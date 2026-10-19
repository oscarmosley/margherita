"""UI source contracts; native controls/window execution requires macOS."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1] / "Margherita"

class WatchUIIntegration(unittest.TestCase):
    def test_start_only_after_capability_discovery(self):
        source = (ROOT / "FormatCapabilities.swift").read_text()
        self.assertLess(source.index("outputsByInput = snapshot.outputs"), source.index("WatchFolders.shared.start()"))
        self.assertLess(source.index("isLoading = false"), source.index("WatchFolders.shared.start()"))
        app = (ROOT / "MargheritaApp.swift").read_text()
        self.assertNotIn("WatchFolders.shared.start()", app)
        self.assertIn("WatchFolders.shared.stop()", app)

    def test_folders_contains_watch_section(self):
        source = (ROOT / "Views.swift").read_text() + (ROOT / "WatchFolderViews.swift").read_text()
        folders = source.split("struct FoldersTab:", 1)[1].split("private var destinationRows", 1)[0]
        self.assertIn("WatchFolderSettings()", folders)
        self.assertIn("ForEach(watcher.rules)", source)
        self.assertIn("binding(\\.enabled)", source)
        self.assertIn("binding(\\.targetFormat)", source)
        self.assertIn("binding(\\.includeSubfolders)", source)
        self.assertIn("binding(\\.suffix)", source)

    def test_default_keep_and_confirmation_required_to_trash(self):
        source = (ROOT / "Views.swift").read_text() + (ROOT / "WatchFolderViews.swift").read_text()
        add = source.split("private func addFolder()", 1)[1].split("struct WatchFolderRuleEditor", 1)[0]
        self.assertIn("deleteOriginal: false", add)
        confirm = source.split("private func setDeleteOriginal", 1)[1].split("private func chooseDestination", 1)[0]
        self.assertIn('alert.addButton(withTitle: "Keep originals")', confirm)
        self.assertIn("guard alert.runModal() == .alertSecondButtonReturn else { return }", confirm)
        self.assertLess(confirm.index("guard alert.runModal()"), confirm.index("wrappedValue = enabled"))

    def test_open_outputs_opens_reserved_folder_or_parent(self):
        source = (ROOT / "WatchFolderViews.swift").read_text()
        action = source.split('Button("Open outputs")', 1)[1].split('Button("Choose…"', 1)[0]
        self.assertIn('appendingPathComponent(".Margherita Outputs", isDirectory: true)', action)
        self.assertIn("fileExists(atPath: outputs.path)", action)
        self.assertIn("NSWorkspace.shared.open(outputs)", action)
        self.assertIn("NSWorkspace.shared.open(parent)", action)

    def test_output_caption_explains_reserved_hidden_subfolder(self):
        source = (ROOT / "WatchFolderViews.swift").read_text()
        self.assertIn("reserved hidden .Margherita Outputs subfolder of the chosen output folder", source)
        self.assertIn("current.destinationPath = destination.path", source)
        self.assertIn("current.profiles[canonical] = settings", source)

    def test_rule_profiles_snapshot_and_destination_permission(self):
        source = (ROOT / "Views.swift").read_text() + (ROOT / "WatchFolderViews.swift").read_text()
        self.assertIn("profiles: Preferences.shared.options.formatProfiles", source)
        self.assertIn("current.profiles[canonical] = settings", source)
        self.assertIn('Button("Copy current format defaults")', source)
        self.assertIn("current.destinationBookmark = try destination.bookmarkData", source)
        self.assertIn("panel.canCreateDirectories = true", source)
        for key in ("imageQuality", "maxDimension", "videoQuality", "audioBitrate", "gifFPS", "archiveCompression"):
            self.assertIn("profile(\\." + key + ")", source)

if __name__ == "__main__":
    unittest.main()
