"""Exercise the actual presentation helper and geometry, without claiming macOS rendering."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))

class WheelLabelTests(unittest.TestCase):
    def test_real_swift_layout(self):
        if not Path(SWIFTC).exists():
            self.skipTest("Swift compiler unavailable")
        overlay = (ROOT / "Margherita/OverlayController.swift").read_text()
        helper = overlay[overlay.index("enum WheelLabelLayout"):overlay.index("/// Observable state")]
        geometry = (ROOT / "Margherita/WheelGeometry.swift").read_text()
        geometry = geometry[geometry.index("struct WheelGeometry"):geometry.index("    /// Rounded annular sector")] + "}\n"
        main = r"""
import Foundation
var checked = 0
func check(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}
check(WheelLabelLayout.text("Searchable PDF") == "SEARCHABLE\nPDF", "searchable PDF break")
check(WheelLabelLayout.text("OCR Text") == "OCR\nTEXT", "OCR break")
check(WheelLabelLayout.text("Copy Path") == "COPY\nPATH", "path break")
check(WheelLabelLayout.text("JPG") == "JPG", "short title unchanged")
for title in ["Copy to Folder", "Convert to Searchable PDF", "Remove Background", "OCR Text", "Compress"] {
    let shown = WheelLabelLayout.text(title)
    check(shown.split(separator: "\n").count <= 2, "two lines at most")
    check(shown.replacingOccurrences(of: "\n", with: " ") == title.uppercased(), "words preserved")
}
for size: CGFloat in [320, 360, 460] {
    for count in 1...60 {
        for page in 0..<max(1, (count + 17) / 18) {
            let g = WheelGeometry(count: count, page: page, size: size)
            for s in g.sectors {
                let box = WheelLabelLayout.bounds(inner: s.innerRadius, outer: s.outerRadius,
                                                 lo: s.lo, hi: s.hi, gap: g.gap)
                check(box.width > 4 && box.height > 0, "usable padded bounds")
                // Check the complete rectangle perimeter in math coordinates, not just its centre.
                for step in 0...20 {
                    let t = CGFloat(step) / 20
                    for edge in 0..<4 {
                        let dx = edge < 2 ? (t - 0.5) * box.width : (edge == 2 ? -0.5 : 0.5) * box.width
                        let dy = edge < 2 ? (edge == 0 ? -0.5 : 0.5) * box.height : (t - 0.5) * box.height
                        let x = s.midRadius * cos(s.mid) + dx
                        let y = s.midRadius * sin(s.mid) + dy
                        let r = hypot(x, y)
                        var a = atan2(y, x)
                        while a < s.mid - .pi { a += 2 * .pi }
                        while a > s.mid + .pi { a -= 2 * .pi }
                        let inset = g.gap / (2 * s.midRadius)
                        check(r > s.innerRadius && r < s.outerRadius, "inside radial arcs")
                        check(a > s.lo + inset && a < s.hi - inset, "inside slice boundaries")
                        checked += 1
                    }
                }
            }
        }
    }
}
print("Checked \(checked) label boundary samples")
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / "Layout.swift").write_text("import Foundation\n" + helper + geometry)
            (path / "main.swift").write_text(main)
            exe = path / "labels"
            compile_result = subprocess.run([SWIFTC, str(path / "Layout.swift"), str(path / "main.swift"), "-o", str(exe)], env=ENV, capture_output=True, text=True)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(exe)], env=ENV, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_face_uses_bounded_two_line_presentation(self):
        source = (ROOT / "Margherita/OverlayController.swift").read_text()
        face = source[source.index("@ViewBuilder private func sectorView"):source.index("    private func hub")]
        self.assertIn("Text(WheelLabelLayout.text(item.label))", face)
        self.assertIn(".lineLimit(2).minimumScaleFactor(0.5)", face)
        self.assertIn(".multilineTextAlignment(.center)", face)
        self.assertIn(".padding(.horizontal, 2)", face)
        self.assertIn(".clipped()", face)
        self.assertIn(".accessibilityLabel(item.label)", face)
        self.assertNotIn("@State", source)

if __name__ == "__main__":
    unittest.main()
