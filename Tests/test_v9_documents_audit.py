"""Real extracted Swift helpers, not a reimplementation of their conversion logic.
Only platform adapters are substituted on Linux: ditto ZIP -> zip, BSD tar path.
No successful rendering/textutil/app stub is used.
Run directly to also write the per-route JSON evidence ledger.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
import xml.etree.ElementTree as ET
from test_native_documents_archives import ROOT, ENV, SWIFTC, function

INPUTS = "doc docx rtf rtfd odt html htm txt webarchive md epub pdf csv tsv xlsx ods xls textclipping srt vtt pages numbers key ppt pptx".split()
OUTPUTS = "doc docx rtf rtfd odt html txt webarchive md pdf epub png jpg csv tsv xlsx ods xls textclipping srt vtt pages pptx".split()
EVIDENCE = {}
SUPPORT = {}
SUPPORT_ALL = {}
BINARY_SUPPORT = {}

class DocumentAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        docs = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        selected = ["static func xml(", "static func parseDelimited(", "static func delimited(",
                    "private static func column(", "private static func put(", "static func odsContent(",
                    "private static func writeODS(", "private static func readODS(",
                    "fileprivate static func odsRows(", "private static func writeWorkbook(",
                    "private static func readWorkbook(", "private static func workbookRows(",
                    "private static func writeEPUB(", "static func subtitle(", "static func supportsFormat(", "static func supports("]
        if os.uname().sysname == "Darwin":
            selected += ["private static func renderPDF(", "private static func renderDocumentImage("]
        pure = "import Foundation\nimport FoundationXML\n"
        if os.uname().sysname == "Darwin":
            pure += "import AppKit\nimport CoreText\nimport PDFKit\nimport ImageIO\n"
        pure += "enum NativeDocuments {\nprivate static let textLimit = 8 * 1024 * 1024\n"
        pure += "private static let fm = FileManager.default\n"
        # Keep actual supports() predicates, with unavailable platform-only engines
        # explicitly disabled. These adapters never implement a conversion.
        for declaration in [
            'private static let rich: Set<String> = ["doc","docx","rtf","rtfd","odt","html","htm","txt","webarchive"]',
            'private static let textOutputs: Set<String> = ["doc","docx","rtf","rtfd","odt","html","txt","webarchive","md","pdf","epub","png","jpg"]',
            'private static let officeInputs: Set<String> = ["doc","docx","odt","ppt","pptx","xls","xlsx","ods"]',
            'static var libreOfficeAvailable: Bool { CommandLine.arguments[3] == "support-all" }']:
            pure += declaration + "\n"
        pure += "\n".join(function(docs, sig) for sig in selected)
        # Real helpers stay private in app. Test-only access wrapper is inside enum.
        pure += r"""
