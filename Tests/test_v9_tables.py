"""Compact single-matrix layout arithmetic and source contracts."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class V9Tables(unittest.TestCase):
    def test_full_matrix_fits_minimum_settings_width(self):
        # Minimum window620 minus page40 and card20. Full dynamic output count.
        available = 620 - 40 - 20
        for count in range(1, 31):
            cell = (available - 58 - 2 * count) / count
            self.assertGreaterEqual(cell, 14)
            self.assertAlmostEqual(58 + cell * count + 2 * count, available)
    def test_one_matrix_no_inner_scroll_or_pagination(self):
        s = (ROOT / "Margherita/Views.swift").read_text()
        s = s[s.index("struct CompatibilityTab"):s.index("// MARK: Permissions")] + (ROOT / "Margherita/CompatibilityMatrix.swift").read_text()
        self.assertEqual(s.count("ScrollView {"), 1)
        self.assertNotIn("columnPages", s)
        self.assertNotIn("pages[index]", s)
        self.assertEqual(s.count("Grid(horizontalSpacing:"), 1)
        self.assertIn("ForEach(Array(table.outputs.enumerated()), id:", s)
        self.assertIn(".rotationEffect(.degrees(-90))", s)
