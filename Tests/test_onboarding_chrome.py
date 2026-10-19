"""Compile the actual arc helper and verify edge clearance and button spacing."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
class OnboardingChromeTests(unittest.TestCase):
    def test_arc_geometry(self):
        source = (ROOT / "Margherita/Onboarding.swift").read_text()
        helper = source[source.index("enum OnboardingChrome {"):source.index("struct TrafficLights:")]
        with tempfile.TemporaryDirectory() as folder:
            f = Path(folder) / "main.swift"
            f.write_text("import Foundation\n" + helper + """
let points = (0..<3).map { OnboardingChrome.centre($0) }
for point in points {
    let distance = hypot(point.x - 220, point.y - 220)
    precondition(abs((220 - distance - 6.5) - 19) < 0.000001)
    precondition(point.x > 0 && point.x < 145 && point.y > 0 && point.y < 105)
}
for i in 0..<2 {
    precondition(abs(hypot(points[i+1].x - points[i].x, points[i+1].y - points[i].y) - 21) < 0.000001)
    precondition(points[i+1].x > points[i].x && points[i+1].y < points[i].y)
}
""")
            env = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
            compiler = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
            binary = str(Path(folder) / "chrome")
            subprocess.run([compiler, "-swift-version", "5", str(f), "-o", binary], env=env, check=True, capture_output=True)
            subprocess.run([binary], env=env, check=True, capture_output=True)

    def test_chrome_uses_shared_corner_geometry(self):
        source = (ROOT / "Margherita/Onboarding.swift").read_text()
        self.assertIn("host.layer?.cornerRadius = OnboardingChrome.cornerRadius", source)
        self.assertNotIn(".padding(.leading, 140).padding(.top, 62)", source)
        for i in range(3):
            self.assertIn(".position(OnboardingChrome.centre(%s))" % i, source)
        self.assertIn('.buttonStyle(.plain).accessibilityLabel(label)', source)