static func convert(input: URL, to output: URL, format: String) throws {
    throw NativeConversionError.message("Platform-rich-text dispatch is not present in the portable harness.")
}
static func audit(_ input: URL, _ output: URL, _ target: String, _ work: URL) throws {
    let ext = input.pathExtension.lowercased()
    if target == "support" || target == "support-all" {
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [[String]]
        var results: [[String: Any]] = []
        for pair in cases {
            let url = URL(fileURLWithPath: pair[0])
            results.append(["input": url.pathExtension, "output": pair[1], "supports": supports(input: url, format: pair[1])])
        }
        try JSONSerialization.data(withJSONObject: results).write(to: output)
        return
    }
    if target == "textclipping" || ext == "textclipping" {
        try TextClipping.convert(input: input, to: output, format: target)
        return
    }
    #if os(macOS)
    if target == "audit-pdf" {
        try renderPDF(NSAttributedString(string: String(contentsOf: input, encoding: .utf8),
            attributes: [.font: NSFont.systemFont(ofSize: 12)]), output: output)
        return
    }
    if target == "audit-png" {
        try renderDocumentImage(input, output: output, format: "png")
        return
    }
    #endif
    if ["srt","vtt"].contains(ext) {
        try subtitle(String(contentsOf: input, encoding: .utf8), source: ext, target: target).write(to: output, atomically: true, encoding: .utf8)
        return
    }
    if target == "epub" {
        try writeEPUB(String(contentsOf: input, encoding: .utf8), title: "Audit <book>", output: output, work: work)
        return
    }
    let rows: [[String]]
    if ext == "xlsx" { rows = try readWorkbook(input, work: work) }
    else if ext == "ods" { rows = try readODS(input, work: work) }
    else if ext == "xls" { rows = try LegacySpreadsheet.readXML(Data(contentsOf: input)) }
    else { rows = try parseDelimited(String(contentsOf: input, encoding: .utf8), separator: ext == "tsv" ? "\t" : ",") }
    switch target {
    case "xlsx": try writeWorkbook(rows, output: output, work: work)
    case "ods": try writeODS(rows, output: output, work: work)
    case "xls": try LegacySpreadsheet.xml(rows).write(to: output, atomically: true, encoding: .utf8)
    case "json": try JSONSerialization.data(withJSONObject: rows).write(to: output)
    default: try delimited(rows, separator: target == "tsv" ? "\t" : ",").write(to: output, atomically: true, encoding: .utf8)
    }
}
}
"""
        # Swift raw harness has escaped tabs only at source literal locations.
        pure += docs[docs.index("fileprivate final class DocumentXML:"):]
        archives = (ROOT / "Margherita/NativeArchives.swift").read_text()
        if os.uname().sysname != "Darwin":
            archives = archives.replace("import Darwin", "import Glibc").replace('"/usr/bin/tar"', '"/usr/bin/bsdtar"')
            # Explicit OS adapter, leaves package contents generated by Swift unchanged.
            archives = archives.replace("let fm = FileManager.default\n        let scratch", """if executable == "/usr/bin/ditto" {
            return try run("/usr/bin/zip", ["-q", "-X", "-r", arguments.last!, "."],
                           at: URL(fileURLWithPath: arguments[arguments.count - 2]), limit: limit, timeout: timeout)
        }
        let fm = FileManager.default
        let scratch""", 1)
        # Extract the actual XML parser/writer, not LegacySpreadsheet.convert whose
        # app-routing dependencies are deliberately absent from this portable harness.
        legacy = (ROOT / "Margherita/LegacySpreadsheet.swift").read_text()
        # Compile actual capability predicates under two explicit installation scenarios.
        # These are capability probes only, never conversion implementations.
        for name in ["PDFOffice", "NativeSlides"]:
            source = (ROOT / ("Margherita/" + name + ".swift")).read_text()
            pure += "\nenum " + name + " {\n" + function(source, "static func supportsFormat(") + "\n" + function(source, "static func supports(") + "\n}\n"
        apple = (ROOT / "Margherita/AppleDocuments.swift").read_text()
        pure += '\nenum AppleDocuments { static func installed(_ ext: String) -> Bool { CommandLine.arguments[3] == "support-all" }\n'
        pure += function(apple, "static func supportsFormat(") + "\n"
        pure += function(apple, "static func supports(") + "\n}\n"
        office = (ROOT / "Margherita/OfficeApplications.swift").read_text()
        pure += '\nenum OfficeApplications { private enum Engine { case word, powerpoint, excel, pages, keynote, numbers; var installed: Bool { CommandLine.arguments[3] == "support-all" } }\n'
        pure += function(office, "private static func candidates(") + "\n"
        pure += function(office, "static func supportsFormat(") + "\n"
        pure += function(office, "static func supports(") + "\n}\n"
        pure += "\nenum LegacySpreadsheet {\n" + function(legacy, "static func supports(") + "\n"
        pure += next(line.strip() for line in legacy.splitlines() if "static func xmlOutputs(" in line) + "\n"
        pure += function(legacy, "static func supportsFormat(") + "\n"
        pure += function(legacy, "static func xml(") + "\n"
        pure += function(legacy, "static func readXML(") + "\n}\n"
        pure += legacy[legacy.index("private final class SpreadsheetMLReader:"):]
        (cls.root / "Archive.swift").write_text(archives)
        (cls.root / "Docs.swift").write_text(pure)
        (cls.root / "main.swift").write_text(r"""
