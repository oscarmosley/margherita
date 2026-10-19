"""Exercise the DMG assembly using mocked stock Mac commands, no actual disk image."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r"""#!/usr/bin/env python3
import os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["DMG_TEST_LOG"], "a") as log:
    log.write(name + " " + repr(args) + "\n")
def failed(key): return os.environ.get("DMG_TEST_"+key)
if name == "uname": print("Darwin")
elif name == "sleep": pass
elif name == "PlistBuddy": print(os.environ.get("DMG_TEST_VERSION", "1.0.0"))
elif name == "codesign":
    if failed("BAD_SIGN"): sys.exit(4)
elif name == "ditto": shutil.copytree(args[0], args[1], symlinks=True)
elif name == "swiftc":
    if failed("COMPILE"): sys.exit(7)
    shutil.copy2(sys.argv[0], args[args.index("-o")+1])
elif name == "render-dmg":
    if args[0] == "--volume-icon":
        assert (pathlib.Path(args[1])/".VolumeIcon.icns").read_text() == "pizza icon"
        if failed("ICON"): sys.exit(8)
    else:
        if failed("RENDER"): sys.exit(8)
        for n in ["background.png", "background@2x.png"]:
            (pathlib.Path(args[0])/n).write_text("art")
elif name == "tiffutil":
    assert pathlib.Path(args[1]).read_text() == "art"
    assert pathlib.Path(args[2]).read_text() == "art"
    if failed("TIFF"): sys.exit(8)
    pathlib.Path(args[-1]).write_text("retina tiff")
elif name == "osascript":
    mount = pathlib.Path(args[-2])
    assert (mount/".background/background.tiff").read_text() == "retina tiff"
    assert (mount/"Applications").is_symlink()
    if failed("LAYOUT"): sys.exit(9)
    if not failed("NO_DS_STORE"): (mount/".DS_Store").write_text("layout")
elif name == "hdiutil":
    image = pathlib.Path(args[-1])
    if args[0] == "create":
        stage = pathlib.Path(args[args.index("-srcfolder")+1])
        assert (stage/"Margherita.app/Contents/Info.plist").is_file()
        assert (stage/"Applications").is_symlink()
        assert os.readlink(stage/"Applications") == "/Applications"
        assert args[args.index("-format")+1] == "UDRW"
        assert (stage/".background/background@2x.png").exists()
        assert (stage/".VolumeIcon.icns").exists()
        if failed("FAIL"): sys.exit(5)
        image.write_text("writable")
    elif args[0] == "attach":
        mount = pathlib.Path(os.environ["DMG_TEST_MOUNT"])
        stage = mount.parent/"Drag Margherita to Applications"
        shutil.copytree(stage, mount, symlinks=True, dirs_exist_ok=True)
        (mount.parent/"attached").touch()
        if failed("ATTACH"): sys.exit(5)
    elif args[0] == "detach":
        mount = pathlib.Path(args[1])
        if failed("STUCK_MOUNT") or (failed("DETACH") and "-force" not in args): sys.exit(5)
        (mount.parent/"attached").unlink(missing_ok=True)
    elif args[0] == "convert":
        assert not (image.parent/"attached").exists()
        assert args[args.index("-format")+1] == "UDZO"
        if failed("CONVERT"): sys.exit(5)
        image.write_text("mock dmg")
        if failed("RACE"):
            (pathlib.Path.cwd()/"Margherita-1.0.0.dmg").write_text("other process")
    elif args[0] == "verify":
        assert image.read_text() == "mock dmg"
        if failed("BAD_VERIFY"): sys.exit(6)
