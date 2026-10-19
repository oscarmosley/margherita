"""v8 source contracts. Real click/scroll behavior still needs a Mac."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class V8Tables(unittest.TestCase):
    def test_formats_row_has_full_width_hit_shape(self):
        s = (ROOT / "Margherita/FormatSettingsViews.swift").read_text()
        row = s[s.index("private func row(_ item:"):s.index("// MARK: - Detail")]
        self.assertIn(".frame(maxWidth: .infinity, alignment: .leading)", row)
        self.assertIn(".contentShape(Rectangle())", row)
        self.assertLess(row.index(".frame(maxWidth:"), row.index(".contentShape("))
    def test_compatibility_has_one_scroll_owner(self):
        s = (ROOT / "Margherita/Views.swift").read_text()
        s = s[s.index("struct CompatibilityTab"):s.index("// MARK: Permissions")] + (ROOT / "Margherita/CompatibilityMatrix.swift").read_text()
        self.assertEqual(s.count("ScrollView {"), 1)
        self.assertNotIn("ScrollView(.horizontal", s)
        self.assertNotIn("columnPages", s)
        self.assertNotIn("Output formats ", s)
        self.assertIn("MatrixStaticGrid(table: table", s)
        self.assertIn(".rotationEffect(.degrees(-90))", s)
        self.assertIn(".frame(width: cellWidth, height: MatrixMetrics.rowHeight)", s)
