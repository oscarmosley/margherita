import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    @Published var wheelStyle: String { didSet { save(wheelStyle, "wheelStyle") } }
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }
    @Published var floatBehaviour: String { didSet { save(floatBehaviour, "floatBehaviour") } }
    @Published var dock: Bool { didSet { save(dock, "dock"); visibilityChanged?() } }
    @Published var menuBar: Bool { didSet { save(menuBar, "menuBar"); visibilityChanged?() } }
    /// Serialised KeyboardShortcut that starts a convert drag (default "shift").
    @Published var trigger: String { didSet { save(trigger, "trigger") } }
    /// Serialised KeyboardShortcut that opens the file-tools wheel (default "shift+option").
    @Published var toolsTrigger: String { didSet { save(toolsTrigger, "toolsTrigger") } }
    /// Serialised KeyboardShortcut for the global open hotkey (default command+option+P).
    @Published var actionsTrigger: String { didSet { save(actionsTrigger, "actionsTrigger") } }
    @Published var terminalApp: String { didSet { save(terminalApp, "terminalApp") } }
    @Published var hotkey: String { didSet { save(hotkey, "hotkey"); syncHotkey() } }
    @Published var hotkeyEnabled: Bool { didSet { save(hotkeyEnabled, "hotkeyEnabled"); syncHotkey() } }
    @Published var location: String { didSet { save(location, "location") } }
    @Published var folder: String { didSet { save(folder, "folder") } }
    @Published var suffix: String { didSet { save(suffix, "suffix") } }
    @Published var collision: String { didSet { save(collision, "collision") } }
    @Published var imageQuality: Double { didSet { save(imageQuality, "imageQuality") } }
    @Published var audioQuality: Double { didSet { save(audioQuality, "audioQuality") } }
    @Published var videoQuality: String { didSet { save(videoQuality, "videoQuality") } }
    @Published var maxDimension: Int { didSet { save(maxDimension, "maxDimension") } }
    @Published var stripMetadata: Bool { didSet { save(stripMetadata, "stripMetadata") } }
    @Published var accent: String { didSet { save(accent, "accent"); appearanceChanged?() } }
    @Published var theme: String { didSet { save(theme, "theme"); appearanceChanged?() } }
    @Published var overlaySize: Double { didSet { save(overlaySize, "overlaySize") } }
    @Published var overlayPosition: String { didSet { save(overlayPosition, "overlayPosition") } }
    @Published var sounds: Bool { didSet { save(sounds, "sounds") } }
    @Published var notifications: Bool { didSet { save(notifications, "notifications") } }
    @Published var reveal: Bool { didSet { save(reveal, "reveal") } }
    @Published var loginError = ""
    @Published var loginEnabled = false
    var visibilityChanged: (() -> Void)?
    var appearanceChanged: (() -> Void)?
    private init() {
        defaults.register(defaults: [
            "wheelStyle": "glass", "haptics": true, "floatBehaviour": "new", "dock": true, "menuBar": true, "trigger": "shift", "toolsTrigger": "shift+option", "hotkey": "command+option+#35", "hotkeyEnabled": true, "actionsTrigger": "control", "terminalApp": "terminal", "location": "beside",
            "folder": "", "suffix": "-{action}", "collision": "unique", "imageQuality": 0.82,
            "audioQuality": 0.8, "videoQuality": "balanced", "maxDimension": 0,
            "stripMetadata": true, "accent": "tomato", "theme": "system",
            "overlaySize": 380.0, "overlayPosition": "center", "sounds": false,
            "notifications": false, "reveal": false
        ])
        // One-time migration: the old default suffix becomes the {action} template.
        if !defaults.bool(forKey: "suffixMigratedV2") {
            if ["-papaya", "-margherita"].contains(defaults.string(forKey: "suffix") ?? "") { defaults.set("-{action}", forKey: "suffix") }
            defaults.set(true, forKey: "suffixMigratedV2")
        }
        // Replace only the previous default; explicit user colors remain untouched.
        if !defaults.bool(forKey: "margheritaPaletteV7") {
            if defaults.string(forKey: "accent") == "coral" { defaults.set("tomato", forKey: "accent") }
            defaults.set(true, forKey: "margheritaPaletteV7")
        }
        // Earlier builds silently used 1920 as the default conversion cap.
        // Reset that legacy value once; other explicit size choices survive.
        if !defaults.bool(forKey: "originalImageSizeV9") {
            if defaults.integer(forKey: "maxDimension") == 1920 { defaults.set(0, forKey: "maxDimension") }
            defaults.set(true, forKey: "originalImageSizeV9")
        }
        wheelStyle = defaults.string(forKey: "wheelStyle") ?? "glass"
        haptics = defaults.bool(forKey: "haptics")
        floatBehaviour = defaults.string(forKey: "floatBehaviour") ?? "new"
        dock = defaults.bool(forKey: "dock"); menuBar = defaults.bool(forKey: "menuBar")
        trigger = defaults.string(forKey: "trigger") ?? "shift"
        toolsTrigger = defaults.string(forKey: "toolsTrigger") ?? "shift+option"
        actionsTrigger = defaults.string(forKey: "actionsTrigger") ?? "control"
        terminalApp = defaults.string(forKey: "terminalApp") ?? "terminal"
        hotkey = defaults.string(forKey: "hotkey") ?? "command+option+#35"; hotkeyEnabled = defaults.bool(forKey: "hotkeyEnabled")
        location = defaults.string(forKey: "location") ?? "beside"; folder = defaults.string(forKey: "folder") ?? ""
        suffix = defaults.string(forKey: "suffix") ?? "-{action}"; collision = defaults.string(forKey: "collision") ?? "unique"
        imageQuality = defaults.double(forKey: "imageQuality")
        audioQuality = defaults.double(forKey: "audioQuality")
        videoQuality = defaults.string(forKey: "videoQuality") ?? "balanced"
        maxDimension = defaults.integer(forKey: "maxDimension")
        stripMetadata = defaults.bool(forKey: "stripMetadata")
        accent = defaults.string(forKey: "accent") ?? "tomato"; theme = defaults.string(forKey: "theme") ?? "system"
        overlaySize = defaults.double(forKey: "overlaySize")
        overlayPosition = defaults.string(forKey: "overlayPosition") ?? "center"
        sounds = defaults.bool(forKey: "sounds"); notifications = defaults.bool(forKey: "notifications")
        reveal = defaults.bool(forKey: "reveal")
        loginEnabled = SMAppService.mainApp.status == .enabled
        syncHotkey()
    }
    func syncHotkey() { HotkeyManager.shared.configure(shortcut: hotkeyShortcut, enabled: hotkeyEnabled) }
    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
    // MARK: shortcuts
    /// Shortcut that starts a normal convert drag.
    var triggerShortcut: KeyboardShortcut {
        get { KeyboardShortcut(serialized: trigger) ?? KeyboardShortcut(modifiers: .shift) }
        set { trigger = newValue.serialized }
    }
    /// Shortcut that opens the file tools wheel.
    var toolsShortcut: KeyboardShortcut {
        get { KeyboardShortcut(serialized: toolsTrigger) ?? KeyboardShortcut(modifiers: [.shift, .option]) }
        set { toolsTrigger = newValue.serialized }
    }
    var hotkeyShortcut: KeyboardShortcut {
        get { KeyboardShortcut(serialized: hotkey) ?? KeyboardShortcut(modifiers: [.command, .option], keyCode: 35) }
        set { hotkey = newValue.serialized }
    }
    var actionsShortcut: KeyboardShortcut {
        get { KeyboardShortcut(serialized: actionsTrigger) ?? KeyboardShortcut(modifiers: .control) }
        set { actionsTrigger = newValue.serialized }
    }
    enum DragMode { case convert, tools, actions }
    /// Which wheel the held modifiers/keys ask for (exact matching, so shift vs shift+option never collide
    /// unless the user records identical shortcuts; tools wins then).
    func dragMode(modifiers: NSEvent.ModifierFlags, pressedKeys: Set<UInt16>) -> DragMode? {
        if actionsShortcut.matches(modifiers: modifiers, pressedKeys: pressedKeys) { return .actions }
        if toolsShortcut.matches(modifiers: modifiers, pressedKeys: pressedKeys) { return .tools }
        if triggerShortcut.matches(modifiers: modifiers, pressedKeys: pressedKeys) { return .convert }
        return nil
    }
    var triggerLabel: String { triggerShortcut.display }
    var toolsLabel: String { toolsShortcut.display }
    var hotkeyLabel: String { hotkeyShortcut.display }
    /// Kept for older call sites: modifier part of the convert trigger.
    var triggerFlag: NSEvent.ModifierFlags {
        let m = triggerShortcut.modifiers
        return m.isEmpty ? .shift : m
    }
    // MARK: suffix
    /// Replaces {action} in the suffix template, strips path separators.
    static func expandSuffix(_ template: String, action: String) -> String {
        let slug = action.lowercased().filter { $0.isLetter || $0.isNumber }
        return template.replacingOccurrences(of: "{action}", with: slug).replacingOccurrences(of: "/", with: "-")
    }
    func resolvedSuffix(action: String) -> String { Preferences.expandSuffix(suffix, action: action) }
    func suffixPreview(name: String, action: String, ext: String) -> String {
        name + resolvedSuffix(action: action) + "." + ext
    }
    // MARK: accent
    static let swatches: [(name: String, hex: String)] = [
        ("Tomato", "#D6332E"), ("Basil", "#456E4D"), ("Mozzarella", "#F7EDD6"), ("Ember", "#A44632"),
        ("Teal", "#1F9CA6"), ("Sky", "#3B82F6"), ("Grape", "#8B5CF6"), ("Rose", "#EC4899"), ("Graphite", "#5B6270")
    ]
    static func parseHex(_ text: String) -> NSColor? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { String([$0, $0]) }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static func hex(of color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(calibratedRed: 0.84, green: 0.20, blue: 0.18, alpha: 1)
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    var accentHex: String { Preferences.hex(of: accentNS) }
    var accentNS: NSColor {
        if let custom = Preferences.parseHex(accent), accent.hasPrefix("#") { return custom }
        switch accent {
        case "orange": return NSColor(calibratedRed: 1, green: 0.53, blue: 0.13, alpha: 1)
        case "green", "basil": return NSColor(calibratedRed: 0.27, green: 0.43, blue: 0.30, alpha: 1)
        default: return NSColor(calibratedRed: 0.84, green: 0.20, blue: 0.18, alpha: 1)
        }
    }
    var color: Color { Color(nsColor: accentNS) }
    var options: ConversionOptions {
        let extras = FormatExtras.shared
        var options = ConversionOptions(imageQuality: imageQuality, videoQuality: videoQuality,
                                        audioQuality: audioQuality, maxDimension: maxDimension,
                                        stripMetadata: stripMetadata, suffix: suffix,
                                        collision: collision, destination: nil)
        options.formatProfiles = Dictionary(uniqueKeysWithValues: Set(FormatCatalog.allFormats.map { FormatSettingsStore.canonical($0) }).map {
            ($0, FormatSettingsStore.shared.profile(for: $0))
        })
        options.compressionMode = extras.compressionMode
        options.documentLayout = extras.documentLayout
        options.videoHeight = ExtendedMedia.available ? extras.videoHeight : 0
        options.archiveCompression = extras.archiveCompression
        return options
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Margherita in System Settings > General > Login Items." : ""
        } catch { loginError = error.localizedDescription }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url { FolderAccess.shared.remember(url); folder = url.path; location = "folder" }
    }
}
