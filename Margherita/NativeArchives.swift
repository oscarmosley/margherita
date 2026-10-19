import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum NativeConversionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Bounded subprocess output, no shell and no pipe deadlocks. Work is deliberately synchronous;
/// call from ConversionEngine, never the main actor.
enum NativeProcess {
    static let fileLimit = 128 * 1024 * 1024
    static func run(_ executable: String, _ arguments: [String], at directory: URL? = nil,
                    limit: Int = fileLimit, timeout: TimeInterval = 90) throws -> Data {
        try ConversionCancellation.checkCurrent()
        guard limit >= 0, limit < Int.max, timeout.isFinite, timeout > 0 else {
            throw NativeConversionError.message("Invalid process safety limits.")
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("Margherita-process-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("stdout"), err = scratch.appendingPathComponent("stderr")
        _ = fm.createFile(atPath: out.path, contents: nil); _ = fm.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out), errors = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? errors.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = directory
        #if os(macOS)
        let locale = "en_US.UTF-8"
        #else
        let locale = "C.UTF-8"
        #endif
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": locale,
                            "LANG": locale, "HOME": scratch.path, "TMPDIR": scratch.path]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output; task.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        try ConversionCancellation.checkCurrent()
        try task.run()
        let child = ConversionChild(task)
        let token = ConversionCancellation.current
        let registration = token?.register { child.stop() }
        defer { if let registration { token?.unregister(registration) } }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            while finished.wait(timeout: .now() + 0.01) == .timedOut {
                try ConversionCancellation.checkCurrent()
                let count = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let errorCount = (try? err.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if count > limit || errorCount > 1024 * 1024 {
                    throw NativeConversionError.message("Conversion exceeded the safe output size.")
                }
                if ProcessInfo.processInfo.systemUptime - start > timeout {
                    throw NativeConversionError.message("Conversion timed out.")
                }
            }
            try ConversionCancellation.checkCurrent()
        } catch {
            child.stop()
            // Bounded drain, never waitUntilExit on an uncooperative child.
            _ = finished.wait(timeout: .now() + 2)
            throw error
        }
        // A fast child may exit between polls. Bound reads themselves, not just
        // the live size check, so oversized final stdout/stderr cannot exhaust RAM.
        let reader = try FileHandle(forReadingFrom: out)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: max(0, limit) + 1) ?? Data()
        guard data.count <= limit else { throw NativeConversionError.message("Output is too large.") }
        let errorReader = try FileHandle(forReadingFrom: err)
        defer { try? errorReader.close() }
        let errorData = try errorReader.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard errorData.count <= 1024 * 1024 else {
            throw NativeConversionError.message("Conversion exceeded the safe error output size.")
        }
        guard task.terminationStatus == 0 else {
            let details = String(data: errorData, encoding: .utf8) ?? ""
            throw NativeConversionError.message("The system converter could not read this format. " + String(details.prefix(500)))
        }
        return data
    }
    static func checkFile(_ input: URL) throws {
        let v = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= fileLimit else {
            throw NativeConversionError.message("Choose a regular file smaller than 128 MB.")
        }
    }
}

enum NativeArchives {
    static let inputFormats: Set<String> = ["zip", "tar", "tgz", "gz", "gzip", "bz2", "xz", "rar", "7z", "epub", "docx", "pptx", "xlsx", "odt", "ods"]
    static let outputFormats: Set<String> = ["zip", "tar", "tgz", "gz", "gzip"]
    private static let fm = FileManager.default
    private static let totalLimit = 512 * 1024 * 1024

    static func supports(input: URL, format: String) -> Bool {
        let f = format.lowercased()
        return outputFormats.contains(f) || (["extract", "folder"].contains(f) && inputFormats.contains(input.pathExtension.lowercased()))
    }

