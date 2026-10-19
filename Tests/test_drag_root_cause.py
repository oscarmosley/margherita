"""Reproduce the shipped 1.0.0 GZIP-only page using actual route/layout code."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class RootCauseTrace(unittest.TestCase):
    def test_shipped_paging_branch_reproduces_gzip_without_type_changes(self):
        compiler = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
        if not Path(compiler).exists():
            self.skipTest("Swift toolchain unavailable")
        # Verbatim function from shipped commit 65bdad6, bundled so tests also
        # work from a downloaded source ZIP without Git history.
        shipped = (ROOT / "Tests/fixtures/shipped-1.0.0-wheel-update.txt").read_text()
        branch = shipped.split("        if current.pageCount > 1,", 1)[1].split("        let hit =", 1)[0]
        branch = "        if current.pageCount > 1," + branch
        # Execute the exact shipped branch in a portable stand-in, preserving
        # Date.distantPast, page mutation, geometry and its early return.
        geometry = (ROOT / "Margherita/WheelGeometry.swift").read_text()
        geometry = geometry[geometry.index("struct WheelGeometry"):geometry.index("    /// Rounded annular sector")] + "}\n"
        routes = (ROOT / "Margherita/ConversionRoutes.swift").read_text().split("#if os(macOS)", 1)[0]
        fixed = (ROOT / "Margherita/OverlayController.swift").read_text()
        gate = fixed.split("struct WheelPagingGate {", 1)[1].split("/// All modes share", 1)[0]
        program = "import Foundation\n" + routes + geometry + "\nstruct WheelPagingGate {" + gate + r"""
final class Model { var page = 0; var highlighted: Int? = nil }
enum SoundEffects { static func play(_ sound: Sound) {} }
enum Sound { case hover }
struct DragOperation: OptionSet {
    var rawValue: Int
}
final class ShippedWheel {
    var model = Model()
    var lastPageFlip = Date.distantPast
    let items: [String]
    init(items: [String]) { self.items = items }
    func update(_ p: CGPoint) -> DragOperation {
        let current = WheelGeometry(count: items.count, page: model.page, size: 360)
""" + branch + r"""
        return []
    }
    var visible: [String] {
        let g = WheelGeometry(count: items.count, page: model.page, size: 360)
        return g.sectors.map { items[$0.index] }
    }
}
var facts = ConversionRoutes.Facts()
facts.mediaOutputs = ConversionRoutes.videos.union(ConversionRoutes.audio).union(["gif"])
let outputs = ConversionRoutes.outputs(source: "mp4", facts: facts)
precondition(outputs.count == 19)
precondition(outputs.last == "gz")
let old = ShippedWheel(items: outputs)
precondition(old.visible.count == 18)
let unchanged = old.items
_ = old.update(CGPoint(x: 180, y: 180))
precondition(old.model.page == 1)
precondition(old.visible == ["gz"])
precondition(old.items == unchanged) // No URL, type, route or pasteboard changes.
_ = old.update(CGPoint(x: 240, y: 180))
precondition(old.visible == ["gz"])
var fixedGate = WheelPagingGate()
for time in [0.0, 0.1, 0.8, 10.0] {
    precondition(!fixedGate.shouldAdvance(inHub: true, now: time))
}
precondition(!fixedGate.shouldAdvance(inHub: false, now: 11))
precondition(!fixedGate.shouldAdvance(inHub: true, now: 12))
precondition(fixedGate.shouldAdvance(inHub: true, now: 13))
print("MP4 has 19 routes; shipped centre update changes 18 visible choices to GZIP alone without changing type or options.")
"""
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            main.write_text(program)
            binary = str(Path(folder) / "trace")
            env = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
            result = subprocess.run([compiler, "-swift-version", "5", str(main), "-o", binary],
                                    capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([binary], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("without changing type or options", result.stdout)