else: sys.exit(9)
"""

class MakeDMG(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="Margherita dmg 🐈 ")
        self.root = Path(self.tmp.name)
        self.repo = self.root/"source with spaces"
        (self.repo/"scripts").mkdir(parents=True)
        self.app = self.repo/"build/Margherita.app"
        (self.app/"Contents").mkdir(parents=True)
        (self.app/"Contents/Info.plist").write_text("fixture")
        (self.app/"Contents/Resources").mkdir()
        (self.app/"Contents/Resources/AppIcon.icns").write_text("pizza icon")
        for name in ["render-dmg.swift", "layout-dmg.applescript"]:
            shutil.copy2(ROOT/"scripts"/name, self.repo/"scripts"/name)
        self.bin = self.root/"bin"
        self.bin.mkdir()
        for name in ["uname", "PlistBuddy", "ditto", "codesign", "hdiutil", "swiftc", "tiffutil", "osascript", "sleep"]:
            p = self.bin/name
            p.write_text(MOCK)
            p.chmod(0o755)
        script = (ROOT/"scripts/make-dmg.sh").read_text().replace(
            "/usr/libexec/PlistBuddy", '"' + str(self.bin/"PlistBuddy") + '"')
        # Redirect the production /Volumes mount into this isolated fixture.
        script = script.replace('MOUNT="/Volumes/Margherita $VERSION"', 'MOUNT="$WORK/mount"')
        script = script.replace(
            'hdiutil attach "$WORK/writable.dmg" -readwrite -noverify',
            'DMG_TEST_MOUNT="$MOUNT" hdiutil attach "$WORK/writable.dmg" -readwrite -noverify')
        (self.repo/"scripts/make-dmg.sh").write_text(script)
        self.log = self.root/"calls.log"
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ["PATH"],
                        DMG_TEST_LOG=str(self.log))
        self.output = self.repo/"Margherita-1.0.0.dmg"

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, **env):
        return subprocess.run(["bash", "scripts/make-dmg.sh"], cwd=self.repo,
                              env=dict(self.env, **env), text=True, capture_output=True)

    def assert_clean(self):
        self.assertFalse(list((self.repo/"build").glob(".margherita-dmg.*")))

    def test_drag_install_image_and_original_untouched(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(self.output.read_text(), "mock dmg")
        self.assertEqual((self.app/"Contents/Info.plist").read_text(), "fixture")
        self.assert_clean()

    def test_missing_build(self):
        shutil.rmtree(self.app)
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_existing_image_and_symlink_never_replaced(self):
        self.output.write_text("keep")
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.output.read_text(), "keep")
        self.output.unlink()
        self.output.symlink_to(self.repo/"not-created")
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertTrue(self.output.is_symlink())

    def test_publish_race_preserves_other_output(self):
        self.assertNotEqual(self.run_script(DMG_TEST_RACE="1").returncode, 0)
        self.assertEqual(self.output.read_text(), "other process")
        self.assert_clean()

    def test_failures_clean_staging_and_publish_nothing(self):
        for key in ["DMG_TEST_"+key for key in ["BAD_SIGN", "COMPILE", "RENDER", "TIFF", "FAIL", "ATTACH", "ICON", "LAYOUT", "DETACH", "CONVERT", "BAD_VERIFY"]]:
            with self.subTest(key=key):
                self.assertNotEqual(self.run_script(**{key:"1"}).returncode, 0)
                self.assertFalse(self.output.exists())
                self.assert_clean()

    def test_delayed_finder_layout_is_nonfatal(self):
        result = self.run_script(DMG_TEST_NO_DS_STORE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Finder layout file not written yet", result.stdout)
        self.assertEqual(self.output.read_text(), "mock dmg")
        self.assert_clean()

    def test_stock_layout_contract(self):
        layout = (ROOT/"scripts/layout-dmg.applescript").read_text()
        for text in ["on run argv", "with timeout of 60 seconds", "toolbar visible of container window to false",
                     "sidebar width of container window to 0", "{220, 198}", "{580, 198}",
                     "background.tiff", "icon size of viewOptions to 128", "tell disk volName",
                     "pathbar visible of container window to false"]:
            self.assertIn(text, layout)
        renderer = (ROOT/"scripts/render-dmg.swift").read_text()
        self.assertIn("for scale in [1, 2]", renderer)
        self.assertIn("NSWorkspace.shared.setIcon", renderer)
        self.assertIn("Drag Margherita into Applications", renderer)

    def test_lifecycle_order_and_no_changes_to_app(self):
        self.assertEqual(self.run_script().returncode, 0)
        log = self.log.read_text()
        stages = ["'create'", "'attach'", "--volume-icon", "osascript ", "'detach'", "'convert'", "'verify'"]
        offsets = [log.index(stage) for stage in stages]
        self.assertEqual(offsets, sorted(offsets))
        self.assertIn("background@2x.png", log)
        self.assertEqual((self.app/"Contents/Resources/AppIcon.icns").read_text(), "pizza icon")

    def test_missing_icon_is_fatal(self):
        (self.app/"Contents/Resources/AppIcon.icns").unlink()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.output.exists())
        self.assert_clean()

    def test_stuck_mount_is_retained_not_recursively_deleted(self):
        result = self.run_script(DMG_TEST_STUCK_MOUNT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        work = list((self.repo/"build").glob(".margherita-dmg.*"))
        self.assertEqual(len(work), 1)
        self.assertTrue((work[0]/"mount/Margherita.app/Contents/Info.plist").exists())
        self.assertIn("temporary files retained", result.stderr)
        self.assertIn("-force", self.log.read_text())

    def test_checked_in_png_assets_have_native_and_retina_dimensions(self):
        import struct
        for filename, expected in [("background.png", (800, 440)),
                                   ("background@2x.png", (1600, 880))]:
            data = (ROOT/"artwork/dmg"/filename).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", data[16:24]), expected)

    def test_untrusted_version_not_used_in_path(self):
        self.assertNotEqual(self.run_script(DMG_TEST_VERSION="../bad").returncode, 0)
        self.assertFalse(self.output.exists())

if __name__ == "__main__":
    unittest.main()
