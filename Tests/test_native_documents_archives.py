"""Compile and run real Swift logic; BSD tar exercises the macOS archive engine.
Linux substitutes Glibc and bsdtar only. macOS runs unchanged archive source.
AppKit/PDFKit rendering and textutil still require a Mac integration smoke test.
"""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))

def function(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]

class NativeLogic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        source = (ROOT / "Margherita/NativeArchives.swift").read_text()
        if os.uname().sysname != "Darwin":
            if not shutil.which("bsdtar"):
                raise unittest.SkipTest("BSD tar is required")
            source = source.replace("import Darwin", "import Glibc").replace('"/usr/bin/tar"', '"/usr/bin/bsdtar"')
        docs = (ROOT / "Margherita/NativeDocuments.swift").read_text()
        selected = ["static func xml(", "static func parseDelimited(", "static func delimited(", "static func subtitle("]
        pure = "import Foundation\n enum Logic {\n"
        pure += "\n".join(function(docs, s) for s in selected) + "\n}\n"
        (root / "Archive.swift").write_text(source)
        (root / "Logic.swift").write_text(pure)
        (root / "main.swift").write_text(r'''
import Foundation
let args = CommandLine.arguments
do {
    if args[1] == "repack" {
        try NativeArchives.convert(input: [URL(fileURLWithPath: args[2])], to: URL(fileURLWithPath: args[3]), format: "gzip")
    } else if args[1] == "extract" {
        try NativeArchives.extract(input: URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[3]))
    } else if args[1] == "logic" {
        let rows = try Logic.parseDelimited("a,b\r\n\"hello, x\",\"quote \"\"yes\"\"\"\r\n\"two\nlines\",", separator: ",")
        assert(rows == [["a", "b"], ["hello, x", "quote \"yes\""], ["two\nlines", ""]])
        assert(try Logic.parseDelimited("a\tb\nc\t", separator: "\t") == [["a", "b"], ["c", ""]])
        var rejected = false
        do { _ = try Logic.parseDelimited("\"unfinished", separator: ",") } catch { rejected = true }
        assert(rejected)
        assert(Logic.xml("<&\"'") == "&lt;&amp;&quot;&apos;")
        assert(Logic.delimited([["=SUM(A1)", "x,y"]], separator: ",") == "'=SUM(A1),\"x,y\"\r\n")
        let vtt = try Logic.subtitle("1\n00:00:01,000 --> 00:00:03,000\nHello\n\n2\n00:00:05,000 --> 00:00:06,000\nBye\n", source: "srt", target: "vtt")
        assert(vtt.hasPrefix("WEBVTT\n\n00:00:01.000"))
        let srt = try Logic.subtitle(vtt, source: "vtt", target: "srt")
        assert(srt.hasPrefix("1\n00:00:01,000"))
        assert(try Logic.subtitle(vtt, source: "vtt", target: "txt") == "Hello\n\nBye\n")
        for bad in ["../escape", "/absolute", "a/../../bad", "a\\bad", "a\nbad", "*", "a:b"] {
            var safe = true
            do { _ = try NativeArchives.safeEntry(bad) } catch { safe = false }
            assert(!safe)
        }
        assert(try NativeArchives.safeEntry("./folder/file.txt") == "folder/file.txt")
        print("logic passed")
    }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
''')
        # Assertions cannot contain throwing expressions in nonthrowing autoclosures.
        m = (root / "main.swift").read_text()
        m = m.replace('assert(try Logic.parseDelimited("a\\tb\\nc\\t", separator: "\\t") == [["a", "b"], ["c", ""]])',
                      'let tsv = try Logic.parseDelimited("a\\tb\\nc\\t", separator: "\\t"); assert(tsv == [["a", "b"], ["c", ""]])')
        m = m.replace('assert(try Logic.subtitle(vtt, source: "vtt", target: "txt") == "Hello\\n\\nBye\\n")',
                      'let plain = try Logic.subtitle(vtt, source: "vtt", target: "txt"); assert(plain == "Hello\\n\\nBye\\n")')
        m = m.replace('assert(try NativeArchives.safeEntry("./folder/file.txt") == "folder/file.txt")',
                      'let clean = try NativeArchives.safeEntry("./folder/file.txt"); assert(clean == "folder/file.txt")')
        (root / "main.swift").write_text(m)
        cls.binary = root / "native-tests"
        subprocess.run([SWIFTC, "-swift-version", "5", str(ROOT / "Margherita/ConversionCancellation.swift"), str(root / "Archive.swift"), str(root / "Logic.swift"),
                        str(root / "main.swift"), "-o", str(cls.binary)], check=True, env=ENV, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def extract(self, archive, target, success=True):
        result = subprocess.run([str(self.binary), "extract", str(archive), str(target)], capture_output=True, text=True, env=ENV)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        if not success:
            self.assertFalse(target.exists())
        return result

    def test_pure_logic(self):
        subprocess.run([str(self.binary), "logic"], check=True, env=ENV, capture_output=True)

    def test_normal_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with zipfile.ZipFile(root / "input.zip", "w") as z:
                z.writestr("folder/", "")
                z.writestr("folder/hello.txt", "hello")
                z.writestr("unicode-é.txt", "world")
                z.writestr("[Content_Types].xml", "<Types/>")
            self.extract(root / "input.zip", root / "output")
            self.assertEqual((root / "output/folder/hello.txt").read_text(), "hello")
            self.assertEqual((root / "output/[Content_Types].xml").read_text(), "<Types/>")

    def test_archive_repacked_not_nested(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with zipfile.ZipFile(root / "input.zip", "w") as z:
                z.writestr("hello.txt", "hello")
            result = subprocess.run([str(self.binary), "repack", str(root / "input.zip"), str(root / "output.tar.gz")],
                                    capture_output=True, text=True, env=ENV)
            self.assertEqual(result.returncode, 0, result.stderr)
            with tarfile.open(root / "output.tar.gz") as t:
                names = t.getnames()
                self.assertTrue(any(n.endswith("hello.txt") for n in names))
                self.assertFalse(any(n.endswith("input.zip") for n in names))

    def test_traversal_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with zipfile.ZipFile(root / "input.zip", "w") as z:
                z.writestr("../outside", "unsafe")
            self.extract(root / "input.zip", root / "output", False)
            self.assertFalse((root / "outside").exists())

    def test_links_rejected(self):
        for hard in [False, True]:
            with self.subTest(hard=hard), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with tarfile.open(root / "input.tar", "w") as t:
                    info = tarfile.TarInfo("linked")
                    info.type = tarfile.LNKTYPE if hard else tarfile.SYMTYPE
                    info.linkname = "/etc/passwd"
                    t.addfile(info)
                self.extract(root / "input.tar", root / "output", False)

    def test_duplicate_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with tarfile.open(root / "input.tar", "w") as t:
                for i in range(2):
                    info = tarfile.TarInfo("same.txt")
                    info.size = 1
                    t.addfile(info, io.BytesIO(b"x"))
            self.extract(root / "input.tar", root / "output", False)

    def test_plain_gzip(self):
        import gzip
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "hello.gz").write_bytes(gzip.compress(b"content"))
            self.extract(root / "hello.gz", root / "output")
            self.assertEqual((root / "output/hello").read_bytes(), b"content")

    def test_tar_gzip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with tarfile.open(root / "input.tgz", "w:gz") as t:
                info = tarfile.TarInfo("hello.txt")
                info.size = 5
                t.addfile(info, io.BytesIO(b"hello"))
            self.extract(root / "input.tgz", root / "output")
            self.assertEqual((root / "output/hello.txt").read_text(), "hello")

    def test_archive_metacharacter_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with zipfile.ZipFile(root / "input.zip", "w") as z:
                z.writestr("a*.txt", "unsafe match")
            self.extract(root / "input.zip", root / "output", False)

if __name__ == "__main__":
    unittest.main()
