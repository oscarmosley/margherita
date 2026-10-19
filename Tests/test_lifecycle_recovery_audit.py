"""Regression contracts; native activation/window behavior still requires macOS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / "Margherita"

class LifecycleRecoveryAudit(unittest.TestCase):
    def test_replay_only_uses_existing_menu_items(self):
        app = (ROOT / "MargheritaApp.swift").read_text()
        views = (ROOT / "Views.swift").read_text()
        self.assertNotIn('Show Getting Started again', views)
        self.assertNotIn('addHelpMenu', app)
        self.assertEqual(app.count('addItem("Getting Started…"'), 2)

    def test_onboarding_stops_demo_timers_and_disables_restoration(self):
        source = (ROOT / "Onboarding.swift").read_text()
        closed = source.split("func windowWillClose", 1)[1].split("// MARK: - Model", 1)[0]
        self.assertIn("model.converterWheel.stop()", closed)
        self.assertIn("model.actionsWheel.stop()", closed)
        self.assertIn("w.isRestorable = false", source)
        self.assertNotIn("removeObject(forKey:", source)

    def test_cancel_is_idle_safe_and_repeated_clicks_do_not_delay_fallback(self):
        source = (ROOT / "AppModel.swift").read_text()
        cancel = source.split("func cancel() {", 1)[1].split("func undo(", 1)[0]
        self.assertIn("guard busy, let batch = activeBatch, !wasCancelled else { return }", cancel)
        self.assertLess(cancel.index("guard busy"), cancel.index("wasCancelled = true"))
        self.assertIn("self.activeBatch == batch", cancel)
        self.assertIn("progressBatch = nil", cancel)

    def test_progress_queued_before_completion_cannot_overwrite_verification(self):
        source = (ROOT / "AppModel.swift").read_text()
        self.assertIn("self.progressBatch == batch", source)
        self.assertIn("if isCurrent { progressBatch = nil; progress = 1 }", source)
        self.assertIn("progressBatch = batch; error = nil", source)
        self.assertIn("guard !busy else { return }\n        let batch = UUID()", source)

if __name__ == "__main__":
    unittest.main()
