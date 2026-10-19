"""Source contracts only; behind-window blur needs a real Mac visual check."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class V8Glass(unittest.TestCase):
    def test_native_circular_mask_without_swiftui_compositing(self):
        s = (ROOT / "Margherita/OverlayController.swift").read_text()
        effect = s[s.index("final class CircularWheelEffectView"):s.index("struct WheelFaceView")]
        self.assertIn("maskImage = image", effect)
        self.assertIn("v.blendingMode = .behindWindow", effect)
        self.assertIn("override var isOpaque: Bool { false }", effect)
        disc = s[s.index("private func disc("):s.index("private func sectorView(")]
        self.assertEqual(disc.count("BlurBackdrop(material:"), 1)
        self.assertNotIn(".clipShape(", disc)
        self.assertNotIn(".compositingGroup(", disc)
    def test_flat_solid_and_translucent_glass_remain_distinct(self):
        s = (ROOT / "Margherita/OverlayController.swift").read_text()
        self.assertIn("TransparentWheelHostingView(rootView:", s)
        self.assertIn("window.backgroundColor = .clear; window.isOpaque = false", s)
        self.assertIn("shape.fill(WheelPalette.oven)", s)
        self.assertIn("WheelPalette.cream.opacity(0.03)", s)
        self.assertIn("on ? 0.90 : 0.65", s)
