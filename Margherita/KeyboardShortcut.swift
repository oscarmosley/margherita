import AppKit
import SwiftUI

/// A modifier-only or modifier+key combination. Serialised as e.g. "shift", "shift+option",
/// "command+option+#35" (#N is a virtual key code). Legacy values "shift"/"control"/"command" still parse.
struct KeyboardShortcut: Equatable {
    static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    var modifiers: NSEvent.ModifierFlags
    var keyCode: UInt16?

    init(modifiers: NSEvent.ModifierFlags, keyCode: UInt16? = nil) {
        self.modifiers = modifiers.intersection(KeyboardShortcut.relevantModifiers)
        self.keyCode = keyCode
    }
    init?(serialized: String) {
        var mods: NSEvent.ModifierFlags = []
        var key: UInt16?
        let parts = serialized.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        for part in parts {
            switch part {
            case "shift": mods.insert(.shift)
            case "control", "ctrl": mods.insert(.control)
            case "option", "alt": mods.insert(.option)
            case "command", "cmd": mods.insert(.command)
            default:
                if part.hasPrefix("#"), let code = UInt16(part.dropFirst()) { key = code } else { return nil }
            }
        }
        if mods.isEmpty && key == nil { return nil }
        self.init(modifiers: mods, keyCode: key)
    }
    var serialized: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        if let keyCode { parts.append("#" + String(keyCode)) }
        return parts.joined(separator: "+")
    }
    /// Mac-style glyphs, e.g. "⌥⇧" or "⌘⌥P".
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let keyCode { text += KeyboardShortcut.keyName(keyCode) }
        return text.isEmpty ? "None" : text
    }
    /// Words, e.g. "Shift + Option". Used in help text.
    var words: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        if let keyCode { parts.append(KeyboardShortcut.keyName(keyCode)) }
        return parts.isEmpty ? "None" : parts.joined(separator: " + ")
    }
    /// EXACT match: held modifiers (caps lock, function, etc. stripped) must equal this shortcut's modifiers,
    /// and if keyCode is set it must be in pressedKeys. Modifier-only shortcuts ignore pressedKeys.
    func matches(modifiers flags: NSEvent.ModifierFlags, pressedKeys: Set<UInt16> = []) -> Bool {
        guard flags.intersection(KeyboardShortcut.relevantModifiers) == modifiers else { return false }
        if let keyCode { return pressedKeys.contains(keyCode) }
        return true
    }
    /// pressedKeys is required (no main-actor default); pass HeldKeyTracker.shared.keys if you want it.
    func matches(event: NSEvent, pressedKeys: Set<UInt16>) -> Bool {
        var keys = pressedKeys
        if event.type == .keyDown { keys.insert(event.keyCode) }
        if event.type == .keyUp { keys.remove(event.keyCode) }
        return matches(modifiers: event.modifierFlags, pressedKeys: keys)
    }
    /// Exact match used for the global open hotkey (no extra modifiers).
    func exactlyMatches(keyDown event: NSEvent) -> Bool {
        guard let keyCode, event.type == .keyDown, !event.isARepeat else { return false }
        return event.keyCode == keyCode && event.modifierFlags.intersection(KeyboardShortcut.relevantModifiers) == modifiers
    }
    /// Number of inputs; a larger shortcut is more specific when two both match.
    var weight: Int {
        var n = keyCode == nil ? 0 : 1
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where modifiers.contains(flag) { n += 1 }
        return n
    }
    static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
            35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
            47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 36: "Return", 76: "Enter",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
            109: "F10", 111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 116: "Page Up", 117: "Fwd Delete", 119: "End", 121: "Page Down", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        return names[code] ?? "Key " + String(code)
    }
}

