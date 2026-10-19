"""Execute persisted profiles and real options resolution using Foundation Swift."""
from pathlib import Path
import subprocess, tempfile, unittest
from test_native_documents_archives import ROOT, SWIFTC, ENV

class ProfileTests(unittest.TestCase):
    def test_independent_profiles_persist_resolve_and_reset(self):
        profile = (ROOT / "Margherita/PerFormatSettings.swift").read_text().replace("import Combine", """
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
 var wrappedValue: Value
 init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
""")
        models = (ROOT / "Margherita/Models.swift").read_text()
        options = models[models.index("struct ConversionOptions: Sendable"):models.index("\nstruct HistoryEntry:")]
        main = r'''
@main struct ProfileTest {
 @MainActor static func main() {
  let suite = "margherita-tests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = FormatSettingsStore(defaults: defaults)
  var gif = store.profile(for: "GIF")
  gif.gifFPS = 24; gif.gifWidth = 960; gif.gifLoop = false
  gif.compressionMode = "strong"
  store.set(gif, for: "GIF")
  var jpg = store.profile(for: "JPEG")
  jpg.imageQuality = 0.45; jpg.colorMode = "srgb"
  store.set(jpg, for: "JPEG")
  assert(store.profile(for: "JPG").imageQuality == 0.45)
  assert(store.profile(for: "PNG").imageQuality == 0.82)
  assert(store.profile(for: "GIF").gifFPS == 24)
  var archive = store.profile(for: "ZIP")
  archive.archiveCompression = "small"
  store.set(archive, for: "ZIP")
  store.resetConversion(for: "ZIP")
  assert(store.profile(for: "ZIP").archiveCompression == "small")
  store.resetCompression(for: "ZIP")
  assert(store.profile(for: "ZIP").archiveCompression == "balanced")
  let reload = FormatSettingsStore(defaults: defaults)
  assert(reload.profiles == store.profiles)
  var snapshot = ConversionOptions()
  snapshot.formatProfiles = store.profiles
  let resolved = snapshot.resolved(for: "gif")
  assert(resolved.gifFPS == 24 && resolved.gifWidth == 960 && !resolved.gifLoop)
  assert(snapshot.gifFPS == 15)
  store.resetConversion(for: "GIF")
  assert(store.profile(for: "GIF").gifFPS == 15)
  assert(store.profile(for: "GIF").compressionMode == "strong")
  var adjusted = store.profile(for: "GIF")
  adjusted.gifFPS = 12
  store.set(adjusted, for: "GIF")
  store.resetCompression(for: "GIF")
  assert(store.profile(for: "GIF").gifFPS == 12)
  assert(store.profile(for: "GIF").compressionMode == "balanced")
  assert(snapshot.resolved(for: "GIF").gifFPS == 24)
 }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            swift = root / "Profiles.swift"
            swift.write_text(profile + options + main)
            subprocess.run([SWIFTC, "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(root/"test")], env=ENV, check=True, capture_output=True)
            subprocess.run([str(root/"test")], env=ENV, check=True)

if __name__ == "__main__":
    unittest.main()
