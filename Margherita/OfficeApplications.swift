import Foundation
import AppKit
import PDFKit

/// Layout-preserving export through installed desktop applications and Automation permission.
/// These are trusted external applications, NOT a sandbox for hostile documents. Their own
/// security policies still apply. Never enables macros, clicks security prompts, or refreshes
/// links. Do not suppress application alerts: a security/import prompt must fail or time out.
/// Word PDF import is best-effort only, not guaranteed local support. Some Mac releases
/// offer online/cloud PDF conversion. Never approve or UI-script that prompt: cancel it
/// and use LibreOffice/native offline conversion. No dialog is auto-confirmed here.
/// Word may reject PDF import; that failure intentionally permits other engines.
/// Research: https://learn.microsoft.com/en-nz/answers/questions/5131892/convert-pdf-to-editable-word-document
enum OfficeApplications {
    private enum Engine: String {
        case word = "Microsoft Word", powerpoint = "Microsoft PowerPoint", excel = "Microsoft Excel"
        case pages = "Apple Pages", keynote = "Apple Keynote", numbers = "Apple Numbers"

        var bundleID: String {
            switch self {
            case .word: return "com.microsoft.Word"
            case .powerpoint: return "com.microsoft.Powerpoint"
            case .excel: return "com.microsoft.Excel"
            case .pages: return "com.apple.iWork.Pages"
            case .keynote: return "com.apple.iWork.Keynote"
            case .numbers: return "com.apple.iWork.Numbers"
            }
        }
        var installed: Bool {
            installedBundleIDs.contains(bundleID)
        }
    }

    // Discovery is warmed by the background format snapshot once per launch.
    private static let installedBundleIDs: Set<String> = Set([
        "com.microsoft.Word", "com.microsoft.Powerpoint", "com.microsoft.Excel",
        "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.iWork.Numbers"
    ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })

    private static func candidates(source: String, format: String) -> [Engine] {
        let source = source.lowercased(), target = format.lowercased()
        if source == "pdf" && target == "docx" { return [.word] }
        guard target == "pdf" else { return [] }
        if ["doc", "docx", "rtf"].contains(source) { return [.word, .pages] }
        if ["ppt", "pptx"].contains(source) { return [.powerpoint, .keynote] }
        if ["xls", "xlsx"].contains(source) { return [.excel, .numbers] }
        return []
    }

    static func supports(input: URL, format: String) -> Bool {
        input.isFileURL && candidates(source: input.pathExtension, format: format).contains { $0.installed }
    }

    static func supportsFormat(source: String, target: String) -> Bool {
        candidates(source: source, format: target).contains { $0.installed }
    }

    /// Returns only the engine that actually produced a validated output. No output is
    /// installed until an engine succeeds; errors leave the destination untouched.
    static func convert(input: URL, to output: URL, format: String) throws -> String {
        try ConversionCancellation.checkCurrent()
        let fm = FileManager.default
        let engines = candidates(source: input.pathExtension, format: format).filter { $0.installed }
        guard input.isFileURL, output.isFileURL, !engines.isEmpty,
              !fm.fileExists(atPath: output.path), input.standardizedFileURL != output.standardizedFileURL else {
            throw NativeConversionError.message("Office export needs an installed compatible app and a new local output path.")
        }
        // Office formats must be regular files. Validate the immutable staging copy
        // through the same bounded archive checks used by iWork.
        try NativeProcess.checkFile(input)
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-Office-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let source = input.pathExtension.lowercased(), target = format.lowercased()
        let validationCopy = work.appendingPathComponent("validated").appendingPathExtension(source)
        try fm.copyItem(at: input, to: validationCopy)
        try NativeProcess.checkFile(validationCopy)
        try AppleDocuments.validateInput(validationCopy, work: work)
        var failures: [String] = []
        for engine in engines {
            try ConversionCancellation.checkCurrent()
            // Unique filename prevents accidentally resolving a pre-existing user document.
            // Separate copies for each engine prevent a failed engine mutating the next input.
            let name = "Margherita-" + UUID().uuidString
            let opened = work.appendingPathComponent(name).appendingPathExtension(source)
            let staged = work.appendingPathComponent(name + "-export").appendingPathExtension(target)
            try fm.copyItem(at: validationCopy, to: opened)
            do {
                try automate(engine: engine, input: opened, output: staged, target: target)
                try ConversionCancellation.checkCurrent()
                try validateOutput(staged, format: target)
                try ConversionCancellation.checkCurrent()
                try fm.moveItem(at: staged, to: output)
                return engine.rawValue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ConversionCancellation.checkCurrent()
                failures.append(engine.rawValue + ": " + error.localizedDescription)
            }
        }
        throw NativeConversionError.message("Installed Office apps could not export this file. " + failures.joined(separator: " "))
    }

