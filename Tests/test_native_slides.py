"""Compile the actual platform-independent slide reader and exercise hostile OOXML."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class SlidesTests(unittest.TestCase):
    def test_swift_reader(self):
        swift = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
        if not pathlib.Path(swift).exists():
            self.skipTest("Swift compiler not installed")
        harness = r'''
import Foundation
enum NativeConversionError: Error { case message(String) }
func xml(_ s: String) throws -> SlideXML.Node { try SlideXML.parse(Data(s.utf8)) }
func reject(_ f: () throws -> Void) { do { try f(); fatalError("accepted unsafe input") } catch {} }
let p = try xml("<p:presentation xmlns:p='p' xmlns:r='r'><p:sldIdLst><p:sldId r:id='two'/><p:sldId r:id='one'/></p:sldIdLst></p:presentation>")
let r = try xml("<Relationships><Relationship Id='one' Type='x/slide' Target='slides/slide1.xml'/><Relationship Id='two' Type='x/slide' Target='slides/slide2.xml'/></Relationships>")
assert(try NativeSlides.slidePaths(presentation: p, relationships: r) == ["ppt/slides/slide2.xml", "ppt/slides/slide1.xml"])
assert(try NativeSlides.resolve("../media/a.png", relativeTo: "ppt/slides/slide1.xml") == "ppt/media/a.png")
reject { _ = try NativeSlides.resolve("../../../etc/passwd", relativeTo: "ppt/slides/a.xml") }
reject { _ = try NativeSlides.resolve("https://example.org/a", relativeTo: "ppt/slides/a.xml") }
reject { _ = try NativeSlides.resolve("%2e%2e/a", relativeTo: "ppt/slides/a.xml") }
reject { _ = try xml("<!DOCTYPE a [<!ENTITY b SYSTEM 'file:///etc/passwd'>]><a>&b;</a>") }
reject { _ = try xml(String(repeating: "<a>", count: 65) + String(repeating: "</a>", count: 65)) }
reject { _ = try xml("<a>") }
let s = try xml("<p:sld xmlns:p='p' xmlns:a='a' xmlns:r='r'><p:cSld><p:spTree><p:sp><p:spPr><a:xfrm><a:off x='12700' y='25400'/><a:ext cx='127000' cy='254000'/></a:xfrm></p:spPr><p:txBody><a:p><a:r><a:t>Hello &amp; </a:t></a:r><a:r><a:t>world</a:t></a:r></a:p><a:p><a:r><a:t>second</a:t></a:r></a:p></p:txBody></p:sp><p:pic><a:blip r:embed='img'/></p:pic></p:spTree></p:cSld></p:sld>")
let items = NativeSlides.items(s)
assert(items.count == 2 && items[0].text == "Hello & world\nsecond")
assert(items[0].box?.x == 1 && items[0].box?.height == 20 && items[1].imageID == "img")
assert(NativeSlides.items(try xml("<sld><spTree/></sld>")).isEmpty)
assert(!NativeSlides.supports(input: URL(fileURLWithPath: "/a.ppt"), format: "pdf"))
print("slides reader PASS")
'''
        # Swift assert autoclosures cannot throw.
        harness = harness.replace('assert(try NativeSlides.slidePaths(presentation: p, relationships: r) ==', 'let paths = try NativeSlides.slidePaths(presentation: p, relationships: r)\nassert(paths ==')
        harness = harness.replace('assert(try NativeSlides.resolve("../media/a.png", relativeTo: "ppt/slides/slide1.xml") ==', 'let media = try NativeSlides.resolve("../media/a.png", relativeTo: "ppt/slides/slide1.xml")\nassert(media ==')
        harness = harness.replace('assert(NativeSlides.items(try xml("<sld><spTree/></sld>")).isEmpty)', 'let blank = try xml("<sld><spTree/></sld>")\nassert(NativeSlides.items(blank).isEmpty)')
        with tempfile.TemporaryDirectory() as d:
            main = pathlib.Path(d) / "main.swift"
            main.write_text(harness)
            binary = pathlib.Path(d) / "test"
            env = dict(os.environ)
            env["LD_LIBRARY_PATH"] = "/tmp/swift-libs:" + env.get("LD_LIBRARY_PATH", "")
            subprocess.run([swift, str(ROOT / "Margherita/NativeSlides.swift"), str(main), "-o", str(binary)], env=env, check=True, capture_output=True)
            run = subprocess.run([str(binary)], env=env, check=True, capture_output=True, text=True)
            self.assertIn("PASS", run.stdout)

if __name__ == "__main__":
    unittest.main()
