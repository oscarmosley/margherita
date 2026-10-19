import Foundation
import PDFKit

/// Optional already-installed dependency. Never installs Python or modules.
/// Isolated Python excludes cwd/PYTHONPATH/user-site injection; a dedicated venv is supported.
enum PythonPDFDocuments {
    static func convert(input: URL, to output: URL) throws {
        let fm = FileManager.default
        guard input.isFileURL, output.isFileURL, !fm.fileExists(atPath: output.path),
              fm.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw NativeConversionError.message("Optional pdf2docx is unavailable.")
        }
        try NativeProcess.checkFile(input)
        guard let pdf = PDFDocument(url: input), !pdf.isEncrypted, pdf.pageCount > 0, pdf.pageCount <= 200 else {
            throw NativeConversionError.message("Optional PDF import requires an unencrypted PDF of at most 200 pages.")
        }
        let venv = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Margherita/pdf2docx-venv/bin/python3").path
        let candidates = [venv, "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .filter { fm.isExecutableFile(atPath: $0) }
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-pdf2docx-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let copied = work.appendingPathComponent("source.pdf")
        try fm.copyItem(at: input, to: copied)
        let staged = work.appendingPathComponent("result.docx")
        let code = """
        import sys
        from pdf2docx import Converter
        cv = Converter(sys.argv[1])
        try:
            cv.convert(sys.argv[2], multi_processing=False, ignore_page_error=False)
        finally:
            cv.close()
        """
        for python in candidates {
            try ConversionCancellation.checkCurrent()
            do {
                _ = try NativeProcess.run("/usr/bin/sandbox-exec",
                    ["-p", "(version 1)(allow default)(deny network*)", python, "-I", "-c", code,
                     copied.path, staged.path], at: work, timeout: 120)
                try NativeProcess.checkFile(staged)
                let checked = work.appendingPathComponent("checked")
                try NativeArchives.extract(input: staged, to: checked)
                guard fm.fileExists(atPath: checked.appendingPathComponent("word/document.xml").path) else {
                    throw NativeConversionError.message("pdf2docx produced an invalid DOCX.")
                }
                try ConversionCancellation.checkCurrent()
                try fm.moveItem(at: staged, to: output)
                return
            } catch {
                try ConversionCancellation.checkCurrent()
                try? fm.removeItem(at: staged)
                try? fm.removeItem(at: work.appendingPathComponent("checked"))
            }
        }
        throw NativeConversionError.message("No compatible installed Python/pdf2docx engine succeeded.")
    }
}
