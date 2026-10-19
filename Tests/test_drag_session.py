"""Execute the production paging policy; assert drag source/option snapshot contracts."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Margherita/OverlayController.swift").read_text()

class DragSessionTests(unittest.TestCase):
    def test_initial_hub_never_flips_to_gzip_overflow(self):
        helper = SOURCE.split("struct WheelPagingGate {", 1)[1].split("/// All modes share", 1)[0]
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            main.write_text("import Foundation\nstruct WheelPagingGate {" + helper + """
var gate = WheelPagingGate()
for t in [0.0, 0.01, 0.8, 4.0, 20.0] {
    precondition(!gate.shouldAdvance(inHub: true, now: t))
}
precondition(!gate.shouldAdvance(inHub: false, now: 21))
precondition(!gate.shouldAdvance(inHub: true, now: 22))
precondition(!gate.shouldAdvance(inHub: false, now: 22.1))
precondition(!gate.shouldAdvance(inHub: true, now: 23))
precondition(!gate.shouldAdvance(inHub: true, now: 23.5))
precondition(gate.shouldAdvance(inHub: true, now: 23.8))
precondition(!gate.shouldAdvance(inHub: true, now: 30))
precondition(!gate.shouldAdvance(inHub: false, now: 31))
precondition(!gate.shouldAdvance(inHub: true, now: 32))
precondition(gate.shouldAdvance(inHub: true, now: 33))
""")
            env = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
            compiler = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
            binary = str(Path(folder) / "paging")
            subprocess.run([compiler, "-swift-version", "5", str(main), "-o", binary],
                           env=env, check=True, capture_output=True)
            subprocess.run([binary], env=env, check=True, capture_output=True)

    def test_active_drag_skips_pasteboard_reresolution(self):
        handler = SOURCE.split("private func handle(", 1)[1].split("private func show(", 1)[0]
        active = handler.split("if !previewURLs.isEmpty {", 1)[1].split("guard let mode else", 1)[0]
        self.assertIn("wheel.setMode(mode, urls: previewURLs)", active)
        self.assertIn("return", active)
        self.assertNotIn("readObjects", active)
        self.assertNotIn("lastDragCount", SOURCE)
        self.assertIn("dragActive = false; previewURLs = []", SOURCE)

    def test_hover_and_drop_use_snapshot_not_pasteboard(self):
        wheel = SOURCE.split("final class WheelView", 1)[1]
        drop = wheel.split("override func performDragOperation", 1)[1].split("private func update", 1)[0]
        hover = wheel.split("private func update", 1)[1].split("private func index", 1)[0]
        self.assertNotIn("readObjects", drop)
        self.assertNotIn("Action.available", drop + hover)
        self.assertIn("let files = urls", drop)
        self.assertIn("snapshot.tools : snapshot.conversions", wheel)
        self.assertIn("let list = snapshot.fileActions", wheel)
        self.assertNotIn("Action.available", wheel)
        self.assertNotIn("FileAction.allCases", wheel)

    def test_compiled_snapshot_every_category_and_multifile(self):
        # Compile the actual snapshot, with a resolver spy rather than AppKit.
        # This proves caching/source identity, not native decoder support.
        helper = SOURCE.split("@MainActor\nstruct WheelDragSnapshot {", 1)[1].split("@MainActor\nfinal class WheelView", 1)[0]
        program = r"""
import Foundation
enum Action: Equatable {
    case conversion, tool
    static var calls: [[URL]] = []
    static func available(_ urls: [URL], advanced: Bool) -> [Action] {
        calls.append(urls)
        return [advanced ? .tool : .conversion]
    }
}
enum FileAction: CaseIterable { case airdrop, float, copy, move, copyPath, terminal }
struct WheelDragSnapshot {
"""
        # Remove the actor annotation only so this pure data container can run
        # in a portable synchronous harness. Production remains main-actor owned.
        program += helper + r"""
let extensions = ["jpg","jpeg","png","heic","tiff","gif","webp","avif","bmp","svg","ico",
    "mp4","mov","m4v","mkv","webm","avi","wmv",
    "mp3","m4a","wav","aiff","caf","flac","ogg","opus","wma",
    "pdf","doc","docx","pages","key","ppt","pptx","rtf","rtfd","odt","html","txt","md","epub","webarchive","textclipping",
    "xls","xlsx","numbers","ods","csv","tsv","srt","vtt",
    "zip","tar","tgz","gz","gzip","rar","7z","bz2","xz","unknown"]
var checked = 0
for ext in extensions {
    for count in [1, 2, 20] {
        var urls = (0..<count).map { URL(fileURLWithPath: "/tmp/猫 🍕 source \($0).\(ext)") }
        let expected = urls
        let before = Action.calls.count
        let snapshot = WheelDragSnapshot(urls: urls)
        urls = [URL(fileURLWithPath: "/tmp/wrong.gz")]
        for _ in 0..<30 {
            precondition(snapshot.urls == expected)
            precondition(snapshot.conversions == [.conversion])
            precondition(snapshot.tools == [.tool])
            precondition(snapshot.fileActions == Array(FileAction.allCases))
        }
        precondition(Action.calls.count == before + 2)
        precondition(Action.calls.suffix(2).allSatisfy { $0 == expected })
        checked += 1
    }
}
let mixed = [URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.png")]
precondition(WheelDragSnapshot(urls: mixed).urls == mixed)
print("snapshot cases", checked + 1)
"""
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            main.write_text(program)
            env = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
            compiler = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
            if not Path(compiler).exists():
                self.skipTest("Swift toolchain unavailable")
            binary = str(Path(folder) / "snapshot")
            result = subprocess.run([compiler, "-swift-version", "5", str(main), "-o", binary],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([binary], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("snapshot cases", result.stdout)

    def test_same_mode_does_not_reset_and_all_mode_options_resolved_upfront(self):
        wheel = SOURCE.split("final class WheelView", 1)[1]
        setter = wheel.split("func setMode(", 1)[1].split("override func hitTest", 1)[0]
        self.assertLess(setter.index("self.mode == mode"), setter.index("model.page = 0"))
        self.assertIn("if snapshot == nil", setter)
        snapshot = SOURCE.split("struct WheelDragSnapshot", 1)[1].split("final class WheelView", 1)[0]
        self.assertIn("conversions = Action.available(urls, advanced: false)", snapshot)
        self.assertIn("tools = Action.available(urls, advanced: true)", snapshot)
        self.assertIn("fileActions = Array(FileAction.allCases)", snapshot)