import Foundation
do {
    let args = CommandLine.arguments
    let work = URL(fileURLWithPath: args[4])
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try NativeDocuments.audit(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]), args[3], work)
} catch { fputs("\(error)\n", stderr); exit(1) }
""")
        cls.binary = cls.root / "audit"
        result = subprocess.run([SWIFTC, "-swift-version", "5", str(ROOT / "Margherita/ConversionCancellation.swift"), str(cls.root/"Archive.swift"),
                                 str(cls.root/"Docs.swift"), str(ROOT/"Margherita/TextClipping.swift"), str(cls.root/"main.swift"), "-o", str(cls.binary)],
                                env=ENV, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def convert(self, source, target, success=True):
        output = self.root / ("out-" + next(tempfile._get_candidate_names()) + "." + target)
        work = self.root / ("work-" + next(tempfile._get_candidate_names()))
        r = subprocess.run([str(self.binary), str(source), str(output), target, str(work)], env=ENV, text=True, capture_output=True)
        self.assertEqual(r.returncode == 0, success, r.stderr)
        if success and target not in ["json", "support", "support-all", "audit-pdf", "audit-png"]:
            EVIDENCE[source.suffix[1:] + "->" + target] = {
                "status": "pass", "scope": "real extracted Swift value/package helper; not full macOS dispatch"}
        return output

    def fixture(self, name, contents):
        p = self.root / name
        p.write_text(contents)
        return p

    def test_actual_native_support_predicates(self):
        cases = []
        for source in INPUTS:
            file = self.root / ("support." + source)
            file.write_text('<?xml version="1.0"?><Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"/>')
            for target in OUTPUTS:
                if source != target:
                    cases.append([str(file), target])
        listing = self.root / "support-cases.json"
        listing.write_text(json.dumps(cases))
        result = self.convert(listing, "support")
        global SUPPORT, SUPPORT_ALL, BINARY_SUPPORT
        SUPPORT = {row["input"]+"->"+row["output"]:row["supports"] for row in json.loads(result.read_text())}
        result_all = self.convert(listing, "support-all")
        SUPPORT_ALL = {row["input"]+"->"+row["output"]:row["supports"] for row in json.loads(result_all.read_text())}
        binary = self.root / "binary.xls"
        binary.write_bytes(bytes.fromhex("d0cf11e0a1b11ae1") + bytes(504))
        listing.write_text(json.dumps([[str(binary), target] for target in OUTPUTS if target != "xls"]))
        for mode in ["support", "support-all"]:
            result_binary = self.convert(listing, mode)
            BINARY_SUPPORT[mode] = {row["output"]:row["supports"] for row in json.loads(result_binary.read_text())}
        self.assertFalse(BINARY_SUPPORT["support"]["csv"])
        self.assertTrue(BINARY_SUPPORT["support-all"]["csv"])
        self.assertTrue(SUPPORT["xlsx->ods"])
        self.assertTrue(SUPPORT["xls->xlsx"])
        self.assertFalse(SUPPORT["srt->pdf"])
        self.assertTrue(SUPPORT["srt->txt"])

    def test_spreadsheet_packages_and_all_value_routes(self):
        rows = [["alpha", "two  spaces", "ü <&>", "line\nbreak", "=SUM(A1)", "-12.5"], ["tail", "", "42"]]
        source = self.fixture("values.csv", 'alpha,two  spaces,ü <&>,"line\nbreak",=SUM(A1),-12.5\r\ntail,,42\r\n')
        for target in ["xlsx", "ods", "xls", "tsv"]:
            output = self.convert(source, target)
            values = json.loads(self.convert(output, "json").read_text())
            expected = [r[:] for r in rows]
            if target == "tsv":
                expected[0][4] = "'=SUM(A1)"
            self.assertEqual(values, expected)
            if target in ["xlsx", "ods"]:
                with zipfile.ZipFile(output) as z:
                    for name in z.namelist():
                        if name.endswith(".xml"):
                            ET.fromstring(z.read(name))
                    if target == "xlsx":
                        self.assertIn("xl/workbook.xml", z.namelist())
                        self.assertNotIn(b"<f>", z.read("xl/worksheets/sheet1.xml"))
                    else:
                        self.assertEqual(z.infolist()[0].filename, "mimetype")
                        self.assertEqual(z.infolist()[0].compress_type, zipfile.ZIP_STORED)
                        self.assertEqual(z.read("mimetype"), b"application/vnd.oasis.opendocument.spreadsheet")
            for outtype in ["csv", "tsv", "xlsx", "ods", "xls"]:
                if target == outtype:
                    continue
                converted = self.convert(output, outtype)
                actual = json.loads(self.convert(converted, "json").read_text())
                self.assertIn("tail", actual[-1])
                self.assertEqual(actual[0][-1], "-12.5")

    def test_multiple_xlsx_worksheets_sparse_cells_and_cached_formula(self):
        csv = self.fixture("seed.csv", "seed\n")
        seed = self.convert(csv, "xlsx")
        multi = self.root / "multi.xlsx"
        with zipfile.ZipFile(seed) as z, zipfile.ZipFile(multi, "w") as out:
            for name in z.namelist():
                data = z.read(name)
                if name == "xl/workbook.xml":
                    data = data.replace(b"</sheets>", b'<sheet name="Second" sheetId="2" r:id="rId2"/></sheets>')
                if name == "xl/_rels/workbook.xml.rels":
                    data = data.replace(b"</Relationships>", b'<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>')
                out.writestr(name, data)
            out.writestr("xl/worksheets/sheet2.xml", '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="3"><c r="C3"><f>1+41</f><v>42</v></c></row></sheetData></worksheet>')
        rows = json.loads(self.convert(multi, "json").read_text())
        self.assertIn(["Worksheet: Sheet1"], rows)
        self.assertIn(["Worksheet: Second"], rows)
        self.assertEqual(rows[-1], ["", "", "42"])

    def test_multiple_ods_and_xls_worksheets(self):
        source = self.fixture("one.csv", "first\n")
        seed = self.convert(source, "ods")
        multi = self.root / "multi.ods"
        with zipfile.ZipFile(seed) as z, zipfile.ZipFile(multi, "w") as out:
            for name in z.namelist():
                data = z.read(name)
                if name == "content.xml":
                    data = data.replace(b"</office:spreadsheet>", b'<table:table table:name="Second"><table:table-row><table:table-cell office:value="42"/></table:table-row></table:table></office:spreadsheet>')
                out.writestr(name, data)
        rows = json.loads(self.convert(multi, "json").read_text())
        self.assertEqual(rows, [["Worksheet: Sheet1"], ["first"], ["Worksheet: Second"], ["42"]])
        xls = self.convert(source, "xls")
        multi_xls = self.fixture("multi.xls", xls.read_text().replace("</Workbook>", '<Worksheet ss:Name="Second"><Table><Row ss:Index="1"><Cell><Data ss:Type="Number">42</Data></Cell></Row></Table></Worksheet></Workbook>'))
        rows = json.loads(self.convert(multi_xls, "json").read_text())
        self.assertEqual(rows, [["first"], ["Worksheet: Second"], ["42"]])

    def test_real_clipping_writer_reader_roundtrip(self):
        source = self.fixture("clipping.txt", "Text ü 🐱\n=SUM(A1)")
        clipping = self.convert(source, "textclipping")
        import plistlib
        self.assertEqual(plistlib.loads(clipping.read_bytes())["UTI-Data"]["public.utf8-plain-text"], source.read_text())
        plain = self.convert(clipping, "txt")
        self.assertEqual(plain.read_text(), source.read_text())

    def test_epub_real_package(self):
        source = self.fixture("chapter.txt", "First page\n\nSecond page <&> ü")
        output = self.convert(source, "epub")
        with zipfile.ZipFile(output) as z:
            self.assertEqual(z.infolist()[0].filename, "mimetype")
            self.assertEqual(z.infolist()[0].compress_type, zipfile.ZIP_STORED)
            self.assertEqual(z.read("mimetype"), b"application/epub+zip")
            for name in z.namelist():
                if name.endswith((".xml", ".opf", ".ncx", ".xhtml")):
                    ET.fromstring(z.read(name))
            self.assertIn("Second page <&> ü", "".join(ET.fromstring(z.read("OEBPS/chapter.xhtml")).itertext()))

    def test_subtitle_timestamps_and_note_blocks(self):
        vtt = self.fixture("cues.vtt", "WEBVTT\n\nNOTE --> not a cue\nignored\n\n00:01.001 --> 00:03.999 align:start\nhello\n\n01:00:00.000 --> 01:00:01.000\nlast\n")
        srt = self.convert(vtt, "srt")
        self.assertIn("00:00:01,001 --> 00:00:03,999", srt.read_text())
        self.assertNotIn("ignored", srt.read_text())
        self.assertIn("last", self.convert(srt, "txt").read_text())
        self.assertIn("WEBVTT", self.convert(srt, "vtt").read_text())
        self.convert(vtt, "txt")
        for time in ["00:99:01.000 --> 00:99:02.000", "00:00:03.000 --> 00:00:02.999", "99999999999999999999:00:00.000 --> 00:00:02.000"]:
            bad = self.fixture("invalid.vtt", "WEBVTT\n\n"+time+"\nbad\n")
            self.convert(bad, "srt", success=False)

    @unittest.skipUnless(os.uname().sysname == "Darwin", "macOS CoreText/PDFKit executable test")
    def test_mac_multipage_pdf_and_allpage_image(self):
        source = self.fixture("long.txt", "\n".join("Page content line " + str(i) for i in range(220)))
        pdf = self.convert(source, "audit-pdf")
        image = self.convert(pdf, "audit-png")
        # Inspect real output with platform decoders, not byte-marker assertions.
        inspector = self.root / "inspect.swift"
        inspector.write_text('''
import Foundation
import PDFKit
import AppKit
let pdf = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))!
assert(pdf.pageCount > 1)
let page = pdf.page(at: 0)!.bounds(for: .mediaBox)
assert(image.pixelsHigh >= Int(ceil(page.height * 1.5)) * pdf.pageCount)
assert(pdf.string!.contains("Page content line 219"))
''')
        executable = self.root / "inspect"
        subprocess.run([SWIFTC, str(inspector), "-o", str(executable)], env=ENV, check=True)
        subprocess.run([str(executable), str(pdf), str(image)], env=ENV, check=True)
        EVIDENCE["txt->pdf"] = {"status":"pass","scope":"real CoreText multi-page PDF + PDFKit text assertions"}
        EVIDENCE["pdf->png"] = {"status":"pass","scope":"real all-page bitmap image dimensional assertion"}

    @unittest.skipUnless(os.uname().sysname == "Darwin", "macOS textutil required; not counted as a pass")
    def test_mac_rich_text_real_textutil(self):
        text = self.fixture("rich.txt", "Rich text ü\nsecond paragraph")
        for target in ["doc", "docx", "rtf", "rtfd", "odt", "html", "webarchive"]:
            with self.subTest(target=target):
                out = self.root / ("rich." + target)
                r = subprocess.run(["/usr/bin/textutil", "-convert", target, "-output", str(out), "--", str(text)], capture_output=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                back = subprocess.run(["/usr/bin/textutil", "-convert", "txt", "-stdout", "--", str(out)], capture_output=True)
                self.assertEqual(back.returncode, 0, back.stderr)
                self.assertIn("Rich text ü", back.stdout.decode())
                EVIDENCE["txt->"+target] = {"status":"pass","scope":"real macOS textutil roundtrip"}

def write_report(result):
    routes = []
    for source in INPUTS:
        for target in OUTPUTS:
            if source == target:
                continue
            key = source+"->"+target
            evidence = EVIDENCE.get(key, {"status":"mac-untested", "scope":"not executed on macOS; no conversion success claimed"})
            # These exact candidates are selected by the Models.swift document and PDF branches.
            # Final advertising is conditional on real NativeDocuments.supports() predicates.
            pdf_candidates = "txt rtf md docx pages pptx xlsx epub png jpg".split()
            candidate = source != "pdf" or target in pdf_candidates
            advertised_native = candidate and SUPPORT.get(key, False)
            advertised_deps = candidate and SUPPORT_ALL.get(key, False)
            portable = evidence["status"] == "pass" and not evidence["scope"].startswith("real macOS") and "CoreText" not in evidence["scope"]
            routes.append({
                "input":source, "output":target,
                "advertised_candidate":candidate,
                "advertised_without_installed_office_or_iwork":advertised_native,
                "advertised_when_all_supported_apps_installed":advertised_deps,
                "availability_basis":"real extracted supports predicates; no conversion simulated; installation scenarios explicit",
                "conversion_status":"portable-helper-tested" if portable else "Mac-only-untested",
                "full_app_end_to_end_status":"Mac-only-untested",
                "portable_evidence":evidence if portable else None,
                "output_representation": "Excel 2003 SpreadsheetML XML, NOT binary BIFF" if target == "xls" else target,
                "xls_input_variant_probed":"SpreadsheetML XML" if source == "xls" else None,
                **evidence})
    for target in OUTPUTS:
        if target == "xls":
            continue
        routes.append({
            "input":"xls", "input_variant":"binary-BIFF/CFB", "output":target,
            "advertised_candidate":True,
            "advertised_without_installed_office_or_iwork":BINARY_SUPPORT.get("support", {}).get(target, False),
            "advertised_when_all_supported_apps_installed":BINARY_SUPPORT.get("support-all", {}).get(target, False),
            "conversion_status":"Mac-only-untested",
            "full_app_end_to_end_status":"Mac-only-untested",
            "status":"mac-untested",
            "scope":"real support probe only; CFB header fixture is not a valid workbook and was never counted as a conversion",
            "required_dependency":"Numbers/Excel or applicable LibreOffice export; native BIFF decoder absent",
            "portable_evidence":None})
    for action, target in [("searchablePDF","pdf"), ("ocrText","txt")]:
        routes.append({
            "input":"pdf", "output":target, "action":action,
            "advertised_candidate":True,
            "conversion_status":"Mac-only-untested",
            "full_app_end_to_end_status":"Mac-only-untested",
            "status":"mac-untested",
            "scope":"Models.swift PDF special action; actual NativeOCR/Vision not executed by this audit",
            "portable_evidence":None})
    report = {"schema":1, "platform":os.uname().sysname, "full_app_built":False,
              "note":"Pass means stated helper evidence only. mac-untested is NOT a support claim. Values exports flatten multiple sheets with labels, do not preserve formulas/styles.",
              "tests":{"run":result.testsRun,"failures":len(result.failures),"errors":len(result.errors),"skipped":len(result.skipped)},
              "routes":routes}
    artifact = ROOT/"Tests/artifacts/v9-documents-routes.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_text(json.dumps(report, indent=2)+"\n")
    (ROOT/"Tests/v9-documents-audit.json").write_text(json.dumps(report, indent=2)+"\n")

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(DocumentAudit)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    write_report(result)
    raise SystemExit(not result.wasSuccessful())
