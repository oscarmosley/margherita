"""Demo hover shares the live face, animation and hit geometry."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_wheel_geometry import SWIFTC, ENV

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Margherita/Onboarding.swift").read_text()

class OnboardingHover(unittest.TestCase):
    def test_all_demos_use_pointer_driven_real_face(self):
        self.assertEqual(SOURCE.count("DemoWheel(st:"), 2)
        demo = SOURCE.split("struct DemoWheel:", 1)[1].split("// Keyboard:", 1)[0]
        self.assertIn("WheelFaceView(model: st.model)", demo)
        self.assertIn(".onContinuousHover", demo)
        self.assertIn("case .active(let location): st.hover(at: location)", demo)
        self.assertIn("case .ended: st.clearHover()", demo)
        self.assertIn(".onDisappear { st.stop() }", demo)
        state = SOURCE.split("final class WheelState:", 1)[1]
        self.assertNotIn("Timer", state)
        self.assertIn("func stop() {\n        clearHover()", state)
        face = (ROOT / "Margherita/OverlayController.swift").read_text()
        self.assertIn(".animation(.easeOut(duration: 0.12), value: model.highlighted)", face)

    def test_actual_hover_method_hits_every_demo_sector_and_clears(self):
        if not Path(SWIFTC).exists():
            self.skipTest("swiftc unavailable")
        geometry = (ROOT / "Margherita/WheelGeometry.swift").read_text()
        geometry = "import Foundation\n" + geometry[geometry.index("struct WheelGeometry"):geometry.index("    /// Rounded annular sector")] + "}\n"
        methods = SOURCE[SOURCE.index("    func hover(at location:"):SOURCE.index("    func start() {", SOURCE.index("final class WheelState"))]
        stub = """import Foundation
class DemoModel {
    var side: CGFloat = 270
    var count = 7
    var highlighted: Int?
    var geometry: WheelGeometry { WheelGeometry(count: count, page: 0, size: side) }
}
class DemoState {
    let model = DemoModel()
""" + methods + "}\n"
        main = """
import Foundation
let demo = DemoState()
for count in [6, 7] {
    demo.model.count = count
    let g = demo.model.geometry
    for sector in g.sectors {
        let location = CGPoint(x: g.size / 2 + sector.midRadius * cos(sector.mid),
                               y: g.size / 2 - sector.midRadius * sin(sector.mid))
        demo.hover(at: location)
        precondition(demo.model.highlighted == sector.index, "wrong demo sector")
        demo.clearHover()
        precondition(demo.model.highlighted == nil, "exit must clear")
    }
    demo.hover(at: CGPoint(x: 135, y: 135))
    precondition(demo.model.highlighted == nil, "hub")
    demo.hover(at: CGPoint(x: 0, y: 0))
    precondition(demo.model.highlighted == nil, "outside disc")
}
print("Every convert/actions sector and clearing passed")
"""
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "Geometry.swift").write_text(geometry)
            (t / "State.swift").write_text(stub)
            (t / "main.swift").write_text(main)
            exe = t / "hover"
            c = subprocess.run([SWIFTC, str(t / "Geometry.swift"), str(t / "State.swift"), str(t / "main.swift"), "-o", str(exe)], env=ENV, capture_output=True, text=True)
            self.assertEqual(c.returncode, 0, c.stderr)
            p = subprocess.run([str(exe)], env=ENV, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

if __name__ == "__main__":
    unittest.main()
