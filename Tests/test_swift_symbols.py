"""Missing-view regression guard. These tests do not replace a Mac SDK build."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit', ROOT / 'scripts/audit-swift-symbols.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

class SymbolAuditTests(unittest.TestCase):
    def test_all_swift_sources_have_resolved_lexical_symbols(self):
        result = audit.audit(ROOT)
        self.assertEqual(len(result['files']), len(list((ROOT / 'Margherita').glob('*.swift'))))
        for name, values in result.items():
            if name.startswith('unknown_'):
                self.assertEqual(values, [], name)

    def test_missing_views_are_not_platform_symbols(self):
        for name in ['SuccessBurst', 'ShortcutRow', 'AccentPicker']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / 'Margherita').mkdir()
                (root / 'Margherita/Views.swift').write_text('import SwiftUI\nlet sample = ' + name + '()')
                self.assertIn(name, audit.audit(root)['unknown_capitalized_identifiers'])

    def test_actual_view_declarations_exist_without_macro_state(self):
        text = (ROOT / 'Margherita/Views.swift').read_text()
        for name in ['SettingsView', 'ShortcutRow', 'AccentPicker']:
            self.assertIn('struct ' + name + ': View', text)
        for p in (ROOT / 'Margherita').glob('*.swift'):
            for macro in ['@State ', '@StateObject', '@Observable ', '#Preview']:
                self.assertNotIn(macro, p.read_text(), str(p))
        self.assertIn('@ObservedObject var recorder: ShortcutRecorder', text)

    def test_missing_project_function_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Margherita').mkdir()
            (root / 'Margherita/Missing.swift').write_text('struct Example {}\nlet x = Example.missingCall()')
            self.assertIn('Example.missingCall', audit.audit(root)['unknown_project_member_calls'])

    def test_interpolated_references_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Margherita').mkdir()
            (root / 'Margherita/Missing.swift').write_text(r'let s = "Call \(MissingView())"')
            self.assertIn('MissingView', audit.audit(root)['unknown_capitalized_identifiers'])

if __name__ == '__main__':
    unittest.main()
