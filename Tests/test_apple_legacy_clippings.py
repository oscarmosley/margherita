"""Compile and exercise Foundation-only clipping and SpreadsheetML implementations."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_native_documents_archives import ENV, ROOT, SWIFTC

class AppleLegacyLogic(unittest.TestCase):
    def test_foundation_implementations(self):
        stub = """
import Foundation
enum NativeConversionError: Error { case message(String) }
enum AppleDocuments {
static func supports(input: URL, format: String) -> Bool { false }
static func convert(input: URL, to: URL, format: String) throws { fatalError("platform conversion not exercised by parser fixture") }
}
enum NativeDocuments {
static func supports(input: URL, format: String) -> Bool { false }
static func convert(input: URL, to: URL, format: String) throws { fatalError("platform conversion not exercised by parser fixture") }
static func spreadsheetRows(_ input: URL, work: URL) throws -> [[String]] { fatalError("not exercised by parser fixture") }
static func writeSpreadsheetRows(_ rows: [[String]], output: URL, format: String, work: URL) throws { fatalError("not exercised by parser fixture") }
static func delimited(_ rows: [[String]], separator: Character) -> String { fatalError("not exercised by parser fixture") }
static func parseDelimited(_ text: String, separator: Character) throws -> [[String]] { fatalError("not exercised by parser fixture") }
}
"""
        harness = r'''
assert(LegacySpreadsheet.supportsFormat(source: "xls", target: "xlsx"))
assert(LegacySpreadsheet.supportsFormat(source: "csv", target: "xls"))
assert(!LegacySpreadsheet.supportsFormat(source: "xls", target: "docx"))
assert(!LegacySpreadsheet.supports(input: URL(fileURLWithPath: "/nonexistent/discovery.xls"), format: "xlsx"))
let rows = [["a  b", "=SUM(A1)", "<&>", "ü", "line\nbreak"], ["", "tail"]]
let xml = LegacySpreadsheet.xml(rows)
assert(!xml.contains("ss:Formula"))
assert(try LegacySpreadsheet.readXML(Data(xml.utf8)) == rows)
let sparse = xml.replacingOccurrences(of: "<Row>", with: "<Row ss:Index=\"3\">").components(separatedBy: "</Row>")[0] + "</Row></Table></Worksheet></Workbook>"
let result = try LegacySpreadsheet.readXML(Data(sparse.utf8))
assert(result.count == 3 && result[0].isEmpty && result[2] == rows[0])
for bad in ["<!DOCTYPE Workbook><Workbook/>", "<foo/>", xml.replacingOccurrences(of: "<Row>", with: "<Row ss:Index=\"999999999\">")] {
    do { _ = try LegacySpreadsheet.readXML(Data(bad.utf8)); fatalError("accepted malformed XML") } catch {}
}
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let clipping = temp.appendingPathComponent("text.textClipping")
let content = "hello 🐱\n=SUM(A1)"
try PropertyListSerialization.data(fromPropertyList: ["UTI-Data": ["public.utf8-plain-text": content]], format: .binary, options: 0).write(to: clipping)
assert(try TextClipping.read(clipping) == content)
// Classic resource fork with one TEXT resource ID 256.
func be(_ value: Int, _ size: Int) -> [UInt8] { (0..<size).reversed().map { UInt8((value >> ($0 * 8)) & 255) } }
let payload = Array("classic".utf8)
var fork = be(256,4) + be(256 + 4 + payload.count,4) + be(4 + payload.count,4) + be(50,4)
fork += Array(repeating: 0, count: 256 - fork.count)
fork += be(payload.count,4) + payload
var map = Array(repeating: UInt8(0), count: 24)
map += be(28,2) + be(50,2) + be(0,2)
map += Array("TEXT".utf8) + be(0,2) + be(10,2)
map += be(256,2) + be(65535,2) + [0] + be(0,3) + be(0,4)
fork += map
assert(try TextClipping.resourceText(Data(fork)) == "classic")
for bad in [Data(), Data(repeating: 255, count: 100), Data(fork.prefix(270))] {
    do { _ = try TextClipping.resourceText(bad); fatalError("accepted bad fork") } catch {}
}
print("passed")
'''
        # Swift assertions use non-throwing autoclosures.
        harness = harness.replace('assert(try LegacySpreadsheet.readXML(Data(xml.utf8)) == rows)', 'let roundTrip = try LegacySpreadsheet.readXML(Data(xml.utf8)); assert(roundTrip == rows)')
        harness = harness.replace('assert(try TextClipping.read(clipping) == content)', 'let readClipping = try TextClipping.read(clipping); assert(readClipping == content)')
        harness = harness.replace('assert(try TextClipping.resourceText(Data(fork)) == "classic")', 'let classic = try TextClipping.resourceText(Data(fork)); assert(classic == "classic")')
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / "main.swift").write_text(stub + harness)
            result = subprocess.run([SWIFTC, "-swift-version", "5", str(p / "main.swift"),
                str(ROOT / "Margherita/TextClipping.swift"), str(ROOT / "Margherita/LegacySpreadsheet.swift"),
                "-o", str(p / "test")], env=ENV, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(p / "test")], env=ENV, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
