"""Support entry point source contracts, not a native UI/browser integration test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SupportLink(unittest.TestCase):
    def test_explicit_browser_handler(self):
        source = (ROOT / "Margherita/MargheritaApp.swift").read_text()
        handler = source.split("@objc func openSupport()", 1)[1].split("\n    }", 1)[0]
        self.assertIn('guard let url = URL(string: "https://buymeacoffee.com/oscarmosley")', handler)
        self.assertIn("NSWorkspace.shared.open(url)", handler)
        self.assertEqual(source.count('#selector(openSupport)'), 2)
        self.assertIn('addItem("Support Margherita", #selector(openSupport), to: menu)', source)

    def test_tasteful_about_button(self):
        source = (ROOT / "Margherita/Views.swift").read_text().split("struct AboutTab: View", 1)[1].split("@MainActor", 1)[0]
        self.assertIn('Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")', source)
        self.assertIn("AppDelegate.shared?.openSupport()", source)
        self.assertIn(".tint(Color(nsColor: prefs.accentNS))", source)
        self.assertIn(".buttonStyle(.bordered)", source)
        self.assertNotIn("Support isn’t available yet", source)
        self.assertNotIn("@State", source)

    def test_readme_link(self):
        source = (ROOT / "README.md").read_text()
        self.assertIn('href="https://buymeacoffee.com/oscarmosley"', source)
        self.assertNotIn("buymeacoffee.com/YOURNAME", source)
