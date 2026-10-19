import Foundation
import AppKit
import PDFKit
import ImageIO

/// PDF Office exports are explicitly facsimiles/text reflows, not editable layout reconstruction.
/// DOCX includes each complete page as an image followed by selectable extracted/OCR text.
/// PPTX is one page image per slide. XLSX stores page/line/text rows (no invented table structure).
enum PDFOffice {
    static func supports(input: URL, format: String) -> Bool {
        supportsFormat(source: input.pathExtension, target: format)
    }
    static func supportsFormat(source: String, target: String) -> Bool {
        source.lowercased() == "pdf" && ["docx", "rtf", "txt", "pptx", "xlsx"].contains(target.lowercased())
    }
    static func xml(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        })
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static func relationships(_ entries: [(String, String, String)]) -> String {
        "<Relationships xmlns=\"\(relNS)\">" + entries.map {
            "<Relationship Id=\"\(xml($0.0))\" Type=\"\(officeRel + $0.1)\" Target=\"\(xml($0.2))\"/>"
        }.joined() + "</Relationships>"
    }
    static func types(_ overrides: [(String, String)]) -> String {
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/>" +
        overrides.map { "<Override PartName=\"/\($0.0)\" ContentType=\"application/vnd.openxmlformats-officedocument.\($0.1)+xml\"/>" }.joined() + "</Types>"
    }
    static func docxParts(_ texts: [String], sizes: [CGSize], layout: String = "fixed") -> [String: String] {
        var body = "", relations: [(String, String, String)] = []
        for (index, text) in texts.enumerated() {
            let id = index + 1
            if layout != "editable" {
            let size = sizes[index]
            let scale = min(468 / size.width, 600 / size.height)
            let cx = max(1, Int(size.width * scale * 12700)), cy = max(1, Int(size.height * scale * 12700))
            if index > 0 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            body += """
            <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(id)" name="Page \(id)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="Page \(id)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="img\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
            body += "<w:p><w:r><w:t>Extracted text, page \(id)</w:t></w:r></w:p>"
            relations.append(("img\(id)", "image", "media/page\(id).png"))
            }
            body += text.components(separatedBy: .newlines).map {
                "<w:p><w:r><w:t xml:space=\"preserve\">\(xml($0))</w:t></w:r></w:p>"
            }.joined()

        }
        let document = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="720" w:right="1440" w:bottom="720" w:left="1440"/></w:sectPr></w:body></w:document>
        """
        return ["[Content_Types].xml": types([("word/document.xml", "wordprocessingml.document.main")]),
                "_rels/.rels": relationships([("rId1", "officeDocument", "word/document.xml")]),
                "word/document.xml": document, "word/_rels/document.xml.rels": relationships(relations)]
    }
    static func xlsxParts(_ texts: [String]) -> [String: String] {
        var rows = [["Page", "Line", "Extracted text (not reconstructed tables)"]]
        for (page, text) in texts.enumerated() {
            for (line, value) in text.components(separatedBy: .newlines).enumerated() {
                // Excel cells have a 32767 UTF-16-unit limit. Split long lines without data loss.
                var chunk = "", count = 0
                for scalar in value.unicodeScalars {
                    let n = scalar.value > 0xFFFF ? 2 : 1
                    if count + n > 32000 {
                        rows.append([String(page + 1), String(line + 1), chunk]); chunk = ""; count = 0
                    }
                    chunk.unicodeScalars.append(scalar); count += n
                }
                rows.append([String(page + 1), String(line + 1), chunk])
            }
        }
        let sheetRows = rows.enumerated().map { row, values in
            "<row r=\"\(row + 1)\">" + values.enumerated().map { column, value in
                let letter = ["A", "B", "C"][column]
                return "<c r=\"\(letter)\(row + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
            }.joined() + "</row>"
        }.joined()
        return [
            "[Content_Types].xml": types([("xl/workbook.xml", "spreadsheetml.sheet.main"), ("xl/worksheets/sheet1.xml", "spreadsheetml.worksheet")]),
            "_rels/.rels": relationships([("rId1", "officeDocument", "xl/workbook.xml")]),
            "xl/workbook.xml": "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(officeRel.dropLast())\"><sheets><sheet name=\"Extracted text\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": relationships([("rId1", "worksheet", "worksheets/sheet1.xml")]),
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(sheetRows)</sheetData></worksheet>"
        ]
    }
    static func pptxParts(_ sizes: [CGSize]) -> [String: String] {
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let ns = "xmlns:a=\"\(a)\" xmlns:p=\"\(p)\" xmlns:r=\"\(officeRel.dropLast())\""
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        var parts: [String: String] = [:], slideIDs = ""
        var overrides = [("ppt/presentation.xml", "presentationml.presentation.main"),
                         ("ppt/slideMasters/slideMaster1.xml", "presentationml.slideMaster"),
                         ("ppt/slideLayouts/slideLayout1.xml", "presentationml.slideLayout"),
                         ("ppt/theme/theme1.xml", "theme")]
        var relations = [("master", "slideMaster", "slideMasters/slideMaster1.xml")]
        // Fixed 4:3 slides; each PDF page fits completely with white letterboxing.
        for (i, size) in sizes.enumerated() {
            let id = i + 1, scale = min(9144000 / size.width, 6858000 / size.height)
            let cx = Int(size.width * scale), cy = Int(size.height * scale)
            let x = (9144000 - cx) / 2, y = (6858000 - cy) / 2
            slideIDs += "<p:sldId id=\"\(256 + i)\" r:id=\"slide\(id)\"/>"
            relations.append(("slide\(id)", "slide", "slides/slide\(id).xml"))
            overrides.append(("ppt/slides/slide\(id).xml", "presentationml.slide"))
            parts["ppt/slides/slide\(id).xml"] = """
            <p:sld \(ns)><p:cSld><p:spTree>\(group)<p:pic><p:nvPicPr><p:cNvPr id="2" name="PDF page \(id)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
            parts["ppt/slides/_rels/slide\(id).xml.rels"] = relationships([
                ("image", "image", "../media/page\(id).png"), ("layout", "slideLayout", "../slideLayouts/slideLayout1.xml")])
        }
        parts["ppt/presentation.xml"] = "<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"master\"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        parts["ppt/_rels/presentation.xml.rels"] = relationships(relations)
        parts["ppt/slideLayouts/slideLayout1.xml"] = "<p:sldLayout \(ns) type=\"blank\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        parts["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = relationships([("master", "slideMaster", "../slideMasters/slideMaster1.xml")])
        parts["ppt/slideMasters/slideMaster1.xml"] = "<p:sldMaster \(ns)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"layout\"/></p:sldLayoutIdLst></p:sldMaster>"
        parts["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = relationships([("layout", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("theme", "theme", "../theme/theme1.xml")])
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "222222"), ("lt2", "EEEEEE"),
                      ("accent1", "4472C4"), ("accent2", "ED7D31"), ("accent3", "A5A5A5"),
                      ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "70AD47"),
                      ("hlink", "0563C1"), ("folHlink", "954F72")].map {
            "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>"
        }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(fill)<a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        let font = "<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        parts["ppt/theme/theme1.xml"] = "<a:theme xmlns:a=\"\(a)\" name=\"Margherita\"><a:themeElements><a:clrScheme name=\"Default\">\(colors)</a:clrScheme><a:fontScheme name=\"Default\"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme><a:fmtScheme name=\"Default\"><a:fillStyleLst>\(String(repeating: fill, count: 3))</a:fillStyleLst><a:lnStyleLst>\(String(repeating: line, count: 3))</a:lnStyleLst><a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst><a:bgFillStyleLst>\(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        parts["_rels/.rels"] = relationships([("rId1", "officeDocument", "ppt/presentation.xml")])
        parts["[Content_Types].xml"] = types(overrides)
        return parts
    }
    private static func put(_ text: String, _ path: String, root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    static func convert(input: URL, to output: URL, format: String, layout: String = "fixed") throws {
        try ConversionCancellation.checkCurrent()
        let format = format.lowercased(), fm = FileManager.default
        guard supports(input: input, format: format), !fm.fileExists(atPath: output.path) else {
            throw NativeConversionError.message("Unsupported PDF export or output already exists.")
        }
        let pdf = try NativeOCR.document(input)
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-pdf-office-" + UUID().uuidString)
        let root = work.appendingPathComponent("package"), result = work.appendingPathComponent("result." + format)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var texts: [String] = [], sizes: [CGSize] = [], totalText = 0, imageBytes = 0
        for index in 0..<pdf.pageCount {
            try autoreleasepool {
                try ConversionCancellation.checkCurrent()
                guard let page = pdf.page(at: index) else { throw NativeConversionError.message("Missing PDF page.") }
                if format != "pptx" {
                    let text = try NativeOCR.text(page: page)
                    totalText += text.utf8.count
                    guard totalText <= NativeOCR.textLimit else { throw NativeConversionError.message("PDF text exceeds 8 MB.") }
                    texts.append(text)
                }
                if format == "pptx" || (format == "docx" && layout != "editable") {
                    let raster = try NativeOCR.raster(page)
                    sizes.append(raster.size)
                    let folder = format == "docx" ? "word" : "ppt"
                    let target = root.appendingPathComponent("\(folder)/media/page\(index + 1).png")
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard let dest = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else {
                        throw NativeConversionError.message("Cannot create page image.")
                    }
                    CGImageDestinationAddImage(dest, raster.image, nil)
                    guard CGImageDestinationFinalize(dest) else { throw NativeConversionError.message("Cannot encode page image.") }
                    imageBytes += (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? NativeProcess.fileLimit
                    guard imageBytes <= NativeProcess.fileLimit else { throw NativeConversionError.message("Page images exceed 128 MB.") }
                }
            }
        }
        if !["docx", "pptx"].contains(format), !texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw NativeConversionError.message("No readable text found in this PDF.")
        }
        if format == "docx" && layout == "editable" && !texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw NativeConversionError.message("No readable text found in this PDF.")
        }
        if format == "txt" || format == "rtf" {
            let text = texts.joined(separator: "\n\n\u{000C}\n\n")
            if format == "txt" { try text.write(to: result, atomically: true, encoding: .utf8) }
            else {
                let attr = NSAttributedString(string: text)
                let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: result, options: .atomic)
            }
        } else {
            let parts: [String: String]
            if format == "docx" { parts = docxParts(texts, sizes: sizes, layout: layout) }
            else if format == "xlsx" {
                let rows = texts.reduce(1) { $0 + $1.components(separatedBy: .newlines).count + $1.utf16.count / 32000 }
                guard rows <= 100000 else { throw NativeConversionError.message("Too many text rows for export.") }
                parts = xlsxParts(texts)
            } else { parts = pptxParts(sizes) }
            for (path, text) in parts {
                try ConversionCancellation.checkCurrent()
                try put(text, path, root: root)
            }
            _ = try NativeProcess.run("/usr/bin/zip", ["-q", "-X", "-r", result.path, "."], at: root, timeout: 120)
        }
        try NativeProcess.checkFile(result)
        try ConversionCancellation.checkCurrent()
        try fm.moveItem(at: result, to: output)
        do { try ConversionCancellation.checkCurrent() } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }
}
