"""Regression contracts plus a real Swift subprocess diagnostic-limit check."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))


class ConverterEdgeSafety(unittest.TestCase):
    def test_native_movie_stages_before_publishing(self):
        s = (ROOT / "Margherita/NativeMovieAudio.swift").read_text()
        self.assertIn('!fm.fileExists(atPath: output.path)', s)
        self.assertIn('defer { try? fm.removeItem(at: staging) }', s)
        self.assertIn('decoder: decoder, output: temporary', s)
        self.assertLess(s.index('AVAudioFile(forReading: temporary)'), s.index('moveItem(at: temporary'))
        self.assertIn('try? fm.removeItem(at: output)', s)

    def test_pdf_cancellation_and_context_lifetime(self):
        s = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        renderer = s.split("private static func renderPDF(", 1)[1].split("static func parseDelimited", 1)[0]
        self.assertIn('defer { context.closePDF() }', renderer)
        self.assertIn('repeat {\n            try ConversionCancellation.checkCurrent()', renderer)
        s = (ROOT / "Margherita/PDFOffice.swift").read_text()
        self.assertNotIn('if Task.isCancelled', s)
        self.assertIn('try? fm.removeItem(at: output)', s)

    def test_owned_swift_syntax(self):
        for name in ["NativeMovieAudio", "NativeDocuments", "NativeAudio", "PDFOffice", "ExtendedMedia"]:
            subprocess.run([SWIFTC, "-frontend", "-parse", str(ROOT / "Margherita" / (name + ".swift"))],
                           check=True, env=ENV, capture_output=True)

    def test_real_diagnostic_flood_is_stopped(self):
        # Expose the existing subprocess runner only in this isolated test build.
        source = (ROOT / "Margherita/ExtendedMedia.swift").read_text().replace(
            "private static func run(", "static func run(")
        with tempfile.TemporaryDirectory() as folder:
            d = Path(folder)
            (d / "ExtendedMedia.swift").write_text(source)
            options = (ROOT / "Tests/test_v9_media_audit.py").read_text().split(
                "struct ConversionOptions {", 1)[1].split("\n}\nlet a =", 1)[0]
            (d / "main.swift").write_text(
                'import Foundation\nenum MargheritaError: Error { case message(String) }\n'
                + "struct ConversionOptions {" + options + "\n}\n"
                + 'do {\n _ = try ExtendedMedia.run(URL(fileURLWithPath: "/bin/sh"), '
                + '["-c", "while :; do printf \'%65536s\' x; sleep 0.005; done"], timeout: 15)\n'
                + ' fatalError("flood accepted")\n} catch {\n'
                + ' guard String(describing: error).contains("diagnostics size limit") else { fatalError("\\(error)") }\n'
                + ' print("bounded diagnostics passed")\n}\n')
            binary = d / "test"
            subprocess.run([SWIFTC, "-swift-version", "5", str(ROOT / "Margherita/ConversionCancellation.swift"),
                            str(d / "ExtendedMedia.swift"), str(d / "main.swift"), "-o", str(binary)],
                           check=True, env=ENV, capture_output=True, timeout=90)
            result = subprocess.run([str(binary)], check=True, env=ENV, capture_output=True, text=True, timeout=25)
            self.assertIn("bounded diagnostics passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
