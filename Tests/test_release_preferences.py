"""Persisted values may have the wrong type after defaults CLI edits/older builds."""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]
class PersistedPreferences(unittest.TestCase):
    def test_string_preferences_never_force_unwrap(self):
        text = (ROOT / "Margherita/Preferences.swift").read_text()
        self.assertFalse(re.search(r'defaults\.string\(forKey: "[^"]+"\)!', text))
        self.assertIn('defaults.string(forKey: "trigger") ?? "shift"', text)
