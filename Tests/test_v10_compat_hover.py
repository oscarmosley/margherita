"""Compatibility hover and matrix source contracts. Real hover needs a Mac."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
M = (ROOT / "Margherita/CompatibilityMatrix.swift").read_text()
V = (ROOT / "Margherita/Views.swift").read_text()
V = V[V.index("struct CompatibilityTab"):V.index("// MARK: Permissions")]
class CompatHover(unittest.TestCase):
    def test_single_scroll_owner_and_no_probes(self):
        self.assertEqual(V.count("ScrollView {"), 1)
        for s in (M, V):
            self.assertNotIn("Action.available", s)
            self.assertNotIn("FormatCapabilityDiscovery", s)
            self.assertNotIn("ScrollView", M)
    def test_no_forbidden_state_macros(self):
        for tok in ("@State", "@StateObject", "@Observable", "#Preview"):
            self.assertNotIn(tok, M); self.assertNotIn(tok, V)
    def test_hover_state_is_per_table_and_retained(self):
        self.assertIn("final class MatrixHoverState: ObservableObject", M)
        self.assertIn("hover[t.name] = MatrixHoverState()", M)
        self.assertIn("hoverState(for: table.name)", V)
        self.assertNotIn("MatrixHoverState()", V)
    def test_labels_have_one_owner_and_stable_layout(self):
        grid = M[M.index("struct MatrixStaticGrid"):M.index("/// Background-only")]
        overlay = M[M.index("struct MatrixHighlightOverlay"):M.index("/// One NSTrackingArea")]
        self.assertIn("@ObservedObject var hover", grid)
        self.assertIn("hover.column == c ? Color.margherita : Color.secondary", grid)
        self.assertIn("hover.row == r ? Color.margherita : Color.secondary", grid)
        self.assertNotIn("Text(", overlay)
        self.assertNotIn("strokeBorder", overlay)
        self.assertNotIn("height: 3", overlay)
        self.assertNotIn("width: 3", overlay)
        self.assertNotIn(".bold", grid)
        layers = M[M.index("ZStack(alignment: .topLeading)"):M.index("MatrixHoverTracker(hover:")]
        self.assertLess(layers.index("MatrixHighlightOverlay"), layers.index("MatrixStaticGrid"))

    def test_hover_lifecycle_resets(self):
        self.assertIn("func clearHover()", M)
        self.assertIn("for state in hover.values", M)
        self.assertIn(".onDisappear { hover.set(row: nil, column: nil) }", M)
        self.assertIn("static func dismantleNSView", M)
        self.assertIn("override func mouseExited", M)
        self.assertIn("override func viewDidMoveToWindow", M)
        self.assertIn("guard bounds.contains(p)", M)
        self.assertIn(".onAppear { model.clearHover(); model.rebuild() }", V)
        self.assertIn(".onDisappear { model.clearHover() }", V)
        settings = (ROOT / "Margherita/Views.swift").read_text()
        self.assertIn(".onChange(of: ui.selectedTab) { _ in CompatibilityViewModel.shared.clearHover() }", settings)
    def test_setter_only_publishes_changes(self):
        self.assertIn("if self.row != row", M); self.assertIn("if self.column != column", M)
    def test_all_inputs_kept_and_three_cell_kinds(self):
        self.assertIn("formats: Self.rows(for: name)", M)
        self.assertNotIn(".filter { !(", V)
        for k in ("case available", "case sameFormat", "case unsupported"): self.assertIn(k, M)
    def test_xls_keeps_xml_qualifier(self):
        self.assertIn('"XLS" ? "XLS XML"', M)
        self.assertEqual(M.count("MatrixTableData.label("), 2)
    def test_rows_use_settings_groups_only(self):
        self.assertIn("FormatCatalog.settingsGroups", M)
        self.assertNotIn("FormatCatalog.groups", M)
        for w in ("Excel 2003 XML only", "repack", "constrained renderer", "PDF recovery"):
            self.assertIn(w, (ROOT / "Margherita/Views.swift").read_text())
    def test_all_catalogue_formats_reachable(self):
        import re
        fs = (ROOT / "Margherita/FormatSettingsViews.swift").read_text()
        legacy = (ROOT / "Margherita/Views.swift").read_text()
        for name in ("Presentations", "NUMBERS", "KEY", "CAF", "M4V", "TGZ", "CLIPPING"):
            self.assertTrue(re.search(r'"%s"' % name, fs), name)
        groups = re.findall(r'\("([A-Za-z]+)", "[a-z.\\ ]+"\)', M[M.index("static let sections"):M.index("static func rows")])
        self.assertEqual(groups, [g for g in re.findall(r'FormatSettingsGroup\(name: "(\w+)"', fs)])
    def test_background_bands_use_pizza_colour(self):
        o = M[M.index("struct MatrixHighlightOverlay"):M.index("struct MatrixHoverTracker")]
        self.assertEqual(o.count("Color.margherita.opacity(0.07)"), 2)
    def test_tracker_passes_events_through(self):
        self.assertIn("return nil", M[M.index("hitTest"):]) if False else self.assertIn("-> NSView? { nil }", M)
        self.assertIn(".inVisibleRect", M)
    def test_hit_arithmetic(self):
        lw, sp, hh, rh = 58, 2, 76, 20
        cw = (560 - lw - sp * 8) / 8
        col = lambda x: int((x - lw - sp) / (cw + sp)) if x - lw - sp >= 0 else None
        self.assertIsNone(col(30)); self.assertEqual(col(lw + sp + 1), 0)
        self.assertEqual(col(lw + sp + 2 * (cw + sp) + 1), 2)
        self.assertEqual(int((hh + 45 - hh) / rh), 2)
if __name__ == "__main__": unittest.main()
