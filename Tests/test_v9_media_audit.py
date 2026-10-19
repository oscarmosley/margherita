"""Compile actual ExtendedMedia and fully decode a generated media route matrix."""
import concurrent.futures, json, os, re
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
AUDIO = "mp3 flac ogg opus wma wav aiff caf m4a".split()
VIDEO = "mp4 mov m4v mkv webm avi wmv".split()
IMAGE = "gif webp avif bmp".split()
CODECS = dict(zip(AUDIO+VIDEO+IMAGE, "mp3 flac vorbis opus wmav2 pcm_s16le pcm_s16be pcm_s16le aac h264 h264 h264 h264 vp9 mpeg4 wmv2 gif webp av1 bmp".split()))
def run(args):
    p = subprocess.run(list(map(str,args)), capture_output=True,text=True,timeout=120,env=ENV)
    if p.returncode: raise AssertionError(p.stdout+p.stderr)
    return p.stdout
def probe(path):
    return json.loads(run(["ffprobe","-v","error","-show_streams","-show_format","-of","json",path]))
class MediaAudit(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ffmpeg") and Path(SWIFTC).exists(), "Requires Swift and FFmpeg")
    def test_real_routes(self):
        rows=[]
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp)
            # Discovery-only substitution: production does not search Linux PATH.
            source=(ROOT/"Margherita/ExtendedMedia.swift").read_text().replace('"/usr/local/bin/ffmpeg"',json.dumps(shutil.which("ffmpeg")))
            self.assertEqual(set(re.findall(r'"(\w+)": Profile\(', source)),set(AUDIO+VIDEO+IMAGE),
                             "New production profile needs a real matrix case")
            (d/"ExtendedMedia.swift").write_text(source)
            (d/"main.swift").write_text(r'''
import Foundation
enum MargheritaError: Error { case message(String) }
struct ConversionOptions {
 var gifFPS = 15
 var gifWidth = 480
 var gifLoop = true
 var gifDither = true
 var videoCodec = "auto"
 var videoFPS = 0
 var audioBitrate = 256
 var audioSampleRate = 0
 var audioChannels = 0
 var colorMode = "original"
 var stripMetadata = true
 var audioQuality = 0.8
 var maxDimension = 120
 var videoHeight = 120
 var imageQuality = 0.82
 var videoQuality = "medium"
}
let a = CommandLine.arguments
ExtendedMedia.warmUp()
if a[1] == "supports" {
 for f in a.dropFirst(2) { print("\(f) \(ExtendedMedia.supports(format: f))") }
} else {
 do {
 try ExtendedMedia.convert(input: URL(fileURLWithPath:a[1]), to:URL(fileURLWithPath:a[2]),format:a[3],options:ConversionOptions())
 } catch { print(error); exit(1) }
}
''')
            binary=d/"media"
            run([SWIFTC,"-swift-version","5",ROOT/"Margherita/ConversionCancellation.swift",d/"ExtendedMedia.swift",d/"main.swift","-o",binary])
            caps=dict(line.split() for line in run([binary,"supports",*AUDIO,*VIDEO,*IMAGE]).splitlines())
            base=d/"base.mp4"
            run(["ffmpeg","-v","error","-f","lavfi","-i","testsrc2=size=160x120:rate=30:duration=1.2","-f","lavfi","-i","sine=frequency=440:sample_rate=48000:duration=1.2","-c:v","libx264","-threads","1","-c:a","aac","-shortest",base])
            fixtures={}
            for ext in AUDIO+VIDEO+IMAGE:
                if caps[ext]!="true":
                    rows.append(dict(source="fixture",target=ext,status="unavailable_encoder_or_muxer")); continue
                path=d/("source."+ext)
                try:
                    run([binary,base,path,ext]); fixtures[ext]=path
                except Exception as e: rows.append(dict(source="fixture",target=ext,status="fail",detail=str(e)))
            for ext in ["png", "jpg", "tiff"]:
                path=d/("source."+ext)
                run(["ffmpeg","-v","error","-i",base,"-frames:v","1",path])
                fixtures[ext]=path
            # A literal printf-pattern filename must remain a single selected file.
            special=d/"frame%03d.jpg"
            shutil.copyfile(fixtures["jpg"],special)
            fixtures["literal-jpg"]=special
            # Missing audio must fail explicitly, never create a bogus extraction.
            silent=d/"silent.mp4"
            run(["ffmpeg","-v","error","-i",base,"-an","-c:v","copy",silent])
            p=subprocess.run([str(binary),str(silent),str(d/"silent.wav"),"wav"],env=ENV,capture_output=True)
            rows.append(dict(source="silent-video",target="audio-rejection",status="pass" if p.returncode and not (d/"silent.wav").exists() else "fail"))
            fixtures["silent-video"]=silent
            def route(pair):
                src,ext=pair
                out=d/(src+"-to."+ext)
                row=dict(source=src,target=ext)
                try:
                    run([binary,fixtures[src],out,ext])
                    data=probe(out); streams=data["streams"]
                    audio=[s for s in streams if s["codec_type"]=="audio"]
                    video=[s for s in streams if s["codec_type"]=="video"]
                    expected_stream=audio[0] if ext in AUDIO else video[0]
                    assert expected_stream["codec_name"] == CODECS[ext], expected_stream
                    if ext in AUDIO:
                        assert audio and not video,streams
                        assert int(audio[0]["channels"])>0 and int(audio[0]["sample_rate"])>=8000
                    else:
                        assert video,streams
                        v=video[0]
                        assert 0<v["width"]<=480 and 0<v["height"]<=120,v
                        if ext in VIDEO and src in VIDEO:
                            assert audio,"Lost audio"
                            n,den=map(float,v["avg_frame_rate"].split("/"))
                            assert abs(n/den-30)<0.2,v
                        if ext in IMAGE: assert not audio
                        if ext == "gif" and src in VIDEO+["gif"]:
                            # GIF avg_frame_rate may report inverse minimum delay (16.67),
                            # not the true alternating 6/7-centisecond frame cadence.
                            assert abs(int(v["nb_frames"])/float(v["duration"])-15)<0.2,v
                    if ext in AUDIO+VIDEO or (ext=="gif" and src in VIDEO):
                        duration=float(data["format"].get("duration",streams[0].get("duration",0)))
                        assert abs(duration-1.2)<0.25,duration
                        row["duration"]=duration
                    run(["ffmpeg","-v","error","-xerror","-i",out,"-map","0","-f","null","-"])
                    row.update(status="pass",streams=[{k:s[k] for k in ("codec_name","codec_type","width","height","sample_rate","channels","avg_frame_rate") if k in s} for s in streams])
                except Exception as e: row.update(status="fail",detail=str(e))
                return row
            pairs=[]
            for src in fixtures:
                targets=AUDIO if src in AUDIO else (AUDIO+VIDEO+IMAGE if src in VIDEO else (VIDEO+IMAGE if src=="silent-video" else IMAGE+(VIDEO if src=="gif" else [])))
                pairs += [(src,e) for e in targets if caps[e]=="true"]
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: rows.extend(pool.map(route,pairs))
            for name in ["directory","playlist","invalid","overwrite"]:
                inp=d if name=="directory" else d/(name+".m3u")
                out=d/(name+".wav")
                if name not in ["directory","overwrite"]: inp.write_text("#EXTM3U\nhttp://127.0.0.1:9/remote.mp3\n" if name=="playlist" else "invalid audio")
                if name=="overwrite": inp=base;out.write_bytes(b"preserve")
                p=subprocess.run([str(binary),str(inp),str(out),"wav"],env=ENV,capture_output=True,timeout=20)
                safe=out.read_bytes()==b"preserve" if name=="overwrite" else not out.exists()
                rows.append(dict(source=name,target="safety",status="pass" if p.returncode and safe else "fail"))
        artifact=dict(ffmpeg_version=run(["ffmpeg","-version"]).splitlines()[0],swift_version=run([SWIFTC,"--version"]).splitlines()[0],platform=os.uname().sysname,production_source="Margherita/ExtendedMedia.swift",discovery_override_only=True,native_audio="not executed; macOS required",routes=rows)
        (ROOT/"Tests/media-audit.json").write_text(json.dumps(artifact,indent=2)+"\n")
        self.assertFalse([r for r in rows if r["status"]=="fail"],json.dumps([r for r in rows if r["status"]=="fail"],indent=2))
if __name__=="__main__": unittest.main()
