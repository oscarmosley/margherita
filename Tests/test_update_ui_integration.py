from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1] / "Margherita"

class UpdateUIIntegration(unittest.TestCase):
    def test_start_after_launch(self):
        source = (ROOT / "MargheritaApp.swift").read_text()
        launch = source.split("func applicationDidFinishLaunching", 1)[1].split("func applicationShouldTerminate", 1)[0]
        self.assertIn("UpdateController.shared.start()", launch)

    def test_both_menus_offer_check(self):
        source = (ROOT / "MargheritaApp.swift").read_text()
        self.assertEqual(source.count('addItem("Check for Updates…"'), 2)
        self.assertIn("UpdateController.shared.checkForUpdates()", source)

    def test_general_uses_observed_controller_and_actual_configuration(self):
        source = (ROOT / "Views.swift").read_text()
        self.assertIn("@ObservedObject private var updater = UpdateController.shared", source)
        self.assertIn('Toggle("Automatically check for updates"', source)
        self.assertIn("set: { updater.automaticallyChecksForUpdates = $0 }", source)
        self.assertIn(".disabled(!updater.isConfigured)", source)
        self.assertIn("SettingsCaption(updater.statusMessage)", source)

if __name__ == "__main__":
    unittest.main()
