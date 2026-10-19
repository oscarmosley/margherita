import AppKit

enum SoundEffect: String, CaseIterable { case hover, drop, success, error }

@MainActor
enum SoundEffects {
    private static var cache: [SoundEffect: NSSound] = [:]
    private static var lastHover = Date.distantPast
    /// Plays a bundled, synthesised effect when "sounds" is on in Settings.
    static func play(_ effect: SoundEffect, force: Bool = false) {
        let prefs = Preferences.shared
        guard force || prefs.sounds || prefs.haptics else { return }
        if effect == .hover {
            guard Date().timeIntervalSince(lastHover) > 0.08 else { return }
            lastHover = Date()
        }
        if prefs.haptics && effect != .error {
            NSHapticFeedbackManager.defaultPerformer.perform(effect == .hover ? .alignment : .generic, performanceTime: .now)
        }
        guard force || prefs.sounds else { return }
        guard let sound = load(effect) else { return }
        sound.stop(); sound.volume = effect == .hover ? 0.35 : 0.7; sound.play()
    }
    private static func load(_ effect: SoundEffect) -> NSSound? {
        if let cached = cache[effect] { return cached }
        let name = effect.rawValue
        let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Resources")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
        guard let url, let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        cache[effect] = sound
        return sound
    }
}
