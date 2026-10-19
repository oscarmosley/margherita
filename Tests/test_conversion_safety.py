"""Portable production archive/process safety tests; Apple decoders need macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from test_native_documents_archives import ROOT, SWIFTC, ENV, function


class ConversionSafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        source = (ROOT / "Margherita/NativeArchives.swift").read_text()
        if os.uname().sysname != "Darwin":
            if not shutil.which("bsdtar"):
                raise unittest.SkipTest("BSD tar required")
            source = source.replace('"/usr/bin/tar"', '"/usr/bin/bsdtar"')
        (cls.root / "Archives.swift").write_text(source)
        engine = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        pure = """import Foundation
enum MargheritaError: LocalizedError {
 case message(String)
 var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
extension URL { var fileExists: Bool { FileManager.default.fileExists(atPath: path) } }
struct RecoveryRecord: Codable {
 var target: URL; var backup: URL; var stage: URL; var installed = false
}
class Installer {
 let fm = FileManager.default
"""
        for signature in ["private func outputURL(", "private func install("]:
            pure += function(engine, signature).replace("private func", "func") + "\n"
        pure += "}\n"
        (cls.root / "Installer.swift").write_text(pure)
        (cls.root / "main.swift").write_text(r"""
import Foundation
let a = CommandLine.arguments
func url(_ i: Int) -> URL { URL(fileURLWithPath: a[i]) }
do {
 switch a[1] {
 case "stdout": _ = try NativeProcess.run("/usr/bin/python3", ["-c", "import sys; sys.stdout.write('x'*2000000)"], limit: 1024)
 case "stderr": _ = try NativeProcess.run("/usr/bin/python3", ["-c", "import sys; sys.stderr.write('x'*2000000); sys.exit(1)"])
 case "cancel":
  let token = ConversionCancellation()
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
  try ConversionCancellation.$current.withValue(token) {
   _ = try NativeProcess.run("/usr/bin/python3", ["-c", "import time; time.sleep(10)"])
  }
 case "invalid": _ = try NativeProcess.run("/usr/bin/true", [], limit: Int.max)
 case "pack": try NativeArchives.convert(input: [url(2)], to: url(3), format: "zip")
 case "extract": try NativeArchives.extract(input: url(2), to: url(3))
 case "name": print(try Installer().outputURL(url(2), inputs: [url(3)], collision: a[4]).path)
 case "install": _ = try Installer().install(url(2), at: url(3), collision: "unique")
 default: fatalError()
 }
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
""")
        main = cls.root / "main.swift"
        main.write_text(main.read_text().replace("/usr/bin/python3", sys.executable))
        cls.binary = cls.root / "safety"
        built = subprocess.run([SWIFTC, "-swift-version", "5",
            str(ROOT / "Margherita/ConversionCancellation.swift"),
            str(cls.root / "Archives.swift"), str(cls.root / "Installer.swift"),
            str(cls.root / "main.swift"), "-o", str(cls.binary)],
            env=ENV, text=True, capture_output=True)
        if built.returncode:
            raise RuntimeError(built.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def call(self, *args, success=True):
        result = subprocess.run([str(self.binary), *map(str, args)], env=dict(ENV, TMPDIR=str(self.root)),
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def test_final_process_output_is_bounded(self):
        self.assertRegex(self.call("stdout", success=False).stderr.lower(), r"size|too large")
        self.assertIn("size", self.call("stderr", success=False).stderr.lower())

    def test_cancel_stops_child_and_cleans_scratch(self):
        started = time.monotonic()
        self.call("cancel", success=False)
        self.assertLess(time.monotonic() - started, 3)
        self.assertFalse(list(self.root.glob("Margherita-process-*")))

    def test_invalid_limits_do_not_trap(self):
        self.assertIn("Invalid process", self.call("invalid", success=False).stderr)

    def test_unicode_spaces_roundtrip_and_existing_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "café 猫 🍕"
            source.mkdir()
            (source / "hello world.txt").write_text("untouched 🐈")
            archive = root / "out.zip"
            self.call("pack", source, archive)
            output = root / "extracted"
            self.call("extract", archive, output)
            self.assertEqual((output / source.name / "hello world.txt").read_text(), "untouched 🐈")
            self.call("extract", archive, output, success=False)
            self.assertFalse(list(root.glob("*.margherita-*")))

    def test_original_is_never_selected_for_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "original.txt"
            source.write_text("precious")
            result = self.call("name", source, source, "replace")
            self.assertEqual(Path(result.stdout.strip()).name, "original 2.txt")
            self.assertEqual(source.read_text(), "precious")

    def test_late_collision_preserves_stage_and_existing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage, target = root / "stage", root / "target"
            stage.write_text("new")
            target.write_text("old")
            self.call("install", stage, target, success=False)
            self.assertEqual(target.read_text(), "old")
            self.assertEqual(stage.read_text(), "new")

    def test_replace_refuses_symbolic_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, victim, link = root / "source", root / "victim", root / "link"
            source.write_text("source")
            victim.write_text("precious")
            link.symlink_to(victim)
            self.call("name", link, source, "replace", success=False)
            self.assertEqual(victim.read_text(), "precious")


if __name__ == "__main__":
    unittest.main()
