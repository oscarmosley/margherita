"""Exercise real ODS parser/writer Swift logic without a macOS SDK."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_native_documents_archives import ENV, ROOT, SWIFTC, function

class ODSLogic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        source = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        tree = source[source.index("fileprivate final class DocumentXML:"):]
        pure = "import Foundation\n"
        if os.uname().sysname != "Darwin":
            pure += "import FoundationXML\n"
        pure += 'enum NativeConversionError: Error { case message(String) }\nenum NativeDocuments {\n'
        pure += "\n".join(function(source, name) for name in [
            "static func xml(", "static func odsContent(", "fileprivate static func odsRows("])
        pure += "\n}\n" + tree
        pure += r"""
let args = CommandLine.arguments
do {
    if args[1] == "roundtrip" {
        let rows = [["a  b", "x\ty\nz", " <&> ", "=SUM(A1)", "ü"], ["", "last"]]
        let content = NativeDocuments.odsContent(rows)
        let path = URL(fileURLWithPath: args[2])
        try content.write(to: path, atomically: true, encoding: .utf8)
        let actual = try NativeDocuments.odsRows(DocumentXML.read(path))
        assert(actual == rows)
        assert(!content.contains("table:formula"))
    } else {
        let rows = try NativeDocuments.odsRows(DocumentXML.read(URL(fileURLWithPath: args[2])))
        if args[1] == "mixed" { assert(rows == [["a bold c  d", "42", "42"], ["a bold c  d", "42", "42"]]) }
    }
    print("passed")
} catch { fputs("\(error)\n", stderr); exit(1) }
"""
        (root / "main.swift").write_text(pure)
        cls.binary = root / "ods"
        result = subprocess.run([SWIFTC, "-swift-version", "5", str(root / "main.swift"), "-o", str(cls.binary)],
                                env=ENV, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_xml(self, body, mode="read", success=True):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "content.xml"
            path.write_text(body)
            result = subprocess.run([str(self.binary), mode, str(path)], env=ENV, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, success, result.stderr)

    def test_roundtrip_preserves_whitespace_literal_formula_unicode(self):
        self.run_xml("", "roundtrip")

    def test_repetitions_mixed_spans_cached_values(self):
        self.run_xml('<root xmlns:table="table" xmlns:office="office" xmlns:text="text"><table:table>'
                     '<table:table-row table:number-rows-repeated="2"><table:table-cell>'
                     '<text:p>a <text:span>bold</text:span> c<text:s text:c="2"/>d</text:p>'
                     '</table:table-cell><table:table-cell table:number-columns-repeated="2" office:value="42"/>'
                     '</table:table-row></table:table></root>', "mixed")

    def test_oversized_repeat_rejected(self):
        for attribute, element in [("table:number-rows-repeated", "table:table-row"),
                                   ("table:number-columns-repeated", "table:table-cell")]:
            self.run_xml(f'<root xmlns:table="table"><table:table><table:table-row><{element} {attribute}="999999999999"/></table:table-row></table:table></root>',
                         success=False)

    def test_expanded_text_budget_rejected(self):
        self.run_xml('<root xmlns:table="table" xmlns:text="text"><table:table>'
                     '<table:table-row table:number-rows-repeated="10000"><table:table-cell>'
                     '<text:p>' + 'x' * 1000 + '</text:p></table:table-cell>'
                     '</table:table-row></table:table></root>', success=False)

    def test_dtd_rejected(self):
        self.run_xml('<!DOCTYPE root [<!ENTITY evil SYSTEM "file:///etc/passwd">]><root>&evil;</root>', success=False)

    def test_missing_sheet_rejected(self):
        self.run_xml("<root/>", success=False)

if __name__ == "__main__":
    unittest.main()
