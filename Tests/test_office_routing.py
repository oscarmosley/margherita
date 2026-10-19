"""Source contracts only. Installed Office scripting requires Mac smoke testing."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class OfficeRouting(unittest.TestCase):
    def test_preferred_engines_before_native(self):
        text = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        body = text[text.index("static func convertReporting"):text.index("private static func convertNative")]
        self.assertLess(body.index("OfficeApplications.convert("), body.index("officeExport("))
        self.assertLess(body.index("officeExport("), body.index("try convertNative("))
        self.assertIn("try Task.checkCancellation()", body)
        self.assertIn("app export unavailable", body)
    def test_libreoffice_pdf_import_has_explicit_filter(self):
        text = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        self.assertIn('--infilter=writer_pdf_import', text)
        self.assertIn('docx:Office Open XML Text', text)
        self.assertIn('validated-output/word/document.xml', text)
        self.assertIn('(deny network*)', text)
        self.assertIn('MacroSecurityLevel', text)
    def test_success_uses_actual_engines_after_install(self):
        engine = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        self.assertLess(engine.index("let backup = try install("), engine.index("result.engines.append"))
        self.assertIn("convertReporting(input: first", engine)
        model = (ROOT / "Margherita/AppModel.swift").read_text()
        self.assertIn('result.engines.joined(separator: ", ")', model)
        self.assertIn("ConversionHUD.shared.succeed(status)", model)
    def test_automation_copy_discloses_fallback_and_privacy(self):
        text = (ROOT / "Margherita/Views.swift").read_text()
        for fragment in ['private var automationRows: some View', 'Privacy_Automation', 'Cancel any offer to upload', 'Denying access falls back', 'not sandboxed']:
            self.assertIn(fragment, text)
if __name__ == "__main__": unittest.main()
