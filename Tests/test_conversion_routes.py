"""Compile the actual Foundation-only route registry on Linux, not a Python reimplementation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
ROOT = Path(__file__).resolve().parents[1]

class ConversionRouteContracts(unittest.TestCase):
    def test_compiled_registry(self):
        swift = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
        if not Path(swift).exists():
            self.skipTest("Swift toolchain unavailable")
        program = r'''
import Foundation
var native = ConversionRoutes.Facts()
native.imageInputs = ConversionRoutes.images
native.imageOutputs = ["jpg", "png", "tiff", "gif"]
native.audioOutputs = ["wav", "aiff", "caf"]
native.documentRoutes = ["pdf": ["txt", "docx", "png", "jpg"], "srt": ["vtt", "txt"], "xls": ["csv"]]
var enhanced = native
enhanced.mediaOutputs = Set(ConversionRoutes.targets.filter {
    ConversionRoutes.audio.contains($0) || ConversionRoutes.videos.contains($0) || ["gif", "webp", "avif", "bmp"].contains($0)
})
let sources = Array(ConversionRoutes.images.union(ConversionRoutes.videos).union(ConversionRoutes.audio).union(ConversionRoutes.documents).union(ConversionRoutes.archives))
for facts in [native, enhanced] {
    for source in sources {
        let outputs = ConversionRoutes.outputs(source: source, facts: facts)
        precondition(Set(outputs).count == outputs.count)
        precondition(!outputs.contains(source))
        for target in ConversionRoutes.targets {
            precondition(outputs.contains(target) == ConversionRoutes.supports(source: source, target: target, facts: facts))
            if ConversionRoutes.audio.contains(source) && ConversionRoutes.videos.contains(target) {
                precondition(!ConversionRoutes.supports(source: source, target: target, facts: facts))
            }
        }
    }
}
for (a,b) in [("JPEG","jpg"),("TIF","tiff"),("GZIP","gz"),("TGZ","gz"),("CLIPPING","textclipping"),("AIF","aiff"),("HEIF","heic")] {
    precondition(ConversionRoutes.outputs(source: a, facts: enhanced) == ConversionRoutes.outputs(source: b, facts: enhanced))
}
precondition(!ConversionRoutes.supports(source: "mkv", target: "mp4", facts: native))
precondition(ConversionRoutes.supports(source: "mkv", target: "mp4", facts: enhanced))
precondition(ConversionRoutes.supports(source: "mp4", target: "gif", facts: native))
precondition(ConversionRoutes.supports(source: "gif", target: "m4v", facts: enhanced))
precondition(!ConversionRoutes.supports(source: "gif", target: "m4v", facts: native))
precondition(ConversionRoutes.supports(source: "srt", target: "vtt", facts: native))
precondition(!ConversionRoutes.supports(source: "srt", target: "docx", facts: native))
precondition(ConversionRoutes.supports(source: "xls", target: "csv", facts: native))
precondition(!ConversionRoutes.supports(source: "rar", target: "zip", facts: native))
var provenArchive = native
provenArchive.archiveInputs.insert("rar")
precondition(ConversionRoutes.supports(source: "rar", target: "zip", facts: provenArchive))
var ffmpegOnly = enhanced
ffmpegOnly.imageInputs.remove("avif")
precondition(!ConversionRoutes.supports(source: "avif", target: "pdf", facts: ffmpegOnly))
precondition(ConversionRoutes.supports(source: "avif", target: "webp", facts: ffmpegOnly))
precondition(!ConversionRoutes.supports(source: "avif", target: "jpg", facts: ffmpegOnly))
precondition(ConversionRoutes.supports(source: "svg", target: "pdf", facts: native))
precondition(ConversionRoutes.supports(source: "svg", target: "png", facts: native))
print("registry contracts passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / "main.swift"
            main.write_text(program)
            binary = Path(directory) / "contracts"
            subprocess.run([swift, str(ROOT / "Margherita/ConversionRoutes.swift"), str(main), "-o", str(binary)], check=True, capture_output=True, text=True, env=ENV)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, env=ENV)
            self.assertIn("registry contracts passed", result.stdout)

if __name__ == "__main__":
    unittest.main()
