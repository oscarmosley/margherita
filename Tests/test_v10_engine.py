"""v10 native routing contracts. Linux parse only, macOS SDK typecheck conditional."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = (ROOT / "Margherita/ConversionEngine.swift").read_text()
OCR = (ROOT / "Margherita/NativeOCR.swift").read_text()
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))


class NativeSettings(unittest.TestCase):
    def test_ocr_language_propagates(self):
        self.assertIn("format: action.format, language: options.ocrLanguage", ENGINE)
        self.assertIn('language: String = "auto"', OCR)
        self.assertIn("supported.contains(language)", OCR)
        self.assertIn("request.recognitionLanguages = [language]", OCR)
        self.assertIn("text(page: page, language: language)", OCR)
        self.assertIn("recognize(image.image, language: language)", OCR)

    def test_actual_color_pixels_preserve_size(self):
        self.assertIn('applyingFilter("CIColorControls"', ENGINE)
        self.assertIn("kCIInputSaturationKey: 0", ENGINE)
        self.assertIn("CGColorSpace(name: CGColorSpace.sRGB)", ENGINE)
        self.assertIn("width: image.width, height: image.height", ENGINE)
        self.assertIn("colorPixels(pixels(source", ENGINE)
        self.assertIn("colorPixels(pageImage(page", ENGINE)
        self.assertIn("pdfPixels(pixels(sourceImage(url)", ENGINE)

    def test_pdf_quality_encoding(self):
        self.assertIn("options.formatProfile?.pdfImageQuality", ENGINE)
        compression = ENGINE.split("private func compressPDF", 1)[1]
        self.assertIn("let quality = options.imageQuality", compression)
        self.assertIn("kCGImageDestinationLossyCompressionQuality: max(0.05, min(1, quality))", ENGINE)
        self.assertIn("ci.composited(over: white)", ENGINE)

    def test_media_explicit_settings_and_defaults(self):
        self.assertIn("options.audioSampleRate > 0 || options.audioChannels > 0", ENGINE)
        self.assertIn('options.videoCodec != "auto"', ENGINE)
        self.assertIn("options.videoFPS > 0", ENGINE)
        helper = ENGINE.split("private func requiresMediaEnhancer", 1)[1].split("private func exportMedia", 1)[0]
        self.assertNotIn("options.audioBitrate", helper)
        self.assertIn("options.audioBitrate)) * 1000", ENGINE)
        self.assertIn("NativeVideoGIF.convert(input: input, output: output, options: options)", ENGINE)

    @unittest.skipUnless(Path(SWIFTC).exists(), "Swift toolchain unavailable")
    def test_swift_syntax_only(self):
        subprocess.run([SWIFTC, "-frontend", "-parse",
                        str(ROOT / "Margherita/ConversionEngine.swift"),
                        str(ROOT / "Margherita/NativeOCR.swift")],
                       check=True, env=ENV, capture_output=True)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS SDK, not claimed on Linux")
    def test_mac_sdk_typecheck(self):
        subprocess.run([SWIFTC, "-typecheck", "-parse-as-library",
                        *map(str, sorted((ROOT / "Margherita").glob("*.swift")))],
                       check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
