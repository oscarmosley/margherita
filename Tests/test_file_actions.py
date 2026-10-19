"""Compile and run the exact planMove from FileActions.swift (Foundation only, no AppKit)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))

def function(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]

MAIN = r'''
import Foundation
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
func mk(_ p: String) -> URL { let u = root.appendingPathComponent(p); try! fm.createDirectory(at: u, withIntermediateDirectories: true); return u }
func touch(_ p: String) -> URL { let u = root.appendingPathComponent(p); fm.createFile(atPath: u.path, contents: Data()); return u }
var failures = 0
func check(_ ok: Bool, _ name: String) { if !ok { print("FAIL " + name); failures += 1 } }

let a = mk("a"); let sub = mk("a/sub"); let dest = mk("dest"); let ab = mk("ab")
let f = touch("a/file.txt"); let g = touch("g.txt")
// duplicates
var r = Logic.planMove([g, g, g.standardizedFileURL], to: dest)
check(r.error == nil && r.items.count == 1, "duplicates")
// parent + child: only parent
r = Logic.planMove([f, a], to: dest)
check(r.error == nil && r.items.map { $0.path } == [a.path], "parent-child")
// self
r = Logic.planMove([a], to: a)
check(r.error != nil, "self")
// subdirectory
r = Logic.planMove([a], to: sub)
check(r.error != nil, "subdirectory")
// sibling prefix is fine
r = Logic.planMove([a], to: ab)
check(r.error == nil && r.items.count == 1, "sibling prefix a vs ab")
// already in that folder
r = Logic.planMove([f], to: a)
check(r.error != nil, "same folder")
// selected symlink moves the link, not its target
let link = root.appendingPathComponent("link")
try! fm.createSymbolicLink(at: link, withDestinationURL: a)
r = Logic.planMove([link], to: dest)
check(r.error == nil && r.items.map { $0.path } == [link.path], "symlink identity")
// moving a symlink into its own target is allowed (target is not moved)
r = Logic.planMove([link], to: a)
check(r.error == nil, "symlink into its target")
// real dir reached through symlinked ancestor is still caught
let viaLink = link.appendingPathComponent("sub")
r = Logic.planMove([a], to: viaLink)
check(r.error != nil, "dest via symlink inside source")
print(failures == 0 ? "OK" : "FAILED")
exit(failures == 0 ? 0 : 1)
'''

class PlanMove(unittest.TestCase):
    def test_plan_move(self):
        if not Path(SWIFTC).exists():
            self.skipTest("swiftc unavailable")
        source = (ROOT / "Margherita/FileActions.swift").read_text()
        pure = "import Foundation\nenum Logic {\n" + function(source, "nonisolated static func planMove") + "\n}\n"
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "Logic.swift").write_text(pure)
            (t / "main.swift").write_text(MAIN)
            exe = t / "plan"
            c = subprocess.run([SWIFTC, str(t / "Logic.swift"), str(t / "main.swift"), "-o", str(exe)], env=ENV, capture_output=True, text=True)
            self.assertEqual(c.returncode, 0, c.stderr)
            work = t / "work"; work.mkdir()
            p = subprocess.run([str(exe), str(work)], env=ENV, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

if __name__ == "__main__":
    unittest.main()
