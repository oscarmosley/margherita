"""OCR safety contracts, plus a real Vision check when run on a Mac."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Margherita/NativeOCR.swift").read_text()

class OCRContracts(unittest.TestCase):
    def test_bounded_fast_recognition(self):
        self.assertIn("recognitionLongEdge = 2000", SOURCE)
        self.assertIn("CGFloat(recognitionLongEdge) / max", SOURCE)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize: recognitionLongEdge", SOURCE)
        self.assertIn("request.recognitionLevel = .fast", SOURCE)
        self.assertIn("request.usesLanguageCorrection = false", SOURCE)

    def test_cancel_reaches_active_vision_request(self):
        self.assertIn("token?.register { control.cancel() }", SOURCE)
        self.assertIn("request.cancel()", SOURCE)
        self.assertIn("token?.unregister(registration)", SOURCE)
        self.assertIn("try Task.checkCancellation()", SOURCE)
        self.assertIn("try ConversionCancellation.current?.check()", SOURCE)

    def test_timeout_is_not_only_task_cancellation(self):
        self.assertIn("recognitionTimeout: TimeInterval = 20", SOURCE)
        self.assertIn("DispatchWorkItem { control.expire() }", SOURCE)
        self.assertIn("DispatchQueue.global(qos: .utility).asyncAfter", SOURCE)
        self.assertIn("deadline.cancel()", SOURCE)
        self.assertIn("OCR timed out on this page", SOURCE)
        self.assertIn("private let lock = NSLock()", SOURCE)

    def test_progress_and_cleanup(self):
        self.assertIn("progress: @Sendable (Int, Int) -> Void", SOURCE)
        self.assertIn("progress(index, pageCount)", SOURCE)
        self.assertIn("progress(pageCount, pageCount)", SOURCE)
        self.assertIn("defer { try? FileManager.default.removeItem(at: work) }", SOURCE)
        self.assertIn("try? FileManager.default.removeItem(at: output)", SOURCE)
        self.assertIn("try overlay(lines", SOURCE)

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS Vision SDK")
    def test_precancelled_real_vision_and_searchable_pdf(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            main = tmp / "main.swift"
            main.write_text(r'''
import Foundation
import AppKit
import CoreText
import ImageIO
import PDFKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let imageURL = root.appendingPathComponent("screenshot.png")
let output = root.appendingPathComponent("searchable.pdf")
let ctx = CGContext(data: nil, width: 2800, height: 1000, bitsPerComponent: 8,
                    bytesPerRow: 11200, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: 2800, height: 1000))
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SEARCHABLE 12345",
    attributes: [.font: NSFont.systemFont(ofSize: 120), .foregroundColor: NSColor.black]) as CFAttributedString)
ctx.textPosition = CGPoint(x: 120, y: 400); CTLineDraw(line, ctx)
let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil); assert(CGImageDestinationFinalize(dest))
try NativeOCR.convert(input: imageURL, to: output, format: "searchable-pdf")
assert((PDFDocument(url: output)!.string ?? "").contains("12345"))
let token = ConversionCancellation()
token.cancel()
let cancelled = root.appendingPathComponent("cancelled.pdf")
do {
    try ConversionCancellation.$current.withValue(token) {
        try NativeOCR.convert(input: imageURL, to: cancelled, format: "searchable-pdf")
    }
    fatalError("Expected cancellation")
} catch { assert(!FileManager.default.fileExists(atPath: cancelled.path)) }
''')
            sources = ["NativeArchives.swift", "ConversionCancellation.swift", "NativeOCR.swift"]
            result = subprocess.run(["/usr/bin/swiftc", "-swift-version", "5",
                *[str(ROOT / "Margherita" / f) for f in sources], str(main), "-o", str(tmp / "smoke"),
                "-framework", "AppKit", "-framework", "PDFKit", "-framework", "Vision",
                "-framework", "CoreText", "-framework", "ImageIO"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(tmp / "smoke"), str(tmp)], check=True, timeout=90)

if __name__ == "__main__":
    unittest.main()
