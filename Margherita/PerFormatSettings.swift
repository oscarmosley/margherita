import Foundation
import Combine

/// Persisted independently by output format. Inputs/tools use their source format.
struct FormatProfile: Codable, Sendable, Equatable {
    var compressionMode = "balanced"
    var imageQuality = 0.82
    var maxDimension = 0
    var stripMetadata = true
    var colorMode = "original"
    var gifFPS = 15
    var gifWidth = 480
    var gifLoop = true
    var gifDither = true
    var videoCodec = "auto"
    var videoQuality = "balanced"
    var videoHeight = 0
    var videoFPS = 0
    var audioBitrate = 256
    var audioSampleRate = 0
    var audioChannels = 0
    var pdfImageQuality = 0.82
    var ocrLanguage = "auto"
    var archiveCompression = "balanced"
    var documentLayout = "auto"
}

@MainActor
final class FormatSettingsStore: ObservableObject {
    static let shared = FormatSettingsStore()
    @Published private(set) var profiles: [String: FormatProfile] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "formatProfilesV10"),
           let saved = try? JSONDecoder().decode([String: FormatProfile].self, from: data) {
            profiles = saved
        }
    }
    nonisolated static func canonical(_ value: String) -> String {
        let name = value.uppercased()
        return ["JPEG":"JPG", "TIF":"TIFF", "HEIF":"HEIC", "AIF":"AIFF",
                "GZ":"GZIP", "TGZ":"GZIP", "CLIPPING":"TEXTCLIPPING",
                "7ZIP":"7Z", "M4V":"MP4"][name] ?? name
    }
    func profile(for format: String) -> FormatProfile {
        profiles[Self.canonical(format)] ?? FormatProfile()
    }
    func set(_ profile: FormatProfile, for format: String) {
        profiles[Self.canonical(format)] = profile
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "formatProfilesV10") }
    }
    func resetConversion(for format: String) {
        let previous = profile(for: format)
        var clean = FormatProfile()
        clean.compressionMode = previous.compressionMode
        clean.archiveCompression = previous.archiveCompression
        set(clean, for: format)
    }
    func resetCompression(for format: String) {
        var value = profile(for: format)
        value.compressionMode = "balanced"
        value.archiveCompression = "balanced"
        set(value, for: format)
    }
}

extension ConversionOptions {
    /// Pure resolution keeps settings snapshots immutable during an active batch.
    func resolved(for format: String) -> ConversionOptions {
        guard let profile = formatProfiles[FormatSettingsStore.canonical(format)] else { return self }
        var result = self
        result.formatProfile = profile
        result.imageQuality = FormatSettingsStore.canonical(format) == "PDF" ? profile.pdfImageQuality : profile.imageQuality
        result.maxDimension = profile.maxDimension
        result.stripMetadata = profile.stripMetadata
        result.colorMode = profile.colorMode
        result.compressionMode = profile.compressionMode
        result.gifFPS = profile.gifFPS
        result.gifWidth = profile.gifWidth
        result.gifLoop = profile.gifLoop
        result.gifDither = profile.gifDither
        result.videoCodec = profile.videoCodec
        result.videoQuality = profile.videoQuality
        result.videoHeight = profile.videoHeight
        result.videoFPS = profile.videoFPS
        result.audioBitrate = profile.audioBitrate
        result.audioQuality = max(0, min(1, Double(profile.audioBitrate - 64) / 256))
        result.audioSampleRate = profile.audioSampleRate
        result.audioChannels = profile.audioChannels
        result.ocrLanguage = profile.ocrLanguage
        result.archiveCompression = profile.archiveCompression
        result.documentLayout = profile.documentLayout
        return result
    }
}
