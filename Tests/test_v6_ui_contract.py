"""Source regression contracts. Not macOS rendering or SDK build coverage."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class V6UIContract(unittest.TestCase):
    def source(self, name):
        return (ROOT / "Margherita" / name).read_text()
    def test_home_window_and_drop_zone_removed(self):
        for name in ["Views.swift", "MargheritaApp.swift", "OverlayController.swift"]:
            for obsolete in ["MainView", "openMain", "mainWindow", "MainDropView", "FileDropZone"]:
                self.assertNotIn(obsolete, self.source(name), name)
    def test_tabs_and_real_compatibility(self):
        s = self.source("Views.swift")
        self.assertIn('["General", "Formats", "Compatibility", "Folders", "Permissions", "About"]', s)
        self.assertNotIn("Action.available(", s)
        self.assertIn("FormatCapabilities.shared.outputs(of: input)", s)
        self.assertNotIn('https://github.com/', s)
        for field in ["wheelStyle", "haptics", "floatBehaviour"]:
            self.assertIn("prefs." + field, s)
    def test_options_snapshot_preserves_auto_and_real_fields(self):
        s = self.source("Preferences.swift")
        for field in ["compressionMode", "documentLayout", "videoHeight", "archiveCompression"]:
            self.assertIn("options." + field + " =", s)
        self.assertIn('var documentLayout = "auto"', self.source("Models.swift"))
    def test_cold_about_and_resizable_settings(self):
        s = self.source("MargheritaApp.swift")
        body = s[s.index("@objc func openAbout"):s.index("/// Only settings")]
        self.assertLess(body.index("selectedTab = 5"), body.index("openSettings()"))
        self.assertIn(".resizable", s)
    def test_onboarding_does_not_change_login_on_page_visit(self):
        s = self.source("Onboarding.swift")
        self.assertNotIn(".onAppear { prefs.setLogin", s)
        self.assertNotIn("@State", s)
        self.assertIn("Text(\"2. Hold\")", s)
        self.assertIn("WheelFaceView(model: st.model)", s)
        self.assertIn("converterWheel = WheelState(labels:", s)
    def test_float_mode_routes_without_deleting_files(self):
        s = self.source("ShelfView.swift")
        self.assertIn('floatBehaviour == "reuse"', s)
        self.assertIn("ShelfController(isRoot: false)", s)
        self.assertIn("func windowWillClose", s)
        self.assertNotIn("removeItem", s)
    def test_style_and_haptics_have_real_consumers(self):
        self.assertIn('prefs.wheelStyle != "solid"', self.source("OverlayController.swift"))
        self.assertIn("NSVisualEffectView", self.source("OverlayController.swift"))
        self.assertIn("NSHapticFeedbackManager", self.source("SoundEffects.swift"))
    def test_bookmarks_are_persisted_without_deletion(self):
        s = self.source("FolderAccess.swift")
        for marker in ["withSecurityScope", "bookmarkData", "stopAccessingSecurityScopedResource", "folderAccessBookmarksV6"]:
            self.assertIn(marker, s)
        self.assertNotIn("removeItem", s)
if __name__ == "__main__": unittest.main()