    /// Paths are validated independently of the filesystem. Wildcards are rejected;
    /// square brackets are allowed for OOXML and escaped in tar's member matcher.
    static func safeEntry(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 4096, !raw.hasPrefix("/"),
              !raw.contains("\\"), !raw.contains(":"), !raw.contains("*"),
              !raw.contains("?"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeConversionError.message("Unsafe archive entry.")
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains("..") else { throw NativeConversionError.message("Archive contains a path traversal.") }
        let clean = parts.filter { $0 != "." }.joined(separator: "/")
        guard !clean.isEmpty else {
            if raw == "." || raw == "./" { return "" }
            throw NativeConversionError.message("Invalid archive path.")
        }
        return clean
    }

    /// Extract every member as bytes, never ask tar to write paths, links, devices, ACLs or modes.
    /// An archive can therefore never create a symlink or traverse one during extraction.
    static func extract(input: URL, to destination: URL) throws {
        try NativeProcess.checkFile(input)
        guard !fm.fileExists(atPath: destination.path) else { throw NativeConversionError.message("Extraction destination already exists.") }
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-extract-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        // Snapshot the source so entry preflight and extraction read identical bytes.
        let snapshot = work.appendingPathComponent("source")
        try fm.copyItem(at: input, to: snapshot)
        let payload = work.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let ext = input.pathExtension.lowercased()
        // tar can read tgz regardless of its suffix; plain compression streams need a separate route.
        let listing: Data
        do { listing = try NativeProcess.run("/usr/bin/tar", ["-tf", snapshot.path], limit: 4 * 1024 * 1024) }
        catch {
            try ConversionCancellation.checkCurrent()
            let decoder: String
            switch ext {
            case "gz", "gzip": decoder = "/usr/bin/gzip"
            case "bz2": decoder = "/usr/bin/bzip2"
            case "xz": decoder = "/usr/bin/xz"
            default: throw error
            }
            guard fm.isExecutableFile(atPath: decoder) else { throw NativeConversionError.message("This compression decoder is not installed.") }
            let data = try NativeProcess.run(decoder, ["-dc", "--", snapshot.path])
            let name = try safeEntry(input.deletingPathExtension().lastPathComponent)
            guard !name.isEmpty else { throw NativeConversionError.message("Invalid output name.") }
            try data.write(to: payload.appendingPathComponent(name), options: .atomic)
            try ConversionCancellation.checkCurrent()
        try fm.moveItem(at: payload, to: destination)
            return
        }
        guard let list = String(data: listing, encoding: .utf8) else { throw NativeConversionError.message("Archive entry names must use UTF-8.") }
        let entries = list.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        guard entries.count <= 10000 else { throw NativeConversionError.message("Archive contains too many files.") }
        let verboseData = try NativeProcess.run("/usr/bin/tar", ["-tvf", snapshot.path], limit: 8 * 1024 * 1024)
        guard let verbose = String(data: verboseData, encoding: .utf8) else { throw NativeConversionError.message("Invalid archive metadata.") }
        let metadata = verbose.split(separator: "\n").map(String.init)
        guard metadata.count == entries.count else { throw NativeConversionError.message("Ambiguous archive names or metadata.") }
        // BSD tar verbose records contain a declared size. Reject unknown layouts rather
        // than guessing, and bound total expanded bytes before spawning any extractor.
        guard metadata.allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw NativeConversionError.message("Archives containing links, devices or special files are not accepted.")
        }
        let sizePattern = try NSRegularExpression(pattern: #"^[d-][rwxStTs-]{9}[+@.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+"#)
        var declaredTotal = 0
        var sizes: [Int] = []
        for info in metadata {
            try ConversionCancellation.checkCurrent()
            guard let match = sizePattern.firstMatch(in: info, range: NSRange(info.startIndex..., in: info)),
                  let range = Range(match.range(at: 1), in: info), let size = Int(info[range]),
                  size <= NativeProcess.fileLimit else {
                throw NativeConversionError.message("Unsupported archive metadata or member exceeds 128 MB.")
            }
            declaredTotal += size
            guard declaredTotal <= totalLimit else { throw NativeConversionError.message("Expanded archive exceeds 512 MB.") }
            sizes.append(size)
        }
        var seen = Set<String>()
        var total = 0
        for (index, pair) in zip(entries, metadata).enumerated() {
            try ConversionCancellation.checkCurrent()
            let (entry, info) = pair
            guard info.first == "-" || info.first == "d" else {
                throw NativeConversionError.message("Archives containing links, devices or special files are not accepted.")
            }
            let clean = try safeEntry(entry)
            if clean.isEmpty {
                guard info.first == "d" else { throw NativeConversionError.message("Invalid root entry.") }
                continue
            }
            guard seen.insert(clean.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw NativeConversionError.message("Archive contains duplicate paths.") }
            let target = payload.appendingPathComponent(clean)
            if info.first == "d" {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try NativeProcess.run("/usr/bin/tar", ["-xOf", snapshot.path, "--", entry.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")],
                                                limit: min(NativeProcess.fileLimit, totalLimit - total))
                guard data.count == sizes[index] else {
                    throw NativeConversionError.message("Archive member size differs from its declared size.")
                }
                total += data.count
                guard total <= totalLimit else { throw NativeConversionError.message("Expanded archive exceeds 512 MB.") }
                try data.write(to: target, options: .atomic)
            }
        }
        try ConversionCancellation.checkCurrent()
        try fm.moveItem(at: payload, to: destination)
    }

    static func convert(input urls: [URL], to destination: URL, format: String, compression: String = "balanced") throws {
        let format = format.lowercased()
        if format == "extract" || format == "folder" {
            guard urls.count == 1, let first = urls.first else { throw NativeConversionError.message("Extract one archive at a time.") }
            try extract(input: first, to: destination); return
        }
        guard outputFormats.contains(format), !urls.isEmpty,
              !fm.fileExists(atPath: destination.path) else { throw NativeConversionError.message("Unsupported archive format or output already exists.") }
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-archive-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var sources = urls
        let archiveSources = urls.filter { ["zip", "tar", "tgz", "gz", "gzip", "bz2", "xz", "rar", "7z"].contains($0.pathExtension.lowercased()) }
        if !archiveSources.isEmpty {
            guard urls.count == 1, let source = urls.first else {
                throw NativeConversionError.message("Convert one archive at a time, or select ordinary files for a batch archive.")
            }
            let expanded = work.appendingPathComponent("expanded")
            try extract(input: source, to: expanded)
            sources = try fm.contentsOfDirectory(at: expanded, includingPropertiesForKeys: nil)
        }
        let root = work.appendingPathComponent("items")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var total = 0, count = 0, names = Set<String>()
        for url in sources {
            try ConversionCancellation.checkCurrent()
            let name = try safeEntry(url.lastPathComponent)
            guard !name.isEmpty, names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw NativeConversionError.message("Duplicate archive names.") }
            var all = [url]
            let sourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            if sourceValues.isDirectory == true {
                var enumerationError: Error?
                guard let iterator = fm.enumerator(at: url,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                    options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
                    throw NativeConversionError.message("Could not inspect archive input folder.")
                }
                while let child = iterator.nextObject() as? URL {
                    try ConversionCancellation.checkCurrent()
                    all.append(child)
                    if all.count > 10000 { break }
                }
                if let enumerationError { throw enumerationError }
            }
            var memberNames = Set<String>()
            for item in all {
            try ConversionCancellation.checkCurrent()
                // Refuse names that our safe extractor cannot round-trip.
                let relative = item == url ? name : name + "/" + String(item.path.dropFirst(url.path.count + 1))
                let safe = try safeEntry(relative)
                guard memberNames.insert(safe.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                    throw NativeConversionError.message("Archive contains duplicate paths.")
                }
                let v = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                guard v.isSymbolicLink != true, v.isDirectory == true || v.isRegularFile == true else {
                    throw NativeConversionError.message("Archive inputs must not contain links or special files.")
                }
                count += 1; total += v.fileSize ?? 0
                guard count <= 10000, total <= totalLimit else { throw NativeConversionError.message("Archive input exceeds the safe size or file count.") }
            }
            try fm.copyItem(at: url, to: root.appendingPathComponent(name))
        }
        let output = work.appendingPathComponent(format == "zip" ? "result.zip" : "result")
        if format == "zip" {
            // Fixed enum mapping, never pass user text as flags or environment.
            let level = compression == "fast" ? "-1" : (compression == "small" ? "-9" : "-6")
            _ = try NativeProcess.run("/usr/bin/zip", ["-q", "-X", "-r", level, output.path, "."], at: root)
        } else {
            // Tangerine's GZIP route is a gzip-compressed TAR, including batch/folder input.
            if format == "tar" {
                _ = try NativeProcess.run("/usr/bin/tar", ["-cf", output.path, "-C", root.path, "."])
            } else {
                let plain = work.appendingPathComponent("payload.tar")
                _ = try NativeProcess.run("/usr/bin/tar", ["-cf", plain.path, "-C", root.path, "."])
                let level = compression == "fast" ? "-1" : (compression == "small" ? "-9" : "-6")
                // Two bounded processes avoid shell pipelines and ambient GZIP options.
                let bytes = try NativeProcess.run("/usr/bin/gzip", [level, "-c", "--", plain.path])
                try bytes.write(to: output, options: .atomic)
            }
        }
        try NativeProcess.checkFile(output)
        try ConversionCancellation.checkCurrent()
        try fm.moveItem(at: output, to: destination)
    }
}
