import SwiftUI
import AppKit

/// AppKit owns the lifecycle. No SwiftUI App/Scene exists to auto-create Settings.
@main
@MainActor
enum MargheritaApp {
    static func main() {
        // Set before NSApplication is created, including launches after an older build.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication.delegate is weak. Keep the delegate alive throughout the event loop.
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    /// Shared handle for all explicit window entry points.
    private(set) static weak var shared: AppDelegate?
    override init() { super.init(); AppDelegate.shared = self }
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var overlay: OverlayController?
    private var acceptsReopen = false
    private var hintItem: NSMenuItem?
    private var clipboardItem: NSMenuItem?
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let prefs = Preferences.shared
        prefs.visibilityChanged = { [weak self] in self?.updateVisibility() }
        prefs.appearanceChanged = { [weak self] in self?.updateAppearance() }
        FormatCapabilities.shared.start()
        updateAppearance(); updateVisibility()
        prefs.syncHotkey(); HeldKeyTracker.shared.start(); HotkeyManager.shared.start()
        buildMainMenu()
        UpdateController.shared.start()
        ConversionHUD.shared.start()
        overlay = OverlayController()
        overlay?.start()
        // The initial LaunchServices open/reopen event is not an explicit reopen of
        // a running app. Arm only after launch callbacks have returned to the event loop.
        DispatchQueue.main.async { [weak self] in self?.acceptsReopen = true }
        OnboardingController.shared.onClose = { [weak self] in self?.refreshActivationPolicy() }
        if !UserDefaults.standard.bool(forKey: "onboardingCompletedV2") {
            DispatchQueue.main.async { [weak self] in self?.openGettingStarted() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard acceptsReopen else { return false }
        openSettings()
        // We handled it. Do not let AppKit restore or display another window.
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        // Just accept the files. Never open a window for them.
        AppModel.shared.accept(urls)
    }
    func applicationWillTerminate(_ notification: Notification) {
        WatchFolders.shared.stop()
        overlay?.stop(); HeldKeyTracker.shared.stop(); HotkeyManager.shared.stop()
    }
    @objc private func checkForUpdates() { UpdateController.shared.checkForUpdates() }
    /// User-initiated only. No prompts, embedded checkout or background requests.
    @objc func openSupport() {
        guard let url = URL(string: "https://buymeacoffee.com/omo1") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 620, height: 560)
            window.title = "Margherita Settings"; window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(Preferences.shared))
            window.delegate = self; window.center(); settingsWindow = window
        }
        present(settingsWindow)
    }
    @objc func openGettingStarted() {
        OnboardingController.shared.show()
        present(OnboardingController.shared.window)
    }
    @objc func openAbout() {
        MargheritaUIState.shared.selectedTab = 5
        openSettings()
        NotificationCenter.default.post(name: .init("MargheritaShowAbout"), object: nil)
    }
    /// Only settings and onboarding count. HUD, shelf and wheel never change activation.
    private var managedWindows: [NSWindow] { [settingsWindow, OnboardingController.shared.window].compactMap { $0 } }
    private func present(_ window: NSWindow?) {
        guard let window = window else { return }
        if NSApp.mainMenu == nil { buildMainMenu() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func refreshActivationPolicy(closing: NSWindow? = nil) {
        let open = managedWindows.contains { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
        let wanted: NSApplication.ActivationPolicy = (Preferences.shared.dock || open) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        refreshActivationPolicy(closing: closing)
    }
    func windowDidMiniaturize(_ notification: Notification) { refreshActivationPolicy() }
    func windowDidDeminiaturize(_ notification: Notification) { refreshActivationPolicy() }
    @objc private func quit() {
        if AppModel.shared.busy {
            let alert = NSAlert()
            alert.messageText = "A conversion is still running"
            alert.informativeText = "Cancel the batch and wait for it to finish before quitting."
            alert.runModal(); return
        }
        NSApp.terminate(nil)
    }
    func updateVisibility() {
        let prefs = Preferences.shared
        // Both off is allowed: LaunchServices reopen always restores Settings, even without a hotkey.
        refreshActivationPolicy()
        if prefs.menuBar && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = AppDelegate.pizzaMenuBarIcon()
                button.toolTip = "Margherita · local file converter"
            }
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            let ready = NSMenuItem(title: "Margherita is ready", action: nil, keyEquivalent: ""); ready.isEnabled = false
            let hint = NSMenuItem(title: AppDelegate.hintText(), action: nil, keyEquivalent: ""); hint.isEnabled = false
            hintItem = hint
            menu.addItem(ready); menu.addItem(hint)
            menu.addItem(.separator())
            let clipboard = NSMenuItem(title: "Convert Clipboard", action: nil, keyEquivalent: "")
            clipboardItem = clipboard
            menu.addItem(clipboard)
            ClipboardConversion.shared.refresh(clipboard)
            menu.addItem(.separator())
            addItem("Settings…", #selector(openSettings), to: menu, key: ",")
            addItem("Check for Updates…", #selector(checkForUpdates), to: menu)
            addItem("Getting Started…", #selector(openGettingStarted), to: menu)
            addItem("About Margherita", #selector(openAbout), to: menu)
            addItem("Support Margherita", #selector(openSupport), to: menu)
            menu.items.last?.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)
            menu.addItem(.separator())
            addItem("Quit Margherita", #selector(quit), to: menu, key: "q")
            item.menu = menu; statusItem = item
        } else if !prefs.menuBar, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
    }
    static func hintText() -> String {
        let p = Preferences.shared
        return "\(p.triggerLabel): Convert · \(p.toolsLabel): Tools · \(p.actionsShortcut.display): Actions"
    }
    func menuWillOpen(_ menu: NSMenu) {
        hintItem?.title = AppDelegate.hintText()
        if let clipboardItem { ClipboardConversion.shared.refresh(clipboardItem) }
    }
    /// Monochrome pizza slice (crust arc, cheese wedge, pepperoni cut-outs). Template image so macOS tints it.
    static func pizzaMenuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            let crust = NSBezierPath()
            crust.lineWidth = 3; crust.lineCapStyle = .round
            crust.move(to: NSPoint(x: 2.5, y: 14.5))
            crust.curve(to: NSPoint(x: 15.5, y: 14.5), controlPoint1: NSPoint(x: 6.5, y: 16.8), controlPoint2: NSPoint(x: 11.5, y: 16.8))
            crust.stroke()
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 9, y: 0.8))
            body.line(to: NSPoint(x: 3.2, y: 12.2))
            body.line(to: NSPoint(x: 14.8, y: 12.2))
            body.close()
            body.appendOval(in: NSRect(x: 7.2, y: 8.6, width: 2.6, height: 2.6))
            body.appendOval(in: NSRect(x: 8.6, y: 4.8, width: 2.2, height: 2.2))
            body.windingRule = .evenOdd
            body.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    func updateAppearance() {
        switch Preferences.shared.theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self
        menu.addItem(item)
    }
    private func buildMainMenu() {
        let bar = NSMenu(title: "Margherita"), app = NSMenu(title: "Margherita")
        let root = NSMenuItem(); root.submenu = app; bar.addItem(root)
        addItem("About Margherita", #selector(openAbout), to: app)
        addItem("Settings…", #selector(openSettings), to: app, key: ",")
        addItem("Check for Updates…", #selector(checkForUpdates), to: app)
        addItem("Getting Started…", #selector(openGettingStarted), to: app)
        addItem("Support Margherita", #selector(openSupport), to: app)
        app.addItem(.separator()); addItem("Quit Margherita", #selector(quit), to: app, key: "q")
        let editRoot = NSMenuItem(); let edit = NSMenu(title: "Edit"); editRoot.submenu = edit
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        bar.addItem(editRoot)
        NSApp.mainMenu = bar
    }
}