    private static func validateOutput(_ url: URL, format: String) throws {
        try NativeProcess.checkFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 5) ?? Data()
        let valid = format == "pdf" ? header.starts(with: Array("%PDF-".utf8)) : header.starts(with: [0x50, 0x4B])
        guard valid else { throw NativeConversionError.message("The app did not produce a valid " + format.uppercased() + " file.") }
        if format == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isEncrypted, !pdf.isLocked,
                  pdf.pageCount > 0, pdf.pageCount <= 2000 else {
                throw NativeConversionError.message("The exported PDF is empty, encrypted, unreadable or too long.")
            }
        } else {
            let fm = FileManager.default
            let unpacked = fm.temporaryDirectory.appendingPathComponent("Margherita-Office-output-" + UUID().uuidString)
            defer { try? fm.removeItem(at: unpacked) }
            try NativeArchives.extract(input: url, to: unpacked)
            let document = unpacked.appendingPathComponent("word/document.xml")
            try NativeProcess.checkFile(document)
            let size = try document.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 32 * 1024 * 1024,
                  fm.fileExists(atPath: unpacked.appendingPathComponent("[Content_Types].xml").path) else {
                throw NativeConversionError.message("The app did not produce a complete DOCX document.")
            }
        }
    }

    private static func automate(engine: Engine, input: URL, output: URL, target: String) throws {
        let literal = AppleDocuments.literal
        let path = literal(input.path), name = literal(input.lastPathComponent)
        let destination = literal(output.path)
        let outputName = literal(output.lastPathComponent)
        let opening: String, action: String
        switch engine {
        case .word:
            // Word's open result differs by release. Resolve the unique private copy by
            // name instead of trusting active document (which might belong to the user).
            opening = """
            open (POSIX file \(path)) without add to recent files
            set d to get document \(name)
            """
            action = "save as d file name \(destination) file format " + (target == "pdf" ? "format PDF" : "format document")
        case .excel:
            opening = """
            set d to open workbook workbook file name (POSIX file \(path)) update links do not update links
            if (name of d as text) is not \(name) then error "Excel did not bind the private workbook."
            """
            action = "save workbook as d filename \(destination) file format PDF file format"
        case .powerpoint:
            opening = """
            open (POSIX file \(path))
            set d to get presentation \(name)
            """
            action = "save d in (POSIX file \(destination)) as save as PDF"
        case .pages, .keynote, .numbers:
            opening = """
            set d to open (POSIX file \(path))
            if (name of d as text) is not \(name) and (name of d as text) is not \(literal(input.deletingPathExtension().lastPathComponent)) then error "iWork did not bind the private document."
            set boundPrivate to true
            """
            action = "export d to (POSIX file \(destination)) as PDF"
        }
        // Only close our named copies, including the renamed Save As document. No quit,
        // close-all, or active-document commands, even on import/export failure.
        let singular = engine == .excel ? "workbook" : engine == .powerpoint ? "presentation" : "document"
        let close = """
        try
            if exists \(singular) \(name) then close \(singular) \(name) saving no
        end try
        try
            if exists \(singular) \(outputName) then close \(singular) \(outputName) saving no
        end try
        """
        // iWork can omit extensions in its document names. Its returned object is safe
        // after the explicit private-name check, so close that object as well.
        let closeBound = [.pages, .keynote, .numbers].contains(engine) ? "try\nif boundPrivate then close d saving no\nend try" : ""
        // Never mutate global app preferences: terminating the interpreter can skip
        // AppleScript's error cleanup. Refuse link-enabled Word instead of leaving
        // the user's settings changed when a conversion is cancelled.
        let prepare = engine == .word ? """
        if (update links at open of settings) or (update links at print of settings) then
            error "Disable Word automatic link updates before local conversion."
        end if
        """ : ""
        let script = """
        with timeout of 120 seconds
            tell application id \(literal(engine.bundleID))
                set d to missing value
                set boundPrivate to false
                try
                    \(prepare)
                    \(opening)
                    \(action)
                    \(closeBound)
                    \(close)
                on error msg number n
                    \(closeBound)
                    \(close)
                    error msg number n
                end try
            end tell
        end timeout
        """
        // Keep installed-app dictionaries out of the Swift build.
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
