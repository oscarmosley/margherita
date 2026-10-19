"""Compile the real layout/hit-test code with Foundation; rendering still needs macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))

MAIN = r"""
import Foundation
var failures = 0
func check(_ ok: Bool, _ name: String) {
    if !ok { print("FAIL " + name); failures += 1 }
}
var checked = 0
for size: CGFloat in [320, 360, 460] {
    for count in 0...120 {
        let pages = max(1, (count + WheelGeometry.pageSize - 1) / WheelGeometry.pageSize)
        for page in 0..<pages {
            let g = WheelGeometry(count: count, page: page, size: size)
            check(g.pageCount == pages, "page count")
            check(g.sectors.count <= 18, "page bound")
            check(g.sectorIndex(at: CGPoint(x: size / 2, y: size / 2)) == nil, "hub is not an action")
            check(g.sectorIndex(at: CGPoint(x: size * 2, y: size * 2)) == nil, "outside is not an action")
            for s in g.sectors {
                let p = CGPoint(x: size / 2 + s.midRadius * cos(s.mid), y: size / 2 + s.midRadius * sin(s.mid))
                check(g.sectorIndex(at: p) == s.index, "sector midpoint count=\(count) page=\(page) index=\(s.index)")
                check(s.index >= page * 18 && s.index < count, "global item mapping")
                check(s.innerRadius > g.hubRadius && s.outerRadius < size / 2, "bounded radii")
                check(s.hi > s.lo && s.outerRadius > s.innerRadius, "positive sector")
                checked += 1
            }
        }
    }
}
check(WheelGeometry(count: 40, page: -1, size: 360).page == 0, "negative page clamps")
check(WheelGeometry(count: 40, page: 999, size: 360).page == 2, "large page clamps")
print("Checked \(checked) sector mappings")
exit(failures == 0 ? 0 : 1)
"""
class WheelLayout(unittest.TestCase):
    def test_layout_and_hit_mapping(self):
        if not Path(SWIFTC).exists():
            self.skipTest("swiftc unavailable")
        source = (ROOT / "Margherita/WheelGeometry.swift").read_text()
        # Keep the exact struct through all pure layout/hit functions.
        source = "import Foundation\n" + source[source.index("struct WheelGeometry"):source.index("    /// Rounded annular sector")] + "}\n"
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "Layout.swift").write_text(source)
            (t / "main.swift").write_text(MAIN)
            exe = t / "geometry"
            c = subprocess.run([SWIFTC, str(t / "Layout.swift"), str(t / "main.swift"), "-o", str(exe)], env=ENV, capture_output=True, text=True)
            self.assertEqual(c.returncode, 0, c.stderr)
            p = subprocess.run([str(exe)], env=ENV, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
if __name__ == "__main__":
    unittest.main()
