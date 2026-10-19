"""Real timing-plan compilation everywhere; AVFoundation/ImageIO integration on macOS."""
import os
import json
import re
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "Margherita/GIFSampling.swift"
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))

TIMING = r"""
import Foundation
@main struct TimingTest {
    static func main() throws {
        for seconds in [0.001, 0.1, 1.0, 2.0, 5.0, 10.25, 29.999, 30.0] {
            let p = try GIFSamplingPlan(duration: seconds)
            precondition(p.frameCount == min(450, max(1, Int(ceil(seconds * 15)))))
            var sum = 0.0
            for i in 0..<p.frameCount {
                precondition(p.timestamp(for: i) >= 0 && p.timestamp(for: i) < seconds)
                precondition(abs(p.timestamp(for: i) - Double(i) / 15) < 0.000001)
                let delay = p.delay(for: i)
                precondition(delay >= 0.02 && delay <= 0.07)
                precondition(abs(delay * 100 - (delay * 100).rounded()) < 0.000001)
                sum += delay
            }
            precondition(abs(sum - seconds) <= 0.021)
        }
        let p = try GIFSamplingPlan(duration: 2)
        precondition(p.frameCount == 30)
        precondition(p.delay(for: 0) == 0.07)
        precondition(p.delay(for: 1) == 0.06)
        for invalid in [0.0, -1.0, Double.nan, Double.infinity, 30.001] {
            do {
                _ = try GIFSamplingPlan(duration: invalid)
                fatalError("Accepted invalid duration")
            } catch GIFExportError.invalidDuration {}
        }
        print("Timing plan checked")
    }
}
"""

MAC = r"""
import Foundation
import AVFoundation
import ImageIO
import CoreGraphics

@main struct GIFIntegration {
    static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try await NativeVideoGIF.convert(input: input, output: output)
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              let global = CGImageSourceCopyProperties(source, nil) as? [String: Any],
              let gif = global[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        else { fatalError("Unreadable GIF") }
        precondition((gif[kCGImagePropertyGIFLoopCount as String] as? NSNumber)?.intValue == 0)
        let count = CGImageSourceGetCount(source)
        precondition(count == 30, "Expected 2 seconds * 15 fps, got \(count)")
        var fingerprints = Set<Data>()
        var duration = 0.0
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
                  let frame = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                  let delay = frame[kCGImagePropertyGIFDelayTime as String] as? NSNumber,
                  let unclamped = frame[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber
            else { fatalError("Missing frame/delay metadata") }
            precondition(image.width <= 480 && image.height <= 480)
            precondition(abs(delay.doubleValue - unclamped.doubleValue) < 0.001)
            precondition(delay.doubleValue >= 0.06 && delay.doubleValue <= 0.071)
            duration += delay.doubleValue
            // Canonical pixels, not compressed bytes or palette indices.
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let width = image.width
            let height = image.height
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            fingerprints.insert(Data(pixels))
        }
        precondition(abs(duration - 2) < 0.011)
        precondition(fingerprints.count >= 25, "Repeated/keyframe-snapped frames: \(fingerprints.count)")
        let cancelledOutput = output.deletingPathExtension().appendingPathExtension("cancelled.gif")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await NativeVideoGIF.convert(input: input, output: cancelledOutput)
        }
        do { try await task.value; fatalError("Cancellation ignored") }
        catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: cancelledOutput.path))
        print("GIF frames=\(count) distinct=\(fingerprints.count) duration=\(duration)")
    }
}
"""


