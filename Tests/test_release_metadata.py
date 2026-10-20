"""Release metadata, license completeness and source-only packaging contracts."""
from pathlib import Path
import plistlib
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ReleaseMetadata(unittest.TestCase):
    def test_versions_match_release(self):
        info = plistlib.loads((ROOT / "Margherita/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], "1.0.2")
        self.assertEqual(info["CFBundleVersion"], "1.0.2")
        generator = (ROOT / "scripts/generate_project.py").read_text()
        for field in ("CFBundleShortVersionString", "CFBundleVersion", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
            self.assertIn(field + '="1.0.2"', generator)
        project = (ROOT / "Margherita.xcodeproj/project.pbxproj").read_text()
        for field in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
            self.assertEqual(len(re.findall('"' + field + '" = "1.0.2"', project)), 2)
        yml = (ROOT / "project.yml").read_text()
        self.assertIn('CFBundleShortVersionString: "1.0.2"', yml)
        self.assertIn('CFBundleVersion: "1.0.2"', yml)

    def test_full_license_bundled_and_notices_retained(self):
        license = (ROOT / "LICENSE").read_text()
        self.assertIn("GNU GENERAL PUBLIC LICENSE", license)
        self.assertIn("Version 3, 29 June 2007", license)
        self.assertIn("17. Interpretation of Sections 15 and 16.", license)
        self.assertGreater(len(license), 30000)
        self.assertEqual(license, (ROOT / "Margherita/Licenses/Margherita-GPL-3.txt").read_text())
        notice = (ROOT / "Margherita/Licenses/FFmpeg-NOTICE.txt").read_text()
        self.assertIn("exact corresponding FFmpeg", notice)

    def test_generated_downloads_and_caches_ignored(self):
        paths = ["build/Margherita.app", ".DS_Store", ".ffmpeg-cache/ffmpeg.zip",
                 ".cache/download", "ffmpeg-downloads/tool", "margherita.zip"]
        result = subprocess.run(["git", "check-ignore", *paths], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(paths), set(result.stdout.splitlines()))

if __name__ == "__main__":
    unittest.main()
