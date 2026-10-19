import pathlib
import plistlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class SparkleTests(unittest.TestCase):
    def test_shell_syntax(self):
        for script in ("build-app.sh", "bundle-sparkle.sh"):
            subprocess.run(["bash", "-n", str(ROOT / "scripts" / script)], check=True)

    def test_safe_defaults_and_versions(self):
        info = plistlib.loads((ROOT / "Margherita/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleVersion"], "1.0.1")
        self.assertEqual(info["CFBundleShortVersionString"], "1.0.1")
        self.assertIn("REPLACE_OWNER", info["SUFeedURL"])
        self.assertFalse(info["SUEnableAutomaticChecks"])
        self.assertFalse(info["SUAutomaticallyUpdate"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])

    def test_configuration_guard_precedes_instantiation(self):
        src = (ROOT / "Margherita/UpdateController.swift").read_text()
        self.assertIn("#if canImport(Sparkle)", src)
        self.assertLess(src.index("Self.validConfiguration(Bundle"), src.index("let candidate ="))
        self.assertIn('decoded.count == 32', src)
        self.assertIn('url.scheme == "https"', src)
        self.assertIn('contains("REPLACE")', src)
        self.assertIn("try candidate.updater.start()", src)
        self.assertNotIn("checkForUpdatesInBackground", src)

    def test_pinned_verified_binary(self):
        src = (ROOT / "scripts/bundle-sparkle.sh").read_text()
        self.assertIn("VERSION=2.10.0", src)
        self.assertIn("c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c", src)
        self.assertLess(src.index('if [ "$ACTUAL" != "$SHA256" ]'), src.index('tar -xJf'))
        self.assertIn("for arch in arm64 x86_64", src)
        self.assertIn("--proto-redir '=https'", src)
        self.assertIn('-verify_arch "$arch" >&2', src)
        self.assertIn('cp "$DIST/LICENSE"', src)
        self.assertIn('ditto "$DIST/Sparkle.framework"', src)
        self.assertLess(src.index('codesign --force -s - "$FRAME/Versions/B/Autoupdate"'),
                        src.index('codesign --force -s - "$FRAME"'))

    def test_build_probe_and_embedding(self):
        src = (ROOT / "scripts/build-app.sh").read_text()
        self.assertIn("-typecheck", src)
        self.assertIn("@executable_path/../Frameworks", src)
        self.assertIn("Building without automatic updates.", src)
        self.assertLess(src.index('--embed "$SPARKLE_DIST"'), src.index('codesign --force -s - "$APP"'))

    def test_generator_preserves_configuration(self):
        src = (ROOT / "scripts/generate_project.py").read_text()
        compile(src, "generate_project.py", "exec")
        for key in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUVerifyUpdateBeforeExtraction"):
            self.assertIn(key, src)
            self.assertIn(key, (ROOT / "project.yml").read_text())


if __name__ == "__main__":
    unittest.main()