class GIFSamplingTests(unittest.TestCase):
    def compile_run(self, source, args=()):
        if not Path(SWIFTC).exists():
            self.skipTest("Swift compiler unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            main = path / "Check.swift"
            main.write_text(source)
            binary = path / "check"
            c = subprocess.run([SWIFTC, "-swift-version", "5", "-parse-as-library",
                                str(HELPER), str(main), "-o", str(binary)],
                               env=ENV, text=True, capture_output=True)
            self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
            r = subprocess.run([str(binary), *map(str, args)], env=ENV, text=True,
                               capture_output=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_real_pure_timing_plan(self):
        self.compile_run(TIMING)

    def test_engine_uses_bounded_exact_native_export(self):
        engine = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        self.assertIn("try await NativeVideoGIF.convert(input: input, output: output, options: options)", engine)
        source = HELPER.read_text()
        for token in ["requestedTimeToleranceBefore = .zero", "requestedTimeToleranceAfter = .zero",
                      "options.gifWidth", "kCGImagePropertyGIFUnclampedDelayTime",
                      "kCGImagePropertyGIFDelayTime", "kCGImagePropertyGIFLoopCount: 0",
                      "try autoreleasepool", "Task.checkCancellation()", "removeItem(at: output)"]:
            self.assertIn(token, source)

    def test_ffmpeg_route_matches_frame_rate_and_size(self):
        source = (ROOT / "Margherita/ExtendedMedia.swift").read_text()
        gif = source.split('} else if video == "gif" {', 1)[1].split('} else {', 1)[0]
        for token in ['options.gifFPS', 'options.gifWidth', 'options.gifLoop', 'paletteuse=dither=']:
            self.assertIn(token, gif)
        self.assertNotIn("fps=12", gif)
        self.assertNotIn('"-t"', gif)
        self.assertNotIn('"-frames:v"', gif)

    def test_real_ffmpeg_output_timing_size_and_full_duration(self):
        ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
        if not ffmpeg or not ffprobe:
            self.skipTest("Local FFmpeg and ffprobe required")
        # Compile production helper, exercising runtime options rather than argv literals.
        source = (ROOT / "Margherita/ExtendedMedia.swift").read_text().replace('"/usr/local/bin/ffmpeg"', json.dumps(ffmpeg))
        audit = (ROOT / "Tests/test_v9_media_audit.py").read_text()
        stub = audit.split('(d/"main.swift").write_text(r' + chr(39)*3, 1)[1].split(chr(39)*3 + ')', 1)[0]
        stub = stub.replace("var maxDimension = 120", "var maxDimension = 0").replace("var videoHeight = 120", "var videoHeight = 0")
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "Extended.swift").write_text(source)
            (folder / "main.swift").write_text(stub)
            binary = folder / "gif-converter"
            compiled = subprocess.run([SWIFTC, "-swift-version", "5", str(ROOT / "Margherita/ConversionCancellation.swift"), str(folder / "Extended.swift"), str(folder / "main.swift"), "-o", str(binary)], env=ENV, text=True, capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            for seconds, expected in [(2, 30), (31, 465)]:
                clip, output = folder / f"clip{seconds}.mp4", folder / f"out{seconds}.gif"
                commands = [
                    [ffmpeg, "-v", "error", "-f", "lavfi", "-i",
                     f"testsrc2=size=640x360:rate=30:duration={seconds}",
                     "-c:v", "libx264", "-preset", "ultrafast", "-g", "300",
                     "-pix_fmt", "yuv420p", str(clip)],
                    [str(binary), str(clip), str(output), "gif"]
                ]
                for command in commands:
                    result = subprocess.run(command, text=True, capture_output=True, timeout=120, env=ENV)
                    self.assertEqual(result.returncode, 0, result.stderr)
                probe = subprocess.run(
                    [ffprobe, "-v", "error", "-show_streams", "-show_frames",
                     "-of", "json", str(output)], capture_output=True, text=True, timeout=60)
                self.assertEqual(probe.returncode, 0, probe.stderr)
                data = json.loads(probe.stdout)
                stream = data["streams"][0]
                self.assertEqual((stream["width"], stream["height"]), (480, 270))
                frames = data["frames"]
                self.assertEqual(len(frames), expected)
                delays = [float(frame["pkt_duration_time"]) for frame in frames]
                self.assertTrue(all(0.059 <= delay <= 0.071 for delay in delays), delays[:10])
                self.assertLess(abs(sum(delays) - seconds), 0.021)
                self.assertLess(abs(float(stream["duration"]) - seconds), 0.021)
                self.assertIn(b"NETSCAPE2.0", output.read_bytes())
                # Distinct decoded frame checks catch keyframe-only sampling.
                hashes = subprocess.run(
                    [ffmpeg, "-v", "error", "-i", str(output), "-f", "framemd5", "-"],
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(hashes.returncode, 0, hashes.stderr)
                checksums = {line.rsplit(",", 1)[-1].strip()
                             for line in hashes.stdout.splitlines() if not line.startswith("#")}
                self.assertGreaterEqual(len(checksums), int(expected * 0.8))

    @unittest.skipUnless(platform.system() == "Darwin", "AVFoundation requires macOS")
    def test_mac_long_gop_motion_and_metadata(self):
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            self.skipTest("Install FFmpeg locally to generate the synthetic moving clip")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            clip = path / "long-gop.mp4"
            # One keyframe for the whole clip catches default keyframe snapping.
            c = subprocess.run([ffmpeg, "-v", "error", "-f", "lavfi", "-i",
                                "testsrc2=size=640x360:rate=30:duration=2",
                                "-c:v", "libx264", "-g", "300", "-keyint_min", "300",
                                "-sc_threshold", "0", "-pix_fmt", "yuv420p", str(clip)],
                               text=True, capture_output=True, timeout=60)
            self.assertEqual(c.returncode, 0, c.stderr)
            self.compile_run(MAC, (clip, path / "motion.gif"))


if __name__ == "__main__":
    unittest.main()