/// Tracks which non-modifier keys are physically held. Thread-safe and synchronous (monitor callbacks run
/// on the main thread), so there is no async race. Global events need Input Monitoring permission.
final class HeldKeyTracker: @unchecked Sendable {
    static let shared = HeldKeyTracker()
    private let lock = NSLock()
    private var held: Set<UInt16> = []
    private var monitors: [Any] = []
    private init() {}
    var keys: Set<UInt16> { lock.lock(); defer { lock.unlock() }; return held }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.track(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.track(e); return e }) {
            monitors.append(l)
        }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []; held = []
    }
    private func track(_ event: NSEvent) {
        let type = event.type, code = event.keyCode
        lock.lock(); defer { lock.unlock() }
        if type == .keyDown { held.insert(code) } else if type == .keyUp { held.remove(code) }
    }
}

/// Global (plus in-app) hotkey that opens Margherita. State is lock-protected so monitor callbacks never
/// touch main-actor objects synchronously; Preferences pushes changes through configure().
final class HotkeyManager: @unchecked Sendable {
    static let shared = HotkeyManager()
    private let lock = NSLock()
    private var shortcut: KeyboardShortcut?
    private var suspended = false
    private var monitors: [Any] = []
    private init() {}
    func configure(shortcut: KeyboardShortcut, enabled: Bool) {
        lock.lock(); self.shortcut = enabled ? shortcut : nil; lock.unlock()
    }
    /// Pause while a shortcut is being recorded.
    func setSuspended(_ value: Bool) { lock.lock(); suspended = value; lock.unlock() }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in _ = self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            (self?.handle(e) ?? false) ? nil : e
        }) { monitors.append(l) }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
    }
    private func handle(_ event: NSEvent) -> Bool {
        lock.lock(); let current = shortcut, paused = suspended; lock.unlock()
        guard !paused, let current, current.exactlyMatches(keyDown: event) else { return false }
        DispatchQueue.main.async { Task { @MainActor in AppDelegate.shared?.openSettings() } }
        return true
    }
}

/// Plain values copied out of an NSEvent so they can cross to the main actor safely.
private struct RecordedEvent: Sendable {
    var type: NSEvent.EventType
    var keyCode: UInt16
    var flags: NSEvent.ModifierFlags
    var isRepeat: Bool
}

/// Records a shortcut: modifier-only or any combination (including F-keys). The shortcut is committed
/// once everything is released. Escape cancels.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var recording = false
    @Published var live = ""
    private var monitor: Any?
    private var mods: NSEvent.ModifierFlags = []
    private var key: UInt16?
    private var down: Set<UInt16> = []
    private var allowModifierOnly = true
    private var commit: ((KeyboardShortcut) -> Void)?

    func toggle(allowModifierOnly: Bool, commit: @escaping (KeyboardShortcut) -> Void) {
        if recording { stop() } else { start(allowModifierOnly: allowModifierOnly, commit: commit) }
    }
    func start(allowModifierOnly: Bool, commit: @escaping (KeyboardShortcut) -> Void) {
        stop()
        self.allowModifierOnly = allowModifierOnly; self.commit = commit
        reset(); recording = true; HotkeyManager.shared.setSuspended(true)
        // Swallow every key while recording; deliver copies to the main actor in order.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let copy = RecordedEvent(type: event.type, keyCode: event.keyCode,
                                     flags: event.modifierFlags.intersection(KeyboardShortcut.relevantModifiers),
                                     isRepeat: event.type == .keyDown ? event.isARepeat : false)
            DispatchQueue.main.async { Task { @MainActor in self?.handle(copy) } }
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false; live = ""; reset()
        HotkeyManager.shared.setSuspended(false)
    }
    private func reset() { mods = []; key = nil; down = [] }
    private func handle(_ event: RecordedEvent) {
        guard recording else { return }
        let flags = event.flags
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { stop(); return }
            if event.isRepeat { return }
            key = event.keyCode; down.insert(event.keyCode); mods.formUnion(flags)
        case .keyUp:
            down.remove(event.keyCode)
        default:
            mods.formUnion(flags)
        }
        live = KeyboardShortcut(modifiers: mods, keyCode: key).display
        if event.type != .keyDown && flags.isEmpty && down.isEmpty {
            if key == nil && (mods.isEmpty || !allowModifierOnly) { reset(); live = ""; return }
            let result = KeyboardShortcut(modifiers: mods, keyCode: key)
            let done = commit
            stop(); done?(result)
        }
    }
}
