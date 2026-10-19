"""Portable compiled policy tests. FSEvents/bookmarks/real conversions require macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))

class WatchPolicies(unittest.TestCase):
    @unittest.skipUnless(Path(SWIFT).exists(), "Swift compiler unavailable")
    def test_compiled_policies(self):
        harness = r'''
import Foundation
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("photo.jpg")
try Data([1,2,3]).write(to: source)
let stamp = WatchFileStamp.read(source)!
var stability = WatchStability()
let now = Date()
var retry = WatchRetry()
retry.failed(now: now)
assert(retry.nextAttempt == now.addingTimeInterval(2))
for _ in 0..<20 { retry.failed(now: now) }
assert(retry.nextAttempt == now.addingTimeInterval(300))
assert(!WatchPathPolicy.allowedRoot(root.appendingPathComponent(".Margherita Outputs")))
assert(!WatchPathPolicy.allowedRoot(root.appendingPathComponent(".Margherita Outputs/child")))
assert(!WatchPathPolicy.allowedRoot(root.appendingPathComponent(".hidden/child")))
assert(WatchPathPolicy.sameStagedIdentity(stamp, stamp))

assert(!stability.sample(stamp, now: now))
assert(!stability.sample(stamp, now: now.addingTimeInterval(1)))
assert(stability.sample(stamp, now: now.addingTimeInterval(2)))
let changed = WatchFileStamp(size: 4, modified: now, identity: stamp.identity, changed: now)
assert(!stability.sample(changed, now: now.addingTimeInterval(3)))
assert(!stability.sample(changed, now: now.addingTimeInterval(4)))
assert(stability.sample(changed, now: now.addingTimeInterval(5)))
var rapid = WatchStability()
for _ in 0..<20 { assert(!rapid.sample(stamp, now: now)) }
var empty = WatchStability()
let zero = WatchFileStamp(size: 0, modified: now, identity: 1, changed: now)
for n in 0..<10 { assert(!empty.sample(zero, now: now.addingTimeInterval(Double(n)))) }
assert(WatchPathPolicy.eligible(source, root: root, recursive: false, outputs: []))
assert(!WatchPathPolicy.eligible(source, root: root, recursive: true, outputs: [WatchPathPolicy.canonical(source)]))
assert(!WatchPathPolicy.contains(root.path + "-other/file", in: root.path))
for name in [".hidden", "~save", "image.part", "image.crdownload", "image.tmp", "foo~"] {
    let url = root.appendingPathComponent(name)
    try Data([1]).write(to: url)
    assert(!WatchPathPolicy.eligible(url, root: root, recursive: true, outputs: []))
}
let child = root.appendingPathComponent("child")
try fm.createDirectory(at: child, withIntermediateDirectories: true)
let nested = child.appendingPathComponent("nested.jpg")
try Data([1]).write(to: nested)
assert(!WatchPathPolicy.eligible(nested, root: root, recursive: false, outputs: []))
assert(WatchPathPolicy.eligible(nested, root: root, recursive: true, outputs: []))
assert(!WatchPathPolicy.eligible(child, root: root, recursive: true, outputs: []))
let link = root.appendingPathComponent("link.jpg")
try fm.createSymbolicLink(at: link, withDestinationURL: source)
assert(!WatchPathPolicy.eligible(link, root: root, recursive: true, outputs: []))
let dirLink = root.appendingPathComponent("alias")
try fm.createSymbolicLink(at: dirLink, withDestinationURL: child)
assert(!WatchPathPolicy.rootIsNotSymlink(dirLink))
assert(WatchPathPolicy.rootIsNotSymlink(root))
assert(!WatchPathPolicy.eligible(dirLink.appendingPathComponent("nested.jpg"), root: root, recursive: true, outputs: []))
let output = root.appendingPathComponent("converted.png")
try Data([3,2,1]).write(to: output)
assert(!WatchPathPolicy.canDelete(source: source, before: stamp, output: source))
assert(WatchPathPolicy.canDelete(source: source, before: stamp, output: output))
var wrongDevice = stamp
wrongDevice.device = stamp.device &+ 1
assert(!WatchPathPolicy.canDelete(source: source, before: wrongDevice, output: output))
assert(!WatchPathPolicy.sameStagedIdentity(stamp, wrongDevice))
var wrongNanos = stamp
wrongNanos.modifiedNanoseconds = stamp.modifiedNanoseconds &+ 1
assert(!WatchPathPolicy.canDelete(source: source, before: wrongNanos, output: output))
assert(!WatchPathPolicy.sameStagedIdentity(stamp, wrongNanos))
let hardlink = root.appendingPathComponent("hardlink.png")
try fm.linkItem(at: source, to: hardlink)
assert(!WatchPathPolicy.canDelete(source: source, before: stamp, output: hardlink))
try Data([1,2,3,4]).write(to: source)
assert(!WatchPathPolicy.canDelete(source: source, before: stamp, output: output))
print("watch policy/stability/loop/delete assertions passed")
'''
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / "main.swift"
            main.write_text(harness)
            binary = Path(tmp) / "watch-tests"
            result = subprocess.run([SWIFT, str(ROOT / "Margherita/WatchFolderRules.swift"),
                str(main), "-o", str(binary)], env=ENV, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], env=ENV, check=True)

    @unittest.skipUnless(Path(SWIFT).exists(), "Swift compiler unavailable")
    def test_controller_parses(self):
        result = subprocess.run([SWIFT, "-frontend", "-parse",
            str(ROOT / "Margherita/WatchFolders.swift"), str(ROOT / "Margherita/WatchFolderRules.swift")],
            env=ENV, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == "__main__":
    unittest.main()
