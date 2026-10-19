"""v7 source contracts, not a macOS build or rendered UI test."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class V7Contract(unittest.TestCase):
    def test_discovery_off_ui_thread(self):
        s = (ROOT / "Margherita/FormatCapabilities.swift").read_text()
        self.assertIn("Task.detached(priority: .utility)", s)
        self.assertIn("FormatCapabilityDiscovery.snapshot", s)
        v = (ROOT / "Margherita/Views.swift").read_text()
        self.assertNotIn("Action.available(", v)
        self.assertNotIn("ExtendedMedia.available", v)
    def test_shared_demo_and_permissions(self):
        s = (ROOT / "Margherita/Onboarding.swift").read_text()
        self.assertIn("WheelFaceView(model: st.model)", s)
        self.assertNotIn("struct PizzaWheel", s)
        self.assertIn("Permissions", s)
        v = (ROOT / "Margherita/Views.swift").read_text()
        for item in ["Spreadsheets", "Audio", "Video", "Archives", "Subtitles", "PermissionsTab", "Privacy_Accessibility", "Privacy_ListenEvent", "Privacy_Automation"]:
            self.assertIn(item, v)
    def test_no_state_macros(self):
        for p in (ROOT / "Margherita").glob("*.swift"):
            for marker in ["@State ", "@StateObject", "#Preview", "@Observable"]:
                self.assertNotIn(marker, p.read_text(), str(p))
