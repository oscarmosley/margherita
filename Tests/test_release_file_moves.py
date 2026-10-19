"""Run production move/rollback helpers against real files with Unicode paths."""
from test_file_actions import ROOT, SWIFTC, ENV, function
from pathlib import Path
import subprocess
import tempfile
import unittest

class ReleaseMoveTests(unittest.TestCase):
    def test_move_collision_symlinks_and_rollback(self):
        source = (ROOT / "Margherita/FileActions.swift").read_text()
        pure = "import Foundation\nenum Logic {\n"
        for sig in ("nonisolated static func moveItems(", "nonisolated private static func uniqueURL("):
            pure += function(source, sig) + "\n"
        pure += "}\n"
        main = r"""
import Foundation
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let src = root.appendingPathComponent("résumé 📁")
let dest = root.appendingPathComponent("目标 folder")
try fm.createDirectory(at: src, withIntermediateDirectories: true)
try fm.createDirectory(at: dest, withIntermediateDirectories: true)
let name = "hello résumé 🐈.TXT"
let original = src.appendingPathComponent(name)
let existing = dest.appendingPathComponent(name)
try Data("new".utf8).write(to: original)
try Data("old".utf8).write(to: existing)
precondition(Logic.moveItems([original], to: dest) == nil)
let renamed = dest.appendingPathComponent("hello résumé 🐈 2.TXT")
let old = try String(contentsOf: existing)
let new = try String(contentsOf: renamed)
precondition(old == "old" && new == "new")
let again = src.appendingPathComponent("rollback.txt")
try Data("restore".utf8).write(to: again)
precondition(Logic.moveItems([again, src.appendingPathComponent("missing")], to: dest) != nil)
precondition(fm.fileExists(atPath: again.path))
precondition(!fm.fileExists(atPath: dest.appendingPathComponent("rollback.txt").path))
let link = dest.appendingPathComponent("link.txt")
try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent-margherita")
let input = src.appendingPathComponent("link.txt")
try Data("preserved".utf8).write(to: input)
precondition(Logic.moveItems([input], to: dest) == nil)
let contents = try String(contentsOf: dest.appendingPathComponent("link 2.txt"))
precondition(contents == "preserved")
precondition((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
"""
        with tempfile.TemporaryDirectory(prefix="margherita move ") as tmp:
            folder = Path(tmp)
            (folder / "Logic.swift").write_text(pure)
            (folder / "main.swift").write_text(main)
            exe = str(folder / "move")
            result = subprocess.run([SWIFTC, "-swift-version", "5", str(folder/"Logic.swift"), str(folder/"main.swift"), "-o", exe], env=ENV, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([exe, str(folder)], env=ENV, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_filesystem_work_is_detached(self):
        source = (ROOT / "Margherita/FileActions.swift").read_text()
        self.assertIn('Task.detached(priority: .userInitiated)', source)
        self.assertIn('guard !moving', source)

if __name__ == "__main__":
    unittest.main()
