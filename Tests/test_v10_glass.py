"""Math-only contrast checks vs worst-case white backdrop. Not a Mac render."""
from pathlib import Path
import re, unittest
S = (Path(__file__).resolve().parents[1] / "Margherita/OverlayController.swift").read_text()
def const(n): return float(re.search(n + r" = ([0-9.]+)", S).group(1))
BACK = (0.02, 0.02, 0.03)
def over(bg, fg, a): return tuple(f * a + b * (1 - a) for f, b in zip(fg, bg))
def lin(c): return c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4
def lum(c): r, g, b = map(lin, c); return .2126 * r + .7152 * g + .0722 * b
def ratio(a, b):
    x, y = sorted((lum(a), lum(b)), reverse=True); return (x + .05) / (y + .05)
WHITE = (1, 1, 1)
class V10Glass(unittest.TestCase):
    def test_labels_on_white(self):
        bg = over(over(WHITE, BACK, const("discBackingAlpha")), BACK, const("sectorBackingAlpha"))
        self.assertGreaterEqual(ratio(WHITE, bg), 4.5)
    def test_hub_on_white(self):
        bg = over(over(WHITE, BACK, const("discBackingAlpha")), BACK, const("hubBackingAlpha"))
        self.assertGreaterEqual(ratio(WHITE, bg), 4.5)
    def test_hover_accent_worst_case(self):
        a = const("hoverAccentAlpha")
        base = over(over(WHITE, BACK, const("discBackingAlpha")), BACK, const("sectorBackingAlpha"))
        for acc in [(1, 1, 0), (1, 1, 1), (1, .8, .2), (.95, .3, .2)]:
            self.assertGreaterEqual(ratio(WHITE, over(over(base, acc, a), BACK, const('hoverShadeAlpha'))), 4.5)
    def test_glass_kept(self):
        self.assertIn("BlurBackdrop(material: .hudWindow)", S)
        self.assertLess(const("discBackingAlpha"), 0.8)
    def test_halo(self):
        self.assertGreaterEqual(S.count("black.opacity(0.85), radius: 1.5"), 2)
if __name__ == "__main__": unittest.main()
