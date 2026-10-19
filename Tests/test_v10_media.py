"""Compile production media helper and inspect real encoded output on Linux."""
import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
STUB = r"""
import Foundation
enum MargheritaError: Error { case message(String) }
struct ConversionOptions {
 var stripMetadata = true
 var audioQuality = 0.8
 var maxDimension = 120
 var videoHeight = 120
 var imageQuality = 0.82
 var videoQuality = "balanced"
 var gifFPS = 10
 var gifWidth = 128
 var gifLoop = true
 var gifDither = true
 var videoCodec = "auto"
 var videoFPS = 12
 var audioBitrate = 96
 var audioSampleRate = 32000
 var audioChannels = 1
}
@main struct Check {
 static func main() throws {
  let a = CommandLine.arguments
  for fps in [1, 10, 24, 50] {
   let p = try GIFSamplingPlan(duration: 30, framesPerSecond: fps)
   precondition(p.frameCount == 30 * fps)
   precondition(p.timestamp(for: p.frameCount-1) < 30)
  }
  ExtendedMedia.warmUp()
  var o = ConversionOptions()
  o.videoCodec = a[4]; o.gifLoop = a[5] == "true"; o.gifDither = a[6] == "true"
  try ExtendedMedia.convert(input: URL(fileURLWithPath: a[1]), to: URL(fileURLWithPath: a[2]), format: a[3], options: o)
 }
}
"""
def run(args):
    p = subprocess.run(list(map(str,args)), capture_output=True, text=True, env=ENV, timeout=180)
    if p.returncode: raise AssertionError(p.stdout + p.stderr)
    return p.stdout
def probe(p):
    return json.loads(run(["ffprobe","-v","error","-show_streams","-show_format","-of","json",p]))
class LiveMediaSettings(unittest.TestCase):
    @unittest.skipUnless(Path(SWIFTC).exists() and shutil.which("ffmpeg"), "Swift and FFmpeg required")
    def test_real_options(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp)
            source=(ROOT/"Margherita/ExtendedMedia.swift").read_text().replace('"/usr/local/bin/ffmpeg"',json.dumps(shutil.which("ffmpeg")))
            (d/"Extended.swift").write_text(source)
            (d/"Check.swift").write_text(STUB)
            binary=d/"check"
            run([SWIFTC,"-swift-version","5",ROOT/"Margherita/ConversionCancellation.swift","-parse-as-library",d/"Extended.swift",ROOT/"Margherita/GIFSampling.swift",d/"Check.swift","-o",binary])
            base=d/"input.mp4"
            run(["ffmpeg","-v","error","-f","lavfi","-i","testsrc2=size=320x240:rate=30:duration=2","-f","lavfi","-i","sine=frequency=440:sample_rate=48000:duration=2","-c:v","libx264","-threads","1","-c:a","aac","-shortest",base])
            for ext, codec, expected in [("mp4","h264","h264"),("mov","hevc","hevc"),("webm","auto","vp9")]:
                out=d/("video."+ext)
                # Opus cannot encode 32000 Hz, so explicit incompatible sample rates must error.
                if ext == "webm":
                    p=subprocess.run([str(binary),str(base),str(out),ext,codec,"true","true"],env=ENV,capture_output=True)
                    self.assertNotEqual(p.returncode,0)
                    self.assertFalse(out.exists())
                    continue
                run([binary,base,out,ext,codec,"true","true"])
                streams=probe(out)["streams"]
                v=next(s for s in streams if s["codec_type"]=="video")
                a=next(s for s in streams if s["codec_type"]=="audio")
                self.assertEqual(v["codec_name"],expected)
                self.assertEqual(v["height"],120)
                self.assertEqual(v["avg_frame_rate"],"12/1")
                self.assertEqual(a["sample_rate"],"32000")
                self.assertEqual(a["channels"],1)
                self.assertTrue(60000 < int(a["bit_rate"]) < 115000)
            for ext in ["mp3","wav","flac","aiff","caf","ogg","m4a","wma"]:
                out=d/("audio."+ext)
                run([binary,base,out,ext,"auto","true","true"])
                a=probe(out)["streams"][0]
                self.assertEqual(a["channels"],1)
                self.assertEqual(a["sample_rate"],"32000")
            hashes=[]
            for loop, dither in [(True,True),(False,False)]:
                out=d/("gif"+str(loop)+".gif")
                run([binary,base,out,"gif","auto",str(loop).lower(),str(dither).lower()])
                v=probe(out)["streams"][0]
                self.assertEqual((v["width"],v["height"]),(128,96))
                self.assertEqual(int(v["nb_frames"]),20)
                self.assertAlmostEqual(float(v["duration"]),2,places=1)
                self.assertEqual(b"NETSCAPE2.0" in out.read_bytes(),loop)
                hashes.append(run(["ffmpeg","-v","error","-i",out,"-f","framemd5","-"]))
            self.assertNotEqual(hashes[0],hashes[1],"Dither toggle must affect actual pixels")
            for ext,codec in [("mkv","hevc"),("gif","h264"),("mp4","bogus")]:
                out=d/("bad"+ext+"."+ext)
                p=subprocess.run([str(binary),str(base),str(out),ext,codec,"true","true"],env=ENV,capture_output=True)
                self.assertNotEqual(p.returncode,0)
                self.assertFalse(out.exists())
if __name__ == "__main__": unittest.main()
