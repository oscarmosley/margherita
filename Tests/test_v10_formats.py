"""v10 Formats tab source contracts (Linux cannot compile SwiftUI)."""
from pathlib import Path
import re, unittest
ROOT = Path(__file__).resolve().parents[1]
S = (ROOT / "Margherita/FormatSettingsViews.swift").read_text()
V = (ROOT / "Margherita/Views.swift").read_text()
def balanced(s):
    return all(s.count(a) == s.count(b) for a, b in ("{}", "()", "[]"))
class V10Formats(unittest.TestCase):
    def test_balanced(self):
        self.assertTrue(balanced(S)); self.assertTrue(balanced(V))
    def test_old_detail_removed(self):
        self.assertNotIn("struct FormatDetail", V); self.assertNotIn("struct FormatsTab", V)
        self.assertIn("struct FormatSettingsDetail", S); self.assertIn("struct FormatsTab", S)
    def test_catalog_complete(self):
        for f in ["JPG","HEIC","TIFF","AVIF","SVG","PDF","DOCX","PAGES","PPTX","PPT","CSV","XLS","MP3","CAF","WMA","MP4","M4V","GIF","ZIP","TGZ","BZ2","XZ","7Z","RAR","SRT","VTT"]:
            self.assertIn('"%s"' % f, S)
        for a in ["heif","jpeg","tif","aif","gz","tar.gz","bzip2","7zip"]:
            self.assertIn('"%s"' % a, S)
    def test_gif_under_video_not_images(self):
        img = S[S.index('name: "Images"'):S.index('name: "Documents"')]
        vid = S[S.index('name: "Video"'):S.index('name: "Archives"')]
        self.assertNotIn('"GIF"', img); self.assertIn('"GIF"', vid)
    def test_input_only_marked(self):
        for f in ["SVG","PPT","BZ2","XZ","7Z","RAR"]:
            self.assertRegex(S, r'"%s"[^\n]*\.inputOnly' % f)
    def test_search_uses_aliases(self):
        self.assertIn("entry.aliases.contains", S)
        self.assertIn("FormatCatalog.matches", S)
    def test_per_format_store_not_globals(self):
        self.assertIn("FormatSettingsStore.shared", S)
        self.assertNotIn("prefs.imageQuality", S); self.assertNotIn("FormatExtras", S)
        self.assertIn("store.resetConversion(for: key)", S); self.assertIn("store.resetCompression(for: key)", S)
    def test_every_profile_field_has_ui(self):
        for f in ["compressionMode","imageQuality","maxDimension","stripMetadata","colorMode","gifFPS","gifWidth","gifLoop","gifDither","videoCodec","videoQuality","videoHeight","videoFPS","audioBitrate","audioSampleRate","audioChannels","pdfImageQuality","ocrLanguage","archiveCompression","documentLayout"]:
            self.assertIn(f, S, f)
    def test_ffmpeg_gating(self):
        for f in ["videoCodec","videoHeight","videoFPS","audioSampleRate","audioChannels","gifDither"]:
            m = re.search(r"bind\(\\\.%s\)[\s\S]{0,260}?disabled\(!ffmpeg" % f, S)
            self.assertIsNotNone(m, f)
        self.assertIn("Needs FFmpeg", S); self.assertIn("does not dither", S)
    def test_honest_scoping(self):
        self.assertIn('["MP3", "M4A", "OGG", "OPUS", "WMA"]', S)
        self.assertIn('["MP4", "MOV"].contains(format)', S)
        self.assertIn("if codecOverridable {", S)
        self.assertIn("Compress Tool Settings", S)
        self.assertIn("These settings apply when exporting to", S)
        self.assertIn("not every conversion path applies it yet", S)
        self.assertIn("Normal conversions never read it", S)
    def test_ocr_languages(self):
        for l in ["auto","en-US","zh-Hans","de-DE","fr-FR","es-ES"]: self.assertIn('"%s"' % l, S)
        self.assertIn("Only used when you run OCR Text", S)
    def test_tar_has_no_compression(self):
        self.assertIn('["ZIP", "GZIP"].contains(key)', S)
    def test_readonly_archives_and_honest_codecs(self):
        self.assertIn("readOnlyArchive", S); self.assertIn("read-only in Margherita", S)
        self.assertNotIn('"vp9"', S)
        self.assertIn("codecOverridable", S)
        gif = S[S.index("private var gifRows"):S.index("private var videoRows")]
        self.assertNotIn("tag(0)", gif)
    def test_no_banned_swiftui_macros(self):
        for bad in ["@State ", "@StateObject", "@Observable", "#Preview"]: self.assertNotIn(bad, S)
if __name__ == "__main__": unittest.main()
