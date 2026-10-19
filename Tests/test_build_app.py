#!/usr/bin/env python3
"""Exercise bundle assembly with mock Mac tools, not macOS compilation."""
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
MOCK = r'''#!/usr/bin/env python3
import os, pathlib, plistlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(name + " " + repr(args) + "\n")
if name == "uname":
    print("Darwin" if args == ["-s"] else os.environ.get("MOCK_ARCH", "arm64"))
elif name == "curl":
    sys.exit(22)
elif name == "xcode-select":
    if os.environ.get("MOCK_NO_CLT"): sys.exit(1)
    print("/Library/Developer/CommandLineTools")
elif name == "xcrun":
    if args == ["--sdk", "macosx", "--show-sdk-path"]: print(os.environ["MOCK_SDK"])
    elif args == ["--find", "swiftc"]: print(pathlib.Path(sys.argv[0]).parent / "swiftc")
    elif args[0] == "lipo": pathlib.Path(args[-1]).write_text("universal")
    else: sys.exit(4)
elif name == "swiftc":
    if os.environ.get("MOCK_COMPILE_FAIL"): sys.exit(9)
    pathlib.Path(args[args.index("-o") + 1]).write_text("native")
elif name == "PlistBuddy":
    path = pathlib.Path(args[-1])
    value = plistlib.loads(path.read_bytes())
    if args[1].startswith("Delete"): value.pop("CFBundleIconName", None)
    else: value["CFBundleIconFile"] = "AppIcon.icns"
    path.write_bytes(plistlib.dumps(value))
elif name == "plutil":
    plistlib.loads(pathlib.Path(args[-1]).read_bytes())
elif name == "sips":
    pathlib.Path(args[args.index("--out") + 1]).write_text("png")
elif name == "iconutil":
    icons = list(pathlib.Path(args[2]).glob("*.png"))
    assert len(icons) == 10, icons
    pathlib.Path(args[-1]).write_text("icns")
elif name in ("codesign", "xattr", "curl"):
    assert pathlib.Path(args[-1]).is_dir()
else: sys.exit(5)
'''

class BuildScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="margherita tests ")
        self.root = Path(self.tmp.name)
        self.repo = self.root / "Margherita source"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copytree(ROOT / "Margherita", self.repo / "Margherita")
        shutil.copy(ROOT / "Margherita-icon.png", self.repo)
        shutil.copy(ROOT / "scripts/bundle-ffmpeg.sh", self.repo / "scripts")
        shutil.copy(ROOT / "scripts/bundle-sparkle.sh", self.repo / "scripts")
        source = (ROOT / "scripts/build-app.sh").read_text()
        self.bin = self.root / "mock tools"
        self.bin.mkdir()
        for name in ("uname", "xcode-select", "xcrun", "swiftc", "PlistBuddy",
                     "plutil", "sips", "iconutil", "codesign", "xattr", "curl"):
            path = self.bin / name
            path.write_text(MOCK)
            path.chmod(0o755)
        source = source.replace("/usr/libexec/PlistBuddy", '"' + str(self.bin / "PlistBuddy") + '"')
        (self.repo / "scripts/build-app.sh").write_text(source)
        self.sdk = self.root / "MacOSX.sdk"
        self.sdk.mkdir()
        self.log = self.root / "calls"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        MOCK_SDK=str(self.sdk), MOCK_LOG=str(self.log))
        self.app = self.repo / "build/Margherita.app"

    def tearDown(self):
        self.tmp.cleanup()

    def run_build(self, **env):
        return subprocess.run(["bash", "scripts/build-app.sh"], cwd=self.repo,
                              env=dict(self.env, **env), text=True, capture_output=True)

    def test_sparkle_offline_download_falls_back(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Building without automatic updates", result.stdout)
        self.assertIn("Sparkle-2.10.0.tar.xz", self.log.read_text())
        self.assertFalse((self.app / "Contents/Frameworks/Sparkle.framework").exists())

    def test_sparkle_opt_out_never_downloads(self):
        result = self.run_build(MARGHERITA_SPARKLE="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Sparkle-2.10.0.tar.xz", self.log.read_text())

    def test_native_bundle_and_resources(self):
        resource = self.repo / "Margherita/en.lproj/Localizable.strings"
        resource.parent.mkdir()
        resource.write_text('"hello" = "Hi";')
        plist_path = self.repo / "Margherita/Info.plist"
        value = plistlib.loads(plist_path.read_bytes())
        value["LSUIElement"] = True
        plist_path.write_bytes(plistlib.dumps(value))
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.assertEqual(value["CFBundleExecutable"], "Margherita")
        self.assertEqual(value["CFBundleIdentifier"], "com.oscar.margherita")
        self.assertEqual(value["CFBundleIconFile"], "AppIcon.icns")
        self.assertTrue(value["LSUIElement"])
        self.assertIn("'-framework', 'CoreServices'", self.log.read_text())
        self.assertNotIn("CFBundleIconName", value)
        self.assertTrue((self.app / "Contents/Resources/AppIcon.icns").is_file())
        self.assertTrue((self.app / "Contents/Resources/en.lproj/Localizable.strings").is_file())
        self.assertFalse(list(self.app.rglob("*.swift")))
        self.assertFalse(list(self.app.rglob("*.xcassets")))
        self.assertTrue(os.access(self.app / "Contents/MacOS/Margherita", os.X_OK))
        calls = self.log.read_text()
        self.assertIn("arm64-apple-macos13", calls)
        self.assertIn("-parse-as-library", calls)
        self.assertIn("-O", calls)
        self.assertIn("'--force', '--deep', '-s', '-'", calls)
        self.assertIn("xattr ['-cr'", calls)
        self.assertFalse(list((self.repo / "build").glob(".margherita-build.*")))

    def test_media_download_failure_is_nonfatal(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WARNING: FFmpeg download/bundling failed", result.stdout)
        self.assertFalse((self.app / "Contents/Resources/bin/ffmpeg").exists())
        self.assertTrue((self.app / "Contents/Resources/Licenses/FFmpeg-GPL-3.txt").is_file())

    def test_intel(self):
        result = self.run_build(MOCK_ARCH="x86_64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("x86_64-apple-macos13", self.log.read_text())

    def test_universal(self):
        result = self.run_build(MARGHERITA_UNIVERSAL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Contents/MacOS/Margherita").read_text(), "universal")
        self.assertIn("x86_64-apple-macos13", self.log.read_text())

    def test_missing_clt(self):
        result = self.run_build(MOCK_NO_CLT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("xcode-select --install", result.stdout)
        self.assertFalse(self.app.exists())

    def test_failed_compile_keeps_previous_build(self):
        self.app.mkdir(parents=True)
        (self.app / "keep").write_text("old")
        result = self.run_build(MOCK_COMPILE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "keep").read_text(), "old")
        self.assertFalse(list((self.repo / "build").glob(".margherita-build.*")))

    def test_unresolved_setting_stops_build(self):
        path = self.repo / "Margherita/Info.plist"
        data = plistlib.loads(path.read_bytes())
        data["CFBundleShortVersionString"] = "$(UNKNOWN_SETTING)"
        path.write_bytes(plistlib.dumps(data))
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unresolved", result.stdout)

    def test_successful_rebuild(self):
        self.app.mkdir(parents=True)
        (self.app / "old").write_text("previous")
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.app / "old").exists())

if __name__ == "__main__":
    unittest.main()
