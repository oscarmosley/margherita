"""Syntax check everywhere; actual Core Audio round trips only on macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Margherita/NativeAudio.swift"
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))


class NativeAudioTests(unittest.TestCase):
    def test_swift_syntax(self):
        subprocess.run([SWIFTC, "-frontend", "-parse", str(SOURCE)], check=True, env=ENV)

    def test_format_probe_is_independent_of_input(self):
        source = SOURCE.read_text()
        probe = source.split("static func supportsFormat(_ format: String) -> Bool {", 1)[1].split("static func supports(input:", 1)[0]
        self.assertIn("encoderIDs.contains(kAudioFormatFLAC)", probe)
        self.assertNotIn("AVAudioFile", probe)
        self.assertNotIn("resourceValues", probe)
        self.assertIn("guard supportsFormat(target), input.isFileURL,", source)
        self.assertIn("static func supportsFormat(sourceExtension: String, target: String) -> Bool", source)

    @unittest.skipUnless(os.uname().sysname == "Darwin", "Requires macOS AVFoundation SDK/runtime")
    def test_native_roundtrips(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "main.swift").write_text(r"""
import Foundation
import AVFoundation
enum MargheritaError: Error { case message(String) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let input = root.appendingPathComponent("fixture.wav")
func fixture() throws {
    let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 44100)!
    buffer.frameLength = 44100
    for channel in 0..<2 {
        for frame in 0..<44100 {
            buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.03)) * 0.25
        }
    }
    let writer = try AVAudioFile(forWriting: input, settings: pcm.settings)
    try writer.write(from: buffer)
}
try fixture()
for ext in ["wav", "aiff", "caf"] {
    assert(NativeAudio.supportsFormat(ext))
    assert(NativeAudio.supportsFormat(ext.uppercased()))
}
assert(NativeAudio.supportsFormat("FLAC") == NativeAudio.supportsFormat("flac"))
for source in ["mp3", "m4a", "wav", "aif", "aiff", "caf", "flac"] {
    assert(NativeAudio.supportsFormat(sourceExtension: source, target: "wav"))
    assert(NativeAudio.supportsFormat(sourceExtension: source.uppercased(), target: "AIFF"))
    assert(NativeAudio.supportsFormat(sourceExtension: source, target: "flac") == NativeAudio.supportsFormat("flac"))
}
for source in ["mp4", "mov", "m4v", "ogg", "opus", "wma", "bogus"] {
    assert(!NativeAudio.supportsFormat(sourceExtension: source, target: "wav"))
}
assert(!NativeAudio.supportsFormat(sourceExtension: "wav", target: "mp3"))
assert(!NativeAudio.supports(input: root.appendingPathComponent("missing.wav"), format: "wav"))
for unsupported in ["mp3", "ogg", "opus", "wma", "bogus"] {
    assert(!NativeAudio.supportsFormat(unsupported))
    assert(!NativeAudio.supports(input: input, format: unsupported))
}
assert(!NativeAudio.supports(input: URL(string: "https://example.com/a.wav")!, format: "wav"))
for ext in ["wav", "aiff", "caf", "flac"] {
    if !NativeAudio.supports(input: input, format: ext) {
        assert(ext == "flac", "PCM encoding unexpectedly unavailable")
        print("FLAC encoder absent; enhancer fallback required")
        continue
    }
    let output = root.appendingPathComponent("result." + ext)
    try NativeAudio.convert(input: input, to: output, format: ext)
    let result = try AVAudioFile(forReading: output)
    assert(result.length == 44100)
    assert(result.processingFormat.channelCount == 2)
    assert(result.processingFormat.sampleRate == 44100)
    let original = try Data(contentsOf: output)
    var refused = false
    do { try NativeAudio.convert(input: input, to: output, format: ext) }
    catch { refused = true }
    assert(refused)
    let after = try Data(contentsOf: output)
    assert(after == original)
}
print("native audio round trips passed")
""")
            binary = root / "audio-test"
            subprocess.run([SWIFTC, str(SOURCE), str(root / "main.swift"), "-o", str(binary)],
                           check=True, env=ENV)
            subprocess.run([str(binary), str(root)], check=True, env=ENV)


if __name__ == "__main__":
    unittest.main()
