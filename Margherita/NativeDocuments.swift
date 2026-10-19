import Foundation
import AppKit
import CoreText
import PDFKit
import ImageIO

/// Native document conversions are intentionally honest about loss of layout:
/// PDF/EPUB/Markdown exports are text reflows, not editable reconstructions or OCR.
/// Spreadsheet exports preserve worksheet values; formula results are cached, not recalculated.
enum NativeDocuments {
    private static let fm = FileManager.default
    private static let rich: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "txt", "webarchive"]
    private static let textOutputs: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "html", "txt", "webarchive", "md", "pdf", "epub", "png", "jpg"]
    private static let textLimit = 8 * 1024 * 1024

    private static let officeInputs: Set<String> = ["doc", "docx", "odt", "ppt", "pptx", "xls", "xlsx", "ods"]
    static var libreOfficeAvailable: Bool { libreOfficeExecutable != nil && fm.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }
    private static let libreOfficeExecutable: String? = {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice").path,
         "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"].first { fm.isExecutableFile(atPath: $0) }
    }()

    private static func officeExport(_ input: URL, output: URL, work: URL, format: String) throws {
        guard let executable = libreOfficeExecutable, libreOfficeAvailable else {
            throw NativeConversionError.message("Install LibreOffice to convert slides or legacy spreadsheets to PDF.")
        }
        try AppleDocuments.validateInput(input, work: work)
        let profile = work.appendingPathComponent("lo-profile")
        try put("""
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item></oor:items>
        """, "user/registrymodifications.xcu", root: profile)
        let staged = work.appendingPathComponent("office-input").appendingPathExtension(input.pathExtension)
        try fm.copyItem(at: input, to: staged)
        // Network is forbidden even for external image/link refresh. No user profile/macros are reused.
        var filters: [String] = []
        if input.pathExtension.lowercased() == "pdf" && format == "docx" {
            filters = ["--infilter=writer_pdf_import"]
        }
        _ = try NativeProcess.run("/usr/bin/sandbox-exec",
            ["-p", "(version 1)(allow default)(deny network*)", executable,
             "-env:UserInstallation=" + profile.absoluteString,
             "--headless", "--nologo", "--nodefault", "--norestore"] + filters +
             ["--convert-to", format == "docx" ? "docx:Office Open XML Text" : "pdf",
              "--outdir", work.path, staged.path], timeout: 120)
        let result = work.appendingPathComponent("office-input").appendingPathExtension(format)
        try NativeProcess.checkFile(result)
        if format == "pdf" {
            guard let pdf = PDFDocument(url: result), pdf.pageCount > 0, pdf.pageCount <= 2000 else {
                throw NativeConversionError.message("LibreOffice did not produce a valid PDF.")
            }
        } else {
            try NativeArchives.extract(input: result, to: work.appendingPathComponent("validated-output"))
            guard fm.fileExists(atPath: work.appendingPathComponent("validated-output/word/document.xml").path) else {
                throw NativeConversionError.message("LibreOffice did not produce a valid DOCX.")
            }
        }
        try fm.moveItem(at: result, to: output)
    }

    static func supports(input: URL, format: String) -> Bool {
        if input.pathExtension.lowercased() == "xls" {
            // Discovery's XLS row explicitly includes SpreadsheetML XML. Real
            // dispatch must sniff before offering those native XML routes.
            if ["png", "jpg"].contains(format.lowercased()),
               LegacySpreadsheet.supports(input: input, format: "pdf") { return true }
            return LegacySpreadsheet.supports(input: input, format: format) ||
                AppleDocuments.supports(input: input, format: format) ||
                OfficeApplications.supports(input: input, format: format) ||
                (libreOfficeAvailable && ["pdf", "png", "jpg"].contains(format.lowercased()))
        }
        return supportsFormat(source: input.pathExtension, target: format)
    }
    static func supportsFormat(source: String, target: String) -> Bool {
        let source = source.lowercased(), target = target.lowercased()
        if source == target { return false }
        if OfficeApplications.supportsFormat(source: source, target: target) ||
           AppleDocuments.supportsFormat(source: source, target: target) ||
           TextClipping.supportsFormat(source: source, target: target) ||
           LegacySpreadsheet.supportsFormat(source: source, target: target) ||
           PDFOffice.supportsFormat(source: source, target: target) ||
           NativeSlides.supportsFormat(source: source, target: target) { return true }
        if ["png", "jpg"].contains(target), ["pptx", "pages", "numbers", "key", "xls"].contains(source) {
            return supportsFormat(source: source, target: "pdf")
        }
        if ["pdf", "png", "jpg"].contains(target) && officeInputs.contains(source) && libreOfficeAvailable { return true }
        if ["srt", "vtt"].contains(source) { return ["srt", "vtt", "txt"].contains(target) }
        if ["csv", "tsv", "xlsx", "ods"].contains(source) { return ["csv", "tsv", "xlsx", "ods", "pdf", "png", "jpg"].contains(target) }
        if source == "pdf" { return ["txt", "md", "docx", "epub", "png", "jpg"].contains(target) }
        if rich.contains(source) || ["md", "epub"].contains(source) { return textOutputs.contains(target) }
        // No fake Pages / PowerPoint / legacy Excel conversions.
        return false
    }

    static func convert(input: URL, to output: URL, format: String) throws {
        _ = try convertReporting(input: input, to: output, format: format)
    }

    /// Reports the engine that actually produced the file, never just the preferred candidate.
    static func convertReporting(input: URL, to output: URL, format: String, layout: String? = nil) throws -> String {
        guard input.isFileURL, output.isFileURL, !fm.fileExists(atPath: output.path) else {
            throw NativeConversionError.message("Conversion needs local input and a new output path.")
        }
        let source = input.pathExtension.lowercased(), target = format.lowercased()
        if source == "pdf" && target == "docx", let layout, ["editable", "fixed"].contains(layout) {
            try PDFOffice.convert(input: input, to: output, format: target, layout: layout)
            return layout == "editable" ? "Native PDF editable text" : "Native PDF page facsimile"
        }
        let preferred = (target == "pdf" && ["doc", "docx", "rtf", "ppt", "pptx", "xls", "xlsx", "odt", "ods"].contains(source))
            || (source == "pdf" && target == "docx")
        var failedPreferred = false
        if preferred && OfficeApplications.supports(input: input, format: target) {
            do { return try OfficeApplications.convert(input: input, to: output, format: target) }
            catch {
                try Task.checkCancellation()
                try? fm.removeItem(at: output)
                failedPreferred = true
            }
        }
        if preferred && libreOfficeAvailable {
            let work = fm.temporaryDirectory.appendingPathComponent("Margherita-Office-" + UUID().uuidString)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            do {
                try officeExport(input, output: output, work: work, format: target)
                return source == "pdf" ? "LibreOffice PDF import" : "LibreOffice"
            } catch {
                try Task.checkCancellation()
                try? fm.removeItem(at: output)
                failedPreferred = true
            }
        }
        if source == "pdf" && target == "docx" {
            do {
                try PythonPDFDocuments.convert(input: input, to: output)
                return "pdf2docx"
            } catch {
                try Task.checkCancellation()
                try? fm.removeItem(at: output)
            }
        }
        try convertNative(input: input, to: output, format: target, allowExternal: !preferred, layout: layout == "editable" ? "editable" : "fixed")
        if failedPreferred { return "Native recovery (app export unavailable)" }
        if AppleDocuments.supports(input: input, format: target) {
            return source == "pages" || target == "pages" ? "Pages" :
                ["numbers", "xls"].contains(source) ? "Numbers" : "Keynote"
        }
        if source == "pdf" && target == "docx" { return "Native PDF recovery" }
        if source == "pptx" && target == "pdf" { return "Native slide recovery" }
        return "Native conversion"
    }

    private static func convertNative(input: URL, to output: URL, format: String, allowExternal: Bool, layout: String = "fixed") throws {
        let source = input.pathExtension.lowercased(), target = format.lowercased()
        guard supports(input: input, format: target) else {
            throw NativeConversionError.message("This conversion is not available natively. Pages, slides and legacy spreadsheets require their original application.")
        }
        guard !fm.fileExists(atPath: output.path) else { throw NativeConversionError.message("Output already exists.") }
        var nativeLegacy = source != "xls"
        if source == "xls", let handle = try? FileHandle(forReadingFrom: input) {
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: 4096)) ?? Data()
            let header = String(data: prefix, encoding: .utf8) ?? ""
            nativeLegacy = header.contains("urn:schemas-microsoft-com:office:spreadsheet") && header.contains("Workbook")
        }
        if (allowExternal || nativeLegacy) && LegacySpreadsheet.supports(input: input, format: target) {
            try LegacySpreadsheet.convert(input: input, to: output, format: target); return
        }
        if allowExternal && AppleDocuments.supports(input: input, format: target) {
            try AppleDocuments.convert(input: input, to: output, format: target); return
        }
        if TextClipping.supports(input: input, format: target) {
            try TextClipping.convert(input: input, to: output, format: target); return
        }
        if PDFOffice.supports(input: input, format: target) {
            try PDFOffice.convert(input: input, to: output, format: target, layout: layout); return
        }
        if NativeSlides.supports(input: input, format: target) {
            try NativeSlides.convert(input: input, to: output, format: target); return
        }
        if source != "rtfd" { try NativeProcess.checkFile(input) }
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-doc-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        if target == "png" || target == "jpg" {
            let pdf: URL
            if source == "pdf" { pdf = input }
            else {
                pdf = work.appendingPathComponent("rendered.pdf")
                try convert(input: input, to: pdf, format: "pdf")
            }
            try renderDocumentImage(pdf, output: output, format: target)
            return
        }
        if allowExternal && target == "pdf" && ["ppt", "xls"].contains(source) && libreOfficeAvailable {
            if ["docx", "odt", "xlsx", "ods", "pptx"].contains(source) {
                try NativeArchives.extract(input: input, to: work.appendingPathComponent("validated-office"))
            }
            try officeExport(input, output: output, work: work, format: "pdf")
            return
        }
        if source == "rtfd" {
            // Validate bundle links, devices and sizes without allowing the importer arbitrary local reads.
            let copy = work.appendingPathComponent("checked.zip")
            try NativeArchives.convert(input: [input], to: copy, format: "zip")
        }
        if ["srt", "vtt"].contains(source) {
            let text = try readText(input)
            try subtitle(text, source: source, target: target).write(to: output, atomically: true, encoding: .utf8)
            return
        }
        if ["csv", "tsv", "xlsx", "ods"].contains(source) {
            let rows: [[String]]
            if source == "xlsx" { rows = try readWorkbook(input, work: work) }
            else if source == "ods" { rows = try readODS(input, work: work) }
            else { rows = try parseDelimited(readText(input), separator: source == "tsv" ? "\t" : ",") }
            try writeSpreadsheetRows(rows, output: output, format: target, work: work)
            return
        }

        // Validate archive-based source documents before any system importer sees them.
        if ["docx", "odt"].contains(source) {
            try NativeArchives.extract(input: input, to: work.appendingPathComponent("validated"))
        }
        var attributed: NSAttributedString?
        let text: String
        if source == "pdf" {
            guard let pdf = PDFDocument(url: input), !pdf.isEncrypted, pdf.pageCount <= 2000 else {
                throw NativeConversionError.message("PDF is encrypted, unreadable or too long.")
            }
            var pages: [String] = []
            var count = 0
            for index in 0..<pdf.pageCount {
                try ConversionCancellation.checkCurrent()
                let page = pdf.page(at: index)?.string ?? ""
                count += page.utf8.count
                guard count <= textLimit else { throw NativeConversionError.message("Extracted text is too large.") }
                pages.append(page)
            }
            if pages.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let recognized = work.appendingPathComponent("recognized.txt")
                try NativeOCR.convert(input: input, to: recognized, format: "txt")
                text = try readText(recognized)
            } else {
                text = pages.joined(separator: "\n\n")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeConversionError.message("This PDF has no readable or recognisable text.")
            }
        } else if source == "epub" {
            text = try readEPUB(input, work: work)
        } else if source == "md" || source == "txt" {
            text = try readText(input)
            if source == "md" {
                if let parsed = try? AttributedString(markdown: text,
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)) {
                    attributed = NSAttributedString(parsed)
                }
            }
        } else {
            let data = try NativeProcess.run("/usr/bin/textutil",
                ["-convert", "rtf", "-noload", "-nostore", "-timeout", "1", "-stdout", "--", input.path], limit: textLimit)
            let loaded = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                               documentAttributes: nil)
            attributed = loaded
            text = loaded.string
        }
        guard text.utf8.count <= textLimit else { throw NativeConversionError.message("Document text exceeds 8 MB.") }
        if target == "txt" || target == "md" {
            try text.write(to: output, atomically: true, encoding: .utf8)
        } else if target == "pdf" {
            try renderPDF(attributed ?? NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]), output: output)
        } else if target == "epub" {
            try writeEPUB(text, title: input.deletingPathExtension().lastPathComponent, output: output, work: work)
        } else if target == "html" {
            // HTML is standalone and contains no external resources or active source markup.
            let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>" +
                xml(input.deletingPathExtension().lastPathComponent) + "</title></head><body><pre>" +
                xml(text) + "</pre></body></html>"
            try html.write(to: output, atomically: true, encoding: .utf8)
        } else {
            let staged: URL
            if let attributed = attributed {
                staged = work.appendingPathComponent("source.rtf")
                let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: staged)
            } else {
                staged = work.appendingPathComponent("source.txt")
                try text.write(to: staged, atomically: true, encoding: .utf8)
            }
            _ = try NativeProcess.run("/usr/bin/textutil",
                ["-convert", target, "-noload", "-nostore", "-timeout", "1", "-output", output.path, "--", staged.path])
        }
    }

    /// Shared values path avoids a CSV round trip that would prefix formula-like strings.
    static func spreadsheetRows(_ input: URL, work: URL) throws -> [[String]] {
        switch input.pathExtension.lowercased() {
        case "xlsx": return try readWorkbook(input, work: work)
        case "ods": return try readODS(input, work: work)
        default: return try parseDelimited(readText(input), separator: input.pathExtension.lowercased() == "tsv" ? "\t" : ",")
        }
    }

    static func writeSpreadsheetRows(_ rows: [[String]], output: URL, format target: String, work: URL) throws {
            if target == "xlsx" { try writeWorkbook(rows, output: output, work: work) }
            else if target == "ods" { try writeODS(rows, output: output, work: work) }
            else if target == "pdf" {
                try renderPDF(NSAttributedString(string: delimited(rows, separator: "\t"),
                                                  attributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)]), output: output)
            } else {
                try delimited(rows, separator: target == "tsv" ? "\t" : ",").write(to: output, atomically: true, encoding: .utf8)
            }
    }

    /// All pages form a single vertical image, not a misleading first-page thumbnail.
    /// Bound bitmap dimensions and pixel count before allocating (about 128 MB maximum).
    private static func renderDocumentImage(_ input: URL, output: URL, format: String) throws {
        guard let document = PDFDocument(url: input), !document.isEncrypted,
              document.pageCount > 0, document.pageCount <= 2000 else {
            throw NativeConversionError.message("PDF is encrypted, unreadable or too long.")
        }
        let scale: CGFloat = 1.5
        var pages: [(PDFPage, CGRect, Int)] = []
        var width = 0, height = 0
        for index in 0..<document.pageCount {
            try ConversionCancellation.checkCurrent()
            guard let page = document.page(at: index) else {
                throw NativeConversionError.message("Could not read PDF page.")
            }
            let box = page.bounds(for: .mediaBox)
            let w = ceil(box.width * scale), h = ceil(box.height * scale)
            guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 65535, h <= 65535 else {
                throw NativeConversionError.message("PDF page dimensions are invalid or too large.")
            }
            width = max(width, Int(w)); height += Int(h)
            guard height <= 65535, width * height <= 32000000 else {
                throw NativeConversionError.message("All-page image exceeds 32 megapixels. Split the PDF first.")
            }
            pages.append((page, box, Int(h)))
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NativeConversionError.message("Could not allocate document image.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = height
        for (page, box, pageHeight) in pages {
            try ConversionCancellation.checkCurrent()
            top -= pageHeight
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(top))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        let type = format == "jpg" ? "public.jpeg" : "public.png"
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
            throw NativeConversionError.message("Could not create document image.")
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NativeConversionError.message("Could not save document image.")
        }
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= textLimit else { throw NativeConversionError.message("Text input exceeds 8 MB.") }
        if let text = String(data: data, encoding: .utf8) { return text.replacingOccurrences(of: "\u{feff}", with: "") }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let text = String(data: data, encoding: .utf16) { return text }
        throw NativeConversionError.message("Text must be UTF-8 or UTF-16 with a byte order mark.")
    }

    static func xml(_ string: String) -> String {
        string.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xfffe && $0.value != 0xffff)
        }.map(String.init).joined()
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Full multi-page CoreText output, never a Quick Look preview.
    private static func renderPDF(_ text: NSAttributedString, output: URL) throws {
        guard text.length <= textLimit else { throw NativeConversionError.message("Document is too long.") }
        var media = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw NativeConversionError.message("Could not create PDF.")
        }
        defer { context.closePDF() }
        let styled = NSMutableAttributedString(attributedString: text)
        if styled.length > 0 {
            let range = NSRange(location: 0, length: styled.length)
            styled.enumerateAttribute(.font, in: range) { value, range, _ in
                if value == nil { styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
            }
        }
        let setter = CTFramesetterCreateWithAttributedString(styled as CFAttributedString)
        let path = CGPath(rect: media.insetBy(dx: 48, dy: 48), transform: nil)
        var offset = 0, pages = 0
        repeat {
            try ConversionCancellation.checkCurrent()
            pages += 1
            guard pages <= 2000 else { throw NativeConversionError.message("PDF exceeds 2000 pages.") }
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let range = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            if text.length > 0 && range.length == 0 {
                throw NativeConversionError.message("Unable to paginate document.")
            }
            offset += range.length
        } while offset < text.length
    }

    static func parseDelimited(_ text: String, separator: Character) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false, index = text.startIndex
        func finishField() { row.append(field); field = ""; afterQuote = false }
        func finishRow() { finishField(); rows.append(row); row = [] }
        while index < text.endIndex {
            let c = text[index], next = text.index(after: index)
            if quoted {
                if c == "\"" {
                    if next < text.endIndex && text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                    quoted = false; afterQuote = true
                } else { field.append(c) }
            } else if c == separator { finishField() }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                finishRow()
                if c == "\r" && next < text.endIndex && text[next] == "\n" { index = text.index(after: next); continue }
            } else if c == "\"" && field.isEmpty && !afterQuote { quoted = true }
            else {
                guard !afterQuote, c != "\"" else { throw NativeConversionError.message("Malformed quoted CSV field.") }
                field.append(c)
            }
            guard rows.count <= 100000, row.count <= 16384, field.utf8.count <= 1024 * 1024 else {
                throw NativeConversionError.message("Spreadsheet exceeds safe row, column or cell limits.")
            }
            index = next
        }
        guard !quoted else { throw NativeConversionError.message("Unclosed CSV quote.") }
        if !field.isEmpty || !row.isEmpty || afterQuote { finishRow() }
        guard rows.reduce(0, { $0 + $1.count }) <= 200000 else { throw NativeConversionError.message("Spreadsheet exceeds 200000 cells.") }
        return rows
    }

    static func delimited(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in row.map { value in
            // CSV formula protection for opening exported data in Excel. XLSX uses literal strings.
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let numeric = Double(trimmed).map { $0.isFinite } ?? false
            let safe = !numeric && ["=", "+", "-", "@"].contains(String(trimmed.prefix(1))) ? "'" + value : value
            if safe.contains(separator) || safe.contains("\"") || safe.contains("\n") || safe.contains("\r") {
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return safe
        }.joined(separator: String(separator)) }.joined(separator: "\r\n") + "\r\n"
    }

    private static func column(_ index: Int) -> String {
        var n = index + 1, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
    private static func put(_ value: String, _ path: String, root: URL) throws {
        let target = root.appendingPathComponent(path)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: target, atomically: true, encoding: .utf8)
    }

    /// ODS exports are a single sheet of literal strings, never executable formulas.
    static func odsContent(_ rows: [[String]]) -> String {
        let body = rows.map { row in
            "<table:table-row>" + row.map { value in
                "<table:table-cell office:value-type=\"string\"><text:p>" +
                    value.components(separatedBy: "\n").map { line in
                        // ODF collapses ordinary repeated spaces. Preserve every whitespace run.
                        line.map { c in
                            c == " " ? "<text:s/>" : (c == "\t" ? "<text:tab/>" : xml(String(c)))
                        }.joined()
                    }.joined(separator: "<text:line-break/>") + "</text:p></table:table-cell>"
            }.joined() + "</table:table-row>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Sheet1">\(body)</table:table></office:spreadsheet></office:body></office:document-content>
        """
    }

    private static func writeODS(_ rows: [[String]], output: URL, work: URL) throws {
        let root = work.appendingPathComponent("ods")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try put("application/vnd.oasis.opendocument.spreadsheet", "mimetype", root: root)
        try put(odsContent(rows), "content.xml", root: root)
        try put("""
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
        """, "META-INF/manifest.xml", root: root)
        _ = try NativeProcess.run("/usr/bin/zip", ["-X", "-0", output.path, "mimetype"], at: root)
        _ = try NativeProcess.run("/usr/bin/zip", ["-X", "-r", output.path, "content.xml", "META-INF"], at: root)
    }

    private static func readODS(_ input: URL, work: URL) throws -> [[String]] {
        let root = work.appendingPathComponent("ods")
        try NativeArchives.extract(input: input, to: root)
        return try odsRows(DocumentXML.read(root.appendingPathComponent("content.xml")))
    }

    /// Repetitions are bounded before expanding, including empty trailing cells/rows.
    fileprivate static func odsRows(_ document: DocumentXML.Node) throws -> [[String]] {
        let sheets = document.name == "table" ? [document] : document.descendants("table")
        guard !sheets.isEmpty else { throw NativeConversionError.message("ODS has no worksheet.") }
        if sheets.count > 1 {
            var combined: [[String]] = []
            for sheet in sheets {
                combined.append(["Worksheet: " + (sheet.attributes["table:name"] ?? "Unnamed")])
                combined += try odsRows(sheet)
                guard combined.count <= 100000, combined.reduce(0, { $0 + $1.count }) <= 200000,
                      combined.reduce(0, { $0 + $1.reduce(0, { $0 + $1.utf8.count }) }) <= 8 * 1024 * 1024 else {
                    throw NativeConversionError.message("Combined ODS exceeds safe limits.")
                }
            }
            return combined
        }
        let sheet = sheets[0]
        func repeats(_ node: DocumentXML.Node, _ key: String, maximum: Int) throws -> Int {
            guard let raw = node.attributes[key] else { return 1 }
            guard let n = Int(raw), n > 0, n <= maximum else {
                throw NativeConversionError.message("ODS repetition exceeds safe limits.")
            }
            return n
        }
        func content(_ node: DocumentXML.Node) throws -> String {
            if node.name == "s" {
                return String(repeating: " ", count: try repeats(node, "text:c", maximum: 1000000))
            }
            if node.name == "tab" { return "\t" }
            if node.name == "line-break" { return "\n" }
            var value = ""
            for part in node.parts {
                switch part {
                case .text(let text): value += text
                case .child(let child): value += try content(child)
                }
                guard value.utf8.count <= 1024 * 1024 else {
                    throw NativeConversionError.message("ODS cell exceeds 1 MB.")
                }
            }
            return value
        }
        var rows: [[String]] = [], cells = 0, expandedBytes = 0
        for node in sheet.descendants("table-row") {
            var row: [String] = []
            for cell in node.children where ["table-cell", "covered-table-cell"].contains(cell.name) {
                let count = try repeats(cell, "table:number-columns-repeated", maximum: 16384)
                guard row.count + count <= 16384 else {
                    throw NativeConversionError.message("ODS exceeds 16384 columns.")
                }
                let paragraphs = cell.descendants("p")
                let value: String
                if !paragraphs.isEmpty { value = try paragraphs.map { try content($0) }.joined(separator: "\n") }
                else {
                    value = cell.attributes["office:string-value"] ?? cell.attributes["office:value"] ??
                        cell.attributes["office:boolean-value"] ?? cell.attributes["office:date-value"] ??
                        cell.attributes["office:time-value"] ?? ""
                }
                guard value.utf8.count <= 1024 * 1024 else {
                    throw NativeConversionError.message("ODS cell exceeds 1 MB.")
                }
                row.append(contentsOf: repeatElement(value, count: count))
            }
            let count = try repeats(node, "table:number-rows-repeated", maximum: 100000)
            guard rows.count + count <= 100000, cells + row.count * count <= 200000 else {
                throw NativeConversionError.message("ODS exceeds safe row or cell limits.")
            }
            let rowBytes = row.reduce(0) { $0 + $1.utf8.count }
            guard rowBytes <= 8 * 1024 * 1024,
                  rowBytes * count <= 8 * 1024 * 1024 - expandedBytes else {
                throw NativeConversionError.message("Expanded ODS text exceeds 8 MB.")
            }
            expandedBytes += rowBytes * count
            cells += row.count * count
            rows.append(contentsOf: repeatElement(row, count: count))
        }
        return rows
    }

    private static func writeWorkbook(_ rows: [[String]], output: URL, work: URL) throws {
        let root = work.appendingPathComponent("xlsx")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try put("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """, "[Content_Types].xml", root: root)
        try put("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """, "_rels/.rels", root: root)
        try put("""
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """, "xl/workbook.xml", root: root)
        try put("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """, "xl/_rels/workbook.xml.rels", root: root)
        var body = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, row) in rows.enumerated() {
            body += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() {
                body += "<c r=\"\(column(c))\(r + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
            }
            body += "</row>"
        }
        body += "</sheetData></worksheet>"
        try put(body, "xl/worksheets/sheet1.xml", root: root)
        _ = try NativeProcess.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", root.path, output.path])
    }

    private static func readWorkbook(_ input: URL, work: URL) throws -> [[String]] {
        let root = work.appendingPathComponent("xlsx")
        try NativeArchives.extract(input: input, to: root)
        let workbook = try DocumentXML.read(root.appendingPathComponent("xl/workbook.xml"))
        let sheets = workbook.descendants("sheet")
        guard !sheets.isEmpty else { throw NativeConversionError.message("Workbook has no worksheet.") }
        var combined: [[String]] = []
        for sheet in sheets {
            if sheets.count > 1 { combined.append(["Worksheet: " + (sheet.attributes["name"] ?? "Unnamed")]) }
            combined += try workbookRows(root: root, sheet: sheet)
            guard combined.count <= 100000, combined.reduce(0, { $0 + $1.count }) <= 200000,
                  combined.reduce(0, { $0 + $1.reduce(0, { $0 + $1.utf8.count }) }) <= textLimit else {
                throw NativeConversionError.message("Combined workbook exceeds safe limits.")
            }
        }
        return combined
    }

    private static func workbookRows(root: URL, sheet: DocumentXML.Node) throws -> [[String]] {
        guard let id = sheet.attributes["r:id"] else { throw NativeConversionError.message("Workbook has no worksheet.") }
        let rels = try DocumentXML.read(root.appendingPathComponent("xl/_rels/workbook.xml.rels"))
        guard let rel = rels.descendants("Relationship").first(where: { $0.attributes["Id"] == id }),
              rel.attributes["TargetMode"] != "External", let target = rel.attributes["Target"] else {
            throw NativeConversionError.message("Worksheet relationship is invalid.")
        }
        let path: String
        if target.hasPrefix("/xl/") { path = String(target.dropFirst()) }
        else { path = "xl/" + target }
        let clean = try NativeArchives.safeEntry(path)
        let sharedURL = root.appendingPathComponent("xl/sharedStrings.xml")
        var shared: [String] = []
        if fm.fileExists(atPath: sharedURL.path) {
            shared = try DocumentXML.read(sharedURL).descendants("si").map { $0.descendants("t").map(\.text).joined() }
        }
        let sheetXML = try DocumentXML.read(root.appendingPathComponent(clean))
        var rows: [[String]] = [], occupied = 0, expandedBytes = 0
        for row in sheetXML.descendants("row") {
            let index = (Int(row.attributes["r"] ?? "") ?? (rows.count + 1)) - 1
            guard index >= rows.count, index < 100000 else { throw NativeConversionError.message("Invalid or oversized worksheet row.") }
            while rows.count <= index { rows.append([]) }
            for cell in row.children where cell.name == "c" {
                let letters = (cell.attributes["r"] ?? "").prefix { $0.isASCII && $0.isLetter }
                var col = 0
                for byte in letters.uppercased().utf8 { col = col * 26 + Int(byte) - 64; if col > 16384 { break } }
                col = letters.isEmpty ? rows[index].count : col - 1
                guard col >= rows[index].count, col < 16384 else { throw NativeConversionError.message("Invalid worksheet column.") }
                occupied += col - rows[index].count + 1
                guard occupied <= 200000 else { throw NativeConversionError.message("Worksheet exceeds 200000 cells.") }
                while rows[index].count <= col { rows[index].append("") }
                let cached = cell.children.first(where: { $0.name == "v" })
                if cell.children.contains(where: { $0.name == "f" }), cached == nil {
                    throw NativeConversionError.message("A worksheet formula has no cached value. Recalculate and save it in Excel or Numbers first.")
                }
                let value = cached?.text ?? ""
                if cell.attributes["t"] == "s" {
                    guard let n = Int(value), shared.indices.contains(n) else { throw NativeConversionError.message("Invalid shared string index.") }
                    rows[index][col] = shared[n]
                } else if cell.attributes["t"] == "inlineStr" {
                    rows[index][col] = cell.descendants("t").map(\.text).joined()
                } else if cell.attributes["t"] == "b" { rows[index][col] = value == "1" ? "TRUE" : "FALSE" }
                else { rows[index][col] = value }
                let bytes = rows[index][col].utf8.count
                expandedBytes += bytes
                guard bytes <= 1024 * 1024, expandedBytes <= textLimit else {
                    throw NativeConversionError.message("Expanded worksheet text exceeds safe limits.")
                }
            }
        }
        return rows
    }

    private static func writeEPUB(_ text: String, title: String, output: URL, work: URL) throws {
        let root = work.appendingPathComponent("epub")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try put("application/epub+zip", "mimetype", root: root)
        try put("""
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """, "META-INF/container.xml", root: root)
        let identifier = UUID().uuidString
        try put("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(xml(title))</dc:title><dc:language>en</dc:language><dc:identifier id="bookid">urn:uuid:\(identifier)</dc:identifier></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="chapter"/></spine></package>
        """, "OEBPS/content.opf", root: root)
        try put("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:uuid:\(identifier)"/></head><docTitle><text>\(xml(title))</text></docTitle><navMap><navPoint id="chapter" playOrder="1"><navLabel><text>\(xml(title))</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>
        """, "OEBPS/toc.ncx", root: root)
        try put("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(xml(title))</title></head><body><h1>\(xml(title))</h1><pre>\(xml(text))</pre></body></html>
        """, "OEBPS/chapter.xhtml", root: root)
        // EPUB requires mimetype first and uncompressed.
        _ = try NativeProcess.run("/usr/bin/zip", ["-X", "-0", output.path, "mimetype"], at: root)
        _ = try NativeProcess.run("/usr/bin/zip", ["-X", "-r", output.path, "META-INF", "OEBPS"], at: root)
    }

    private static func readEPUB(_ input: URL, work: URL) throws -> String {
        let root = work.appendingPathComponent("epub")
        try NativeArchives.extract(input: input, to: root)
        let container = try DocumentXML.read(root.appendingPathComponent("META-INF/container.xml"))
        guard let rawOPF = container.descendants("rootfile").first?.attributes["full-path"] else {
            throw NativeConversionError.message("EPUB has no package manifest.")
        }
        let opfPath = try NativeArchives.safeEntry(rawOPF)
        let opfURL = root.appendingPathComponent(opfPath)
        let opf = try DocumentXML.read(opfURL)
        var text = ""
        for ref in opf.descendants("itemref") {
            guard let id = ref.attributes["idref"],
                  let item = opf.descendants("item").first(where: { $0.attributes["id"] == id }),
                  item.attributes["media-type"] == "application/xhtml+xml",
                  let href = item.attributes["href"]?.removingPercentEncoding else { continue }
            let path = try NativeArchives.safeEntry(href)
            let chapter = opfURL.deletingLastPathComponent().appendingPathComponent(path)
            let data = try NativeProcess.run("/usr/bin/textutil", ["-convert", "txt", "-noload", "-nostore",
                "-timeout", "1", "-stdout", "--", chapter.path], limit: textLimit)
            text += (String(data: data, encoding: .utf8) ?? "") + "\n\n"
            guard text.utf8.count <= textLimit else { throw NativeConversionError.message("EPUB text exceeds 8 MB.") }
        }
        guard !text.isEmpty else { throw NativeConversionError.message("EPUB has no readable chapters (it may be DRM protected).") }
        return text
    }

    static func subtitle(_ original: String, source: String, target: String) throws -> String {
        let normalized = original.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [(String, [String])] = []
        let expression = try NSRegularExpression(pattern: #"^(\d{2,}:\d{2}:\d{2}[\.,]\d{3}|\d{2}:\d{2}[\.,]\d{3})\s+-->\s+(\d{2,}:\d{2}:\d{2}[\.,]\d{3}|\d{2}:\d{2}[\.,]\d{3})(?:\s+.*)?$"#)
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            if let first = lines.first, first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") { continue }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex]
            guard let match = expression.firstMatch(in: timing, range: NSRange(timing.startIndex..., in: timing)),
                  let startRange = Range(match.range(at: 1), in: timing),
                  let endRange = Range(match.range(at: 2), in: timing) else {
                throw NativeConversionError.message("Malformed subtitle timestamp.")
            }
            func milliseconds(_ input: Substring) throws -> Int64 {
                let parts = input.replacingOccurrences(of: ",", with: ".").split(separator: ":")
                let seconds = parts.last!.split(separator: ".")
                guard let sec = Int64(seconds[0]), sec < 60,
                      let fraction = Int64(seconds[1]),
                      let minutes = Int64(parts[parts.count - 2]), minutes < 60,
                      let hours = Int64(parts.count == 3 ? String(parts[0]) : "0"), hours <= 1000000 else {
                    throw NativeConversionError.message("Subtitle timestamp is out of range.")
                }
                return ((hours * 60 + minutes) * 60 + sec) * 1000 + fraction
            }
            guard try milliseconds(timing[endRange]) >= milliseconds(timing[startRange]) else {
                throw NativeConversionError.message("Subtitle cue ends before it starts.")
            }
            func stamp(_ input: Substring) -> String {
                var value = input.replacingOccurrences(of: ",", with: ".")
                if value.filter({ $0 == ":" }).count == 1 { value = "00:" + value }
                return target == "srt" ? value.replacingOccurrences(of: ".", with: ",") : value
            }
            let stampLine = stamp(timing[startRange]) + " --> " + stamp(timing[endRange])
            cues.append((stampLine, Array(lines.dropFirst(timingIndex + 1))))
        }
        guard !cues.isEmpty else { throw NativeConversionError.message("No subtitle cues found.") }
        if target == "txt" { return cues.map { $0.1.joined(separator: "\n") }.joined(separator: "\n\n") + "\n" }
        let body = cues.enumerated().map { index, cue in
            (target == "srt" ? "\(index + 1)\n" : "") + cue.0 + "\n" + cue.1.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return (target == "vtt" ? "WEBVTT\n\n" : "") + body + "\n"
    }
}

/// Limited non-network XML tree reader for OOXML/EPUB. Never resolve external entities or DTDs.
fileprivate final class DocumentXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        enum Part { case text(String); case child(Node) }
        var parts: [Part] = []
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func descendants(_ wanted: String) -> [Node] {
            var result: [Node] = name == wanted ? [self] : []
            for child in children { result += child.descendants(wanted) }
            return result
        }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var nodes = 0
    private var bytes = 0
    private var invalid = false
    static func read(_ url: URL) throws -> Node {
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024, let raw = String(data: data, encoding: .utf8),
              !raw.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !raw.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw NativeConversionError.message("XML is too large or declares unsafe entities.")
        }
        let delegate = DocumentXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root else {
            throw NativeConversionError.message("Invalid document XML.")
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        nodes += 1
        guard nodes <= 500000, stack.count < 64 else { invalid = true; parser.abortParsing(); return }
        let node = Node(elementName.components(separatedBy: ":").last ?? elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node); parent.parts.append(.child(node)) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        bytes += string.utf8.count
        guard bytes <= 20 * 1024 * 1024 else { invalid = true; parser.abortParsing(); return }
        stack.last?.text += string
        stack.last?.parts.append(.text(string))
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        invalid = true; parser.abortParsing(); return nil
    }
}
