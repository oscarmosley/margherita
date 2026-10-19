import Foundation
import AppKit

/// Requires the actual installed iWork app and macOS Automation permission.
/// Never treats Quick Look thumbnails as a complete document.
enum AppleDocuments {
    private static let ids = ["pages": "com.apple.iWork.Pages", "numbers": "com.apple.iWork.Numbers", "xls": "com.apple.iWork.Numbers", "key": "com.apple.iWork.Keynote", "ppt": "com.apple.iWork.Keynote", "pptx": "com.apple.iWork.Keynote"]
    private static let installedIDs = Set(ids.values.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
    })
    static func installed(_ ext: String) -> Bool {
        guard let id = ids[ext] else { return false }
        return installedIDs.contains(id)
    }
    static func supports(input: URL, format: String) -> Bool {
        supportsFormat(source: input.pathExtension, target: format)
    }
    static func supportsFormat(source: String, target: String) -> Bool {
        let s = source.lowercased(), t = target.lowercased()
        guard s != t else { return false }
        if t == "pages" { return installed("pages") && ["pdf", "doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "txt", "webarchive", "md", "epub"].contains(s) }
        if s == "pages" { return installed(s) && ["pdf", "docx", "txt", "rtf", "html", "md", "epub", "png", "jpg"].contains(t) }
        if ["numbers", "xls", "key", "ppt", "pptx"].contains(s) { return installed(s) && (["pdf", "png", "jpg"].contains(t) || (["numbers", "xls"].contains(s) && ["xlsx", "csv", "tsv", "ods"].contains(t))) }
        return false
    }
    static func convert(input: URL, to output: URL, format: String) throws {
        try ConversionCancellation.checkCurrent()
        let fm = FileManager.default, source = input.pathExtension.lowercased(), target = format.lowercased()
        guard supports(input: input, format: target), input.isFileURL, output.isFileURL,
              !fm.fileExists(atPath: output.path) else { throw NativeConversionError.message("iWork conversion requires the installed app and a new local output path.") }
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-iWork-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try validateInput(input, work: work)
        var opened = work.appendingPathComponent("input").appendingPathExtension(source)
        // Open a private copy, never close or mutate an existing user document.
        if target == "pages" && source != "docx" {
            opened = work.appendingPathComponent("input.docx")
            try NativeDocuments.convert(input: input, to: opened, format: "docx")
        } else { try fm.copyItem(at: input, to: opened) }
        let app = target == "pages" ? "pages" : source
        let intermediate: String
        if target == "pages" { intermediate = "pages" }
        else if source == "pages" { intermediate = target == "pdf" || target == "png" || target == "jpg" ? "pdf" : "docx" }
        else if ["numbers", "xls"].contains(source) && !["pdf", "png", "jpg"].contains(target) { intermediate = "xlsx" }
        else { intermediate = "pdf" }
        let staged = work.appendingPathComponent("export").appendingPathExtension(intermediate)
        try automate(app: app, input: opened, output: staged, format: intermediate)
        try ConversionCancellation.checkCurrent()
        guard fm.fileExists(atPath: staged.path) else { throw NativeConversionError.message("iWork did not produce the requested document.") }
        if target == intermediate { try fm.moveItem(at: staged, to: output) }
        else { try NativeDocuments.convert(input: staged, to: output, format: target) }
    }
    /// Installed iWork remains a trusted external application, not a sandboxed renderer.
    /// This bounds local inputs and rejects symlinks/special files before handing off.
    static func validateInput(_ input: URL, work: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let root = try input.resourceValues(forKeys: keys)
        guard root.isSymbolicLink != true else { throw NativeConversionError.message("iWork input must not be a symbolic link.") }
        var size = 0, count = 0
        func inspect(_ url: URL) throws {
            try ConversionCancellation.checkCurrent()
            let v = try url.resourceValues(forKeys: keys)
            guard v.isSymbolicLink != true, v.isRegularFile == true || v.isDirectory == true else {
                throw NativeConversionError.message("iWork input contains a link or special file.")
            }
            count += 1
            size += v.fileSize ?? 0
            guard count <= 20000, size <= 256 * 1024 * 1024 else {
                throw NativeConversionError.message("iWork input exceeds the 256 MB / 20,000 entry limit.")
            }
        }
        try inspect(input)
        if root.isDirectory == true {
            guard ["pages", "numbers", "key"].contains(input.pathExtension.lowercased()),
                  let walk = fm.enumerator(at: input, includingPropertiesForKeys: Array(keys)) else {
                throw NativeConversionError.message("Unsupported iWork package.")
            }
            for case let item as URL in walk { try inspect(item) }
        } else {
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 4) ?? Data()
            if header.starts(with: [0x50, 0x4B]) {
                // Reuse archive traversal, entry/expansion bounds and link validation.
                try NativeArchives.extract(input: input, to: work.appendingPathComponent("validated-archive"))
            }
        }
    }

    /// Escape only AppleScript literals, never shell commands.
    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    private static func automate(app: String, input: URL, output: URL, format: String) throws {
        guard let id = ids[app] else { throw NativeConversionError.message("Unsupported iWork app.") }
        let action = format == "pages"
            ? "save d in (POSIX file " + literal(output.path) + ")"
            : "export d to (POSIX file " + literal(output.path) + ") as " + (format == "docx" ? "Microsoft Word" : format == "xlsx" ? "Microsoft Excel" : "PDF")
        let script = """
        with timeout of 120 seconds
            tell application id \(literal(id))
                set d to open (POSIX file \(literal(input.path)))
                try
                    \(action)
                    close d saving no
                on error msg number n
                    try
                        close d saving no
                    end try
                    error msg number n
                end try
            end tell
        end timeout
        """
        // A child interpreter is cancellable without blocking AppKit's main thread.
        // Script text is one literal argument, never interpreted by a shell.
        do {
            _ = try NativeProcess.run("/usr/bin/osascript", ["-e", script], limit: 1024 * 1024, timeout: 125)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ConversionCancellation.checkCurrent()
            if error.localizedDescription.contains("(-128)") { throw CancellationError() }
            throw error
        }
    }
}
