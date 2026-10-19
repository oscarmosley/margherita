"""Source contracts for onboarding. Native window behavior still needs a Mac smoke test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ONBOARDING = (ROOT / "Margherita/Onboarding.swift").read_text()
APP = (ROOT / "Margherita/MargheritaApp.swift").read_text()

class OnboardingV8Tests(unittest.TestCase):
    def test_fresh_completion_key_not_old_shown_flags(self):
        self.assertIn('bool(forKey: "onboardingCompletedV2")', APP)
        self.assertNotIn('onboardingShownV6', APP + ONBOARDING)
        self.assertNotIn('onboardingCompletedV6', APP + ONBOARDING)

    def test_show_never_marks_completed(self):
        show = ONBOARDING.split('func show() {', 1)[1].split('private var retired', 1)[0]
        self.assertNotIn('UserDefaults.standard.set', show)
        closed = ONBOARDING.split('func windowWillClose', 1)[1].split('// MARK: - Model', 1)[0]
        self.assertIn('closing === window', closed)
        self.assertIn('set(true, forKey: "onboardingCompletedV2")', closed)
        self.assertLess(closed.index('window = nil'), closed.index('onClose?()'))
        self.assertIn('DispatchQueue.main.async { [weak self] in self?.onClose?() }', closed)

    def test_regular_policy_before_show_and_restore_on_close(self):
        show = ONBOARDING.split('func show()', 1)[1].split('private var retired', 1)[0]
        self.assertLess(show.index('setActivationPolicy(.regular)'), show.index('makeKeyAndOrderFront'))
        self.assertIn('w.deminiaturize(nil)', show)
        self.assertIn('onClose = { [weak self] in self?.refreshActivationPolicy() }', APP)
        self.assertIn('? .regular : .accessory', APP)

    def test_manual_setup_remains_in_both_menus(self):
        self.assertEqual(APP.count('addItem("Getting Started…"'), 2)

    def test_single_tomato_folder_outline(self):
        folder = ONBOARDING.split('private var folder:', 1)[1].split('private var finishPage:', 1)[0]
        self.assertIn('FolderSilhouette()', folder)
        self.assertNotIn('Color.basil', folder)
        self.assertIn('WheelPalette.cream', folder)
        self.assertIn('p.closeSubpath()', ONBOARDING)

    def test_no_clt_incompatible_state_macros(self):
        for token in ('@State ', '@StateObject', '@Observable', '#Preview'):
            self.assertNotIn(token, ONBOARDING + APP)

if __name__ == '__main__':
    unittest.main()
