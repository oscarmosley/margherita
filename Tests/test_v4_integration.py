"""Source regression guards only. Not macOS SDK validation."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class V4Integration(unittest.TestCase):
    def test_main_is_plain_conversions(self):
        views = (ROOT / "Margherita/Views.swift").read_text()
        model = (ROOT / "Margherita/AppModel.swift").read_text()
        self.assertNotIn("Advanced tools", views)
        self.assertNotIn("advancedControls", views)
        self.assertNotIn("model.advanced", views)
        self.assertNotIn("var advanced", model)
        source = (ROOT / "Margherita/OverlayController.swift").read_text()
        self.assertIn("conversions = Action.available(urls, advanced: false)", source)
        self.assertIn("tools = Action.available(urls, advanced: true)", source)
        self.assertIn("snapshot.tools : snapshot.conversions", source)
    def test_native_audio_has_dispatch(self):
        engine = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        self.assertIn("NativeAudio.convert(input: first, to: stage", engine)
        self.assertIn("NativeOCR.convert(input: first, to: stage", engine)
    def test_bundle_declares_automation(self):
        import plistlib
        plist = plistlib.loads((ROOT / "Margherita/Info.plist").read_bytes())
        self.assertTrue(plist["NSAppleEventsUsageDescription"])
        self.assertIn("CoreText Vision AVFoundation", (ROOT / "scripts/build-app.sh").read_text())
if __name__ == "__main__": unittest.main()
