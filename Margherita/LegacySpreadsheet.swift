import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Excel 2003 SpreadsheetML XML (.xls), NOT BIFF binary Excel.
/// Values only. Multiple sheets are flattened with worksheet label rows; formulas are not evaluated.
enum LegacySpreadsheet {
    /// Format discovery for XML SpreadsheetML only, never a binary XLS claim.
    static func xmlOutputs() -> [String] { ["csv", "tsv", "xlsx", "ods", "pdf"] }
    /// Discovery only: source "xls" explicitly means Excel 2003 XML, not BIFF.
    /// Actual file dispatch MUST use supports(input:format:) to inspect the bytes.
    static func supportsFormat(source: String, target: String) -> Bool {
        let s = source.lowercased(), t = target.lowercased()
        return s != t && ((s == "xls" && xmlOutputs().contains(t)) ||
            (t == "xls" && ["csv", "tsv", "xlsx", "ods"].contains(s)))
    }
    static func supports(input: URL, format: String) -> Bool {
        let s = input.pathExtension.lowercased(), t = format.lowercased()
        if s == "xls" {
            guard let handle = try? FileHandle(forReadingFrom: input) else { return false }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 4096) else { return false }
            let header = String(data: prefix, encoding: .utf8) ?? ""
            let isXML = header.contains("urn:schemas-microsoft-com:office:spreadsheet")
                && header.contains("Workbook")
            if !isXML { return AppleDocuments.supports(input: input, format: format) }
        }
        return s != t && ((s == "xls" && ["csv", "tsv", "xlsx", "ods", "pdf"].contains(t)) ||
            (t == "xls" && ["csv", "tsv", "xlsx", "ods"].contains(s)))
    }
    static func convert(input: URL, to output: URL, format: String) throws {
        guard supports(input: input, format: format), !FileManager.default.fileExists(atPath: output.path) else { throw NativeConversionError.message("Unsupported spreadsheet conversion or output already exists.") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-XLS-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        if input.pathExtension.lowercased() == "xls" {
            let bytes = try TextClipping.bounded(input)
            guard !bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) else {
                if AppleDocuments.supports(input: input, format: format) {
                    try AppleDocuments.convert(input: input, to: output, format: format)
                    return
                }
                throw NativeConversionError.message("Binary BIFF XLS requires installed Numbers for this conversion, or LibreOffice for PDF. Native XLS export is Excel 2003 XML, not BIFF.")
            }
            let rows = try readXML(bytes)
            try NativeDocuments.writeSpreadsheetRows(rows, output: output, format: format.lowercased(), work: work)
        } else {
            let rows = try NativeDocuments.spreadsheetRows(input, work: work)
            try xml(rows).write(to: output, atomically: true, encoding: .utf8)
        }
    }
    static func xml(_ rows: [[String]]) -> String {
        func escape(_ s: String) -> String {
            // XML 1.0 rejects most control characters.
            String(s.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF) })
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = rows.map { row in "<Row>" + row.map { "<Cell><Data ss:Type=\"String\" xml:space=\"preserve\">" + escape($0) + "</Data></Cell>" }.joined() + "</Row>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><?mso-application progid=\"Excel.Sheet\"?><Workbook xmlns=\"urn:schemas-microsoft-com:office:spreadsheet\" xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\"><Worksheet ss:Name=\"Sheet1\"><Table>" + body + "</Table></Worksheet></Workbook>"
    }
    static func readXML(_ bytes: Data) throws -> [[String]] {
        guard bytes.count <= 8 * 1024 * 1024,
              let text = String(data: bytes, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw NativeConversionError.message("XLS must be bounded UTF-8 Excel 2003 XML without a DTD.")
        }
        let reader = SpreadsheetMLReader()
        let parser = XMLParser(data: bytes)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.failed, reader.sawWorkbook, reader.sheets > 0 else { throw NativeConversionError.message("Invalid or oversized Excel 2003 XML workbook.") }
        return reader.rows
    }
}

private final class SpreadsheetMLReader: NSObject, XMLParserDelegate {
    let namespace = "urn:schemas-microsoft-com:office:spreadsheet"
    var rows: [[String]] = [], row: [String] = []
    var sheetStart = 0
    var sheets = 0, inSheet = false, inRow = false, inCell = false, inData = false
    var sawWorkbook = false, failed = false, text = "", textBytes = 0, cells = 0, depth = 0
    func reject(_ parser: XMLParser) { failed = true; parser.abortParsing() }
    func index(_ attrs: [String: String]) -> Int? {
        // XMLParser keeps qualified attribute names even with namespace processing.
        if let v = attrs["ss:Index"] ?? attrs["Index"] ?? attrs.first(where: { $0.key.hasSuffix(":Index") })?.value { return Int(v) ?? -1 }
        return nil
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        depth += 1
        guard depth <= 64 else { reject(parser); return }
        guard namespaceURI == namespace else { return }
        if name == "Workbook" { sawWorkbook = true }
        if name == "Worksheet" {
            sheets += 1; inSheet = true
            if sheets > 1 {
                rows.append(["Worksheet: " + (attrs["ss:Name"] ?? attrs["Name"] ?? "Sheet" + String(sheets))])
            }
            sheetStart = rows.count
        }
        guard inSheet else { return }
        if name == "Row" {
            if let i = index(attrs) {
                guard i > rows.count - sheetStart, i <= 10000 else { reject(parser); return }
                while rows.count - sheetStart < i - 1 { rows.append([]) }
            }
            guard rows.count < 10000 else { reject(parser); return }
            row = []; inRow = true
        } else if name == "Cell" && inRow {
            if let i = index(attrs) {
                guard i > row.count, i <= 1000 else { reject(parser); return }
                while row.count < i - 1 { row.append("") }
            }
            guard row.count < 1000 else { reject(parser); return }
            inCell = true; text = ""
        } else if name == "Data" && inCell { inData = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inData else { return }
        textBytes += string.utf8.count
        guard textBytes <= 8 * 1024 * 1024 else { reject(parser); return }
        text += string
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        guard namespaceURI == namespace else { return }
        if inSheet {
            if name == "Data" { inData = false }
            else if name == "Cell" && inCell {
                cells += 1
                guard cells <= 200000 else { reject(parser); return }
                row.append(text); inCell = false
            } else if name == "Row" && inRow { rows.append(row); inRow = false }
        }
        if name == "Worksheet" { inSheet = false }
    }
}
