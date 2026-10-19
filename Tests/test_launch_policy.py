"""Source contract for quiet launch. A real LaunchServices smoke test still needs macOS."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "Margherita/MargheritaApp.swift").read_text()
def body(signature):
    start = SOURCE.index(signature)
    pos = SOURCE.index("{", start) + 1
    end, depth = pos, 1
    while depth:
        if SOURCE[end] == "{": depth += 1
        if SOURCE[end] == "}": depth -= 1
        end += 1
    return SOURCE[pos:end - 1]
class LaunchPolicy(unittest.TestCase):
    def test_launch_only_schedules_first_run_onboarding(self):
        launch = body("func applicationDidFinishLaunching")
        self.assertNotRegex(launch, r"\b(openSettings|present|makeKeyAndOrderFront)\s*\(")
        self.assertIn("onboardingCompletedV2", launch)
        self.assertNotIn("UserDefaults.standard.set(true", launch)
    def test_no_swiftui_lifecycle_or_settings_scene(self):
        self.assertIn("enum MargheritaApp", SOURCE)
        self.assertIn("application.delegate = delegate", SOURCE)
        self.assertIn("withExtendedLifetime(delegate) { application.run() }", SOURCE)
        self.assertNotIn("@NSApplicationDelegateAdaptor", SOURCE)
        self.assertNotRegex(SOURCE, r"\b(?:WindowGroup|Settings)\s*\{")
        self.assertNotRegex(SOURCE, r"var body\s*:\s*some Scene")
    def test_explicit_reopen_opens_settings_only_when_running(self):
        reopen = body("func applicationShouldHandleReopen")
        self.assertLess(reopen.index("guard acceptsReopen else { return false }"), reopen.index("openSettings()"))
        self.assertIn("return false", reopen)
        self.assertIn("DispatchQueue.main.async { [weak self] in self?.acceptsReopen = true }",
                      body("func applicationDidFinishLaunching"))
    def test_restoration_disabled_before_launch_and_per_window(self):
        entry = body("static func main()")
        self.assertLess(entry.index('forKey: "NSQuitAlwaysKeepsWindows"'), entry.index("NSApplication.shared"))
        self.assertIn('set(true, forKey: "ApplePersistenceIgnoreState")', entry)
        self.assertIn("false", body("func applicationShouldSaveApplicationState"))
        self.assertIn("false", body("func applicationShouldRestoreApplicationState"))
        self.assertIn("window.isRestorable = false", body("@objc func openSettings"))
    def test_settings_has_exactly_one_owner(self):
        root = Path(__file__).resolve().parents[1] / "Margherita"
        owners = [(p.name, p.read_text().count("SettingsView()")) for p in root.glob("*.swift")]
        self.assertEqual([(n, count) for n, count in owners if count], [("MargheritaApp.swift", 1)])
        settings = body("@objc func openSettings")
        self.assertIn("if settingsWindow == nil", settings)
        self.assertIn("present(settingsWindow)", settings)
        for name in ["KeyboardShortcut.swift"]:
            self.assertIn("AppDelegate.shared?.openSettings()", (root / name).read_text())
        self.assertIn('addItem("Settings…", #selector(openSettings), to: app, key: ",")', SOURCE)
        self.assertIn('addItem("Settings…", #selector(openSettings), to: menu, key: ",")', SOURCE)
    def test_no_main_window(self):
        self.assertNotIn("openMain", SOURCE); self.assertNotIn("MainView", SOURCE); self.assertNotIn("mainWindow", SOURCE)
    def test_initial_file_open_stays_quiet(self):
        callback = body("func application(_ application: NSApplication, open urls:")
        self.assertIn("AppModel.shared.accept(urls)", callback)
        self.assertNotRegex(callback, r"open(Main|Settings)|present")
    def test_startup_has_no_permission_prompts(self):
        for signature in ["func applicationDidFinishLaunching", "func applicationWillFinishLaunching"]:
            self.assertNotRegex(body(signature), r"requestAuthorization|runModal|AXIsProcessTrustedWithOptions|CGRequestListenEventAccess")
    def test_last_window_does_not_quit(self):
        self.assertIn("false", body("func applicationShouldTerminateAfterLastWindowClosed"))
if __name__ == "__main__": unittest.main()
