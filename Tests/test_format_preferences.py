"""Real Swift writer/archive exercise plus routing contracts. AVFoundation needs a Mac."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
import tarfile
from test_native_documents_archives import ROOT, SWIFTC, ENV, function

class FormatPreferences(unittest.TestCase):
    def test_editable_docx_has_text_without_facsimile(self):
        source = (ROOT / "Margherita/PDFOffice.swift").read_text()
        pure = 'import Foundation\nenum PDFOffice {\n'
        pure += 'static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"\n'
        pure += 'static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"\n'
        for name in ["xml", "relationships", "types", "docxParts"]:
            pure += function(source, "static func " + name + "(") + "\n"
        pure += """}
let editable = PDFOffice.docxParts(["Hello & goodbye", "Second page"], sizes: [], layout: "editable")
assert(editable["word/document.xml"]!.contains("Hello &amp; goodbye"))
assert(editable["word/document.xml"]!.contains("Second page"))
assert(!editable["word/document.xml"]!.contains("w:drawing"))
assert(!editable["word/_rels/document.xml.rels"]!.contains("media/page"))
let fixed = PDFOffice.docxParts(["Hello"], sizes: [CGSize(width: 612, height: 792)])
assert(fixed["word/document.xml"]!.contains("w:drawing"))
assert(fixed["word/_rels/document.xml.rels"]!.contains("media/page1.png"))
"""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "main.swift").write_text(pure)
            subprocess.run([SWIFTC, "-swift-version", "5", str(root / "main.swift"), "-o", str(root / "test")], env=ENV, check=True, capture_output=True)
            subprocess.run([str(root / "test")], env=ENV, check=True)

    def test_archive_compression_levels_produce_readable_different_sizes(self):
        source = (ROOT / "Margherita/NativeArchives.swift").read_text()
        if os.uname().sysname != "Darwin":
            if not shutil.which("bsdtar"):
                self.skipTest("BSD tar required")
            source = source.replace("import Darwin", "import Glibc").replace('"/usr/bin/tar"', '"/usr/bin/bsdtar"')
        main = """
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for mode in ["fast", "balanced", "small"] {
    for format in ["zip", "gzip", "tar"] {
        try NativeArchives.convert(input: [root.appendingPathComponent("data.txt")],
            to: root.appendingPathComponent(mode + "." + format), format: format, compression: mode)
    }
}
"""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Archive.swift").write_text(source)
            (root / "main.swift").write_text(main)
            payload = ("Margherita conversion settings " * 10000).encode()
            (root / "data.txt").write_bytes(payload)
            subprocess.run([SWIFTC, "-swift-version", "5", str(ROOT / "Margherita/ConversionCancellation.swift"), str(root / "Archive.swift"), str(root / "main.swift"), "-o", str(root / "test")], env=ENV, check=True, capture_output=True)
            subprocess.run([str(root / "test"), str(root)], env=ENV, check=True)
            for mode in ["fast", "balanced", "small"]:
                with zipfile.ZipFile(root / (mode + ".zip")) as z:
                    self.assertEqual(z.read("data.txt"), payload)
                for ext in ["gzip", "tar"]:
                    with tarfile.open(root / (mode + "." + ext)) as t:
                        self.assertEqual(t.extractfile("./data.txt").read(), payload)
            for ext in ["zip", "gzip"]:
                self.assertGreater((root / ("fast." + ext)).stat().st_size, (root / ("small." + ext)).stat().st_size)
            # TAR is uncompressed regardless of preference. Fresh staging directories
            # have wall-clock mtimes, so whole-archive byte equality is not stable.
            self.assertEqual((root / "fast.tar").stat().st_size, (root / "small.tar").stat().st_size)
            def tar_contents(path):
                with tarfile.open(path) as archive:
                    return [(m.name, m.type, m.size, m.mode,
                             archive.extractfile(m).read() if m.isfile() else None)
                            for m in archive.getmembers()]
            self.assertEqual(tar_contents(root / "fast.tar"), tar_contents(root / "small.tar"))


    def test_compress_quality_snapshot_and_auto_layout(self):
        source = (ROOT / "Margherita/Models.swift").read_text()
        start = source.index("struct ConversionOptions: Sendable")
        end = source.index("\nstruct HistoryEntry:", start)
        profile = (ROOT / 'Margherita/PerFormatSettings.swift').read_text().split('@MainActor')[0].replace('import Combine', '')
        pure = profile + source[start:end]
        pure += r'''
var normal = ConversionOptions()
assert(normal.documentLayout == "auto")
normal.imageQuality = 0.95
normal.videoQuality = "high"
normal.audioQuality = 0.9
let balanced = normal.compressionOptions()
normal.compressionMode = "strong"
let strong = normal.compressionOptions()
assert(normal.imageQuality == 0.95 && normal.videoQuality == "high" && normal.audioQuality == 0.9)
assert(balanced.imageQuality == 0.72 && strong.imageQuality == 0.45)
assert(balanced.videoQuality == "balanced" && strong.videoQuality == "small")
assert(balanced.audioQuality == 0.55 && strong.audioQuality == 0.25)
normal.imageQuality = 0.1
normal.videoQuality = "small"
let low = normal.compressionOptions()
assert(low.imageQuality == 0.1 && low.videoQuality == "small")
'''
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "main.swift").write_text(pure)
            subprocess.run([SWIFTC, "-swift-version", "5", str(root / "main.swift"), "-o", str(root / "test")], env=ENV, check=True, capture_output=True)
            subprocess.run([str(root / "test")], env=ENV, check=True)
        engine = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        self.assertIn("action == .compress ? options.compressionOptions() : options", engine)
        docs = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        self.assertIn('let layout, ["editable", "fixed"].contains(layout)', docs)

    def test_options_are_consumed_and_original_does_not_shrink_to_one_pixel(self):
        engine = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        media = (ROOT / "Margherita/ExtendedMedia.swift").read_text()
        docs = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        self.assertIn("compression: options.archiveCompression", engine)
        self.assertIn("layout: options.documentLayout", engine)
        self.assertIn("limit > 0 ? min(limit, Int(max(w, h))) : Int(max(w, h))", engine)
        self.assertIn("options.maxDimension > 0 ?", engine)
        self.assertIn("options.videoHeight > 0", engine)
        self.assertIn("maximum video height requires local FFmpeg", engine)
        self.assertIn("options.videoHeight > 0", media)
        self.assertIn("trunc(min(ih,", media)
        self.assertIn("let cap = min(16384, options.maxDimension)", media)
        self.assertIn('layout: String? = nil', docs)
        self.assertLess(docs.index('if source == "pdf" && target == "docx", let layout'), docs.index("OfficeApplications.convert("))

if __name__ == "__main__":
    unittest.main()
