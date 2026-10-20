"""Clipboard routing/lifecycle guards plus real AppKit pasteboard probes on macOS."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLIP = (ROOT / "Margherita/ClipboardConversion.swift").read_text()
APP = (ROOT / "Margherita/AppModel.swift").read_text()
MENU = (ROOT / "Margherita/MargheritaApp.swift").read_text()

class ClipboardConversionTests(unittest.TestCase):
    def test_menu_probe_is_lazy_and_prefers_finder_files(self):
        probe = CLIP.split("static func inspect", 1)[1].split("var convertible", 1)[0]
        self.assertLess(probe.index("if !files.isEmpty"), probe.index("let preferred"))
        self.assertNotIn("data(forType:", probe)
        self.assertNotIn("NSImage(", CLIP)
        for uti in ["public.png", "public.tiff", "public.heic", "public.heif", "com.adobe.pdf",
                    "public.rtf", "public.html", "public.utf8-plain-text"]:
            self.assertIn(uti, probe)
        self.assertIn("Action.available(routeURLs)", CLIP)

    def test_menu_rebuilds_and_checks_clipboard_snapshot(self):
        self.assertIn("ClipboardConversion.shared.refresh(clipboardItem)", MENU)
        self.assertIn("menu.autoenablesItems = false", MENU)
        self.assertIn("nothing convertible", CLIP)
        self.assertIn("no supported formats", CLIP)
        self.assertIn("conversion in progress", CLIP)
        self.assertGreaterEqual(CLIP.count("board.changeCount == descriptor.changeCount"), 2)
        self.assertIn("AppModel.shared.run(action, urls: descriptor.urls)", CLIP)

    def test_private_staging_cleanup_cancellation_and_default_destination(self):
        self.assertIn("attributes: [.posixPermissions: 0o700]", CLIP)
        self.assertIn("try data.write(to: url, options: .atomic)", CLIP)
        self.assertEqual(CLIP.count("try ConversionCancellation.current?.check()"), 2)
        self.assertIn("defer { clipboard?.clean() }", APP)
        self.assertLess(APP.index("try clipboard?.stage()"), APP.index("return await engine.run"))
        self.assertIn("Could not prepare the clipboard:", APP)
        self.assertIn(".downloadsDirectory", APP)
        self.assertIn('if preferences.location == "folder", !preferences.folder.isEmpty', APP)
        self.assertIn("let snapshot = options", APP)

    def test_result_cannot_clobber_new_clipboard_or_publish_cancelled_output(self):
        self.assertIn("guard board.changeCount == changeCount", CLIP)
        self.assertIn("outputs.count == 1", CLIP)
        self.assertIn("options: .mappedIfSafe", CLIP)
        self.assertIn("if activeBatch == batch, !wasCancelled", APP)
        self.assertIn("if let clipboard, !wasCancelled, result.notes.isEmpty", APP)

    @unittest.skipUnless(platform.system() == "Darwin", "AppKit integration needs macOS")
    def test_real_pasteboard_formats_and_finder_priority(self):
        # Compile the exact production descriptor against AppKit. No general
        # clipboard is touched, and no full-app singleton is needed.
        descriptor = CLIP[CLIP.index("struct ClipboardDescriptor"):CLIP.index("/// Immutable input")]
        descriptor = descriptor.replace("var actions: [Action] { convertible ? Action.available(routeURLs) : [] }", "")
        harness = r"""
import AppKit
import Foundation
extension URL {
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
}
""" + descriptor + r"""
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
for (name, ext) in [("public.png", "png"), ("public.tiff", "tiff"),
                    ("public.heic", "heic"), ("com.adobe.pdf", "pdf"),
                    ("public.rtf", "rtf"), ("public.utf8-plain-text", "txt")] {
    board.clearContents()
    board.setData(Data([1,2,3]), forType: NSPasteboard.PasteboardType(name))
    let descriptor = ClipboardDescriptor.inspect(board)
    precondition(descriptor.ext == ext)
    precondition(descriptor.convertible)
    precondition(descriptor.changeCount == board.changeCount)
}
let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
try Data([1]).write(to: file)
defer { try? FileManager.default.removeItem(at: file) }
board.clearContents()
board.writeObjects([file as NSURL])
board.setData(Data([1]), forType: .tiff)
precondition(ClipboardDescriptor.inspect(board).urls == [file])
board.clearContents()
precondition(!ClipboardDescriptor.inspect(board).convertible)
print("Private AppKit pasteboard probes passed")
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / "main.swift").write_text(harness)
            result = subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "probe")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(path / "probe")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
