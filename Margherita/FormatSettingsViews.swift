import SwiftUI

// MARK: - Format catalogue for the Formats tab (v10)

enum FormatDirection: Sendable { case both, inputOnly, outputOnly }

struct FormatEntry: Identifiable, Sendable {
    let name: String
    let group: String
    let aliases: [String]
    let direction: FormatDirection
    var id: String { name }
}

struct FormatSettingsGroup: Identifiable, Sendable {
    let name: String
    let entries: [FormatEntry]
    var id: String { name }
    var formats: [String] { entries.map { $0.name } }
}

extension FormatCatalog {
    private static func entry(_ group: String, _ name: String, _ aliases: [String] = [], _ direction: FormatDirection = .both) -> FormatEntry {
        FormatEntry(name: name, group: group, aliases: aliases, direction: direction)
    }

    /// Every format Margherita can read or write, grouped like Tangerine. GIF sits under Video, not Images.
    static let settingsGroups: [FormatSettingsGroup] = [
        FormatSettingsGroup(name: "Images", entries: [
            entry("Images", "JPG", ["jpeg", "jpe"]), entry("Images", "PNG"), entry("Images", "WEBP"),
            entry("Images", "HEIC", ["heif"]), entry("Images", "TIFF", ["tif"]), entry("Images", "AVIF"),
            entry("Images", "BMP"), entry("Images", "SVG", [], .inputOnly)
        ]),
        FormatSettingsGroup(name: "Documents", entries: [
            entry("Documents", "PDF"), entry("Documents", "DOCX", ["word"]), entry("Documents", "DOC"),
            entry("Documents", "PAGES"), entry("Documents", "TXT", ["text", "plain text"]),
            entry("Documents", "MD", ["markdown"]), entry("Documents", "RTF"), entry("Documents", "RTFD"),
            entry("Documents", "HTML", ["htm"]), entry("Documents", "EPUB", ["ebook"]), entry("Documents", "ODT"),
            entry("Documents", "WEBARCHIVE"), entry("Documents", "CLIPPING", ["textclipping", "text clipping"])
        ]),
        FormatSettingsGroup(name: "Presentations", entries: [
            entry("Presentations", "KEY", ["keynote"], .inputOnly), entry("Presentations", "PPTX", ["powerpoint", "slides"]), entry("Presentations", "PPT", ["powerpoint"], .inputOnly)
        ]),
        FormatSettingsGroup(name: "Spreadsheets", entries: [
            entry("Spreadsheets", "NUMBERS", [], .inputOnly), entry("Spreadsheets", "CSV"), entry("Spreadsheets", "TSV"), entry("Spreadsheets", "XLSX", ["excel"]),
            entry("Spreadsheets", "XLS", ["excel"]), entry("Spreadsheets", "ODS")
        ]),
        FormatSettingsGroup(name: "Audio", entries: [
            entry("Audio", "MP3"), entry("Audio", "M4A", ["aac"]), entry("Audio", "WAV"), entry("Audio", "FLAC"),
            entry("Audio", "OGG", ["vorbis"]), entry("Audio", "OPUS"), entry("Audio", "AIFF", ["aif"]),
            entry("Audio", "CAF"), entry("Audio", "WMA")
        ]),
        FormatSettingsGroup(name: "Video", entries: [
            entry("Video", "MP4"), entry("Video", "MOV"), entry("Video", "M4V"), entry("Video", "MKV"),
            entry("Video", "WEBM"), entry("Video", "AVI"), entry("Video", "WMV"), entry("Video", "GIF", ["animated"])
        ]),
        FormatSettingsGroup(name: "Archives", entries: [
            entry("Archives", "ZIP"), entry("Archives", "TAR"), entry("Archives", "GZIP", ["gz"]),
            entry("Archives", "TGZ", ["tar.gz", "targz"], .inputOnly), entry("Archives", "BZ2", ["bzip2"], .inputOnly),
            entry("Archives", "XZ", [], .inputOnly), entry("Archives", "7Z", ["7zip", "sevenzip"], .inputOnly),
            entry("Archives", "RAR", [], .inputOnly)
        ]),
        FormatSettingsGroup(name: "Subtitles", entries: [entry("Subtitles", "SRT"), entry("Subtitles", "VTT")])
    ]

    static var allFormats: [String] {
        var seen = Set<String>()
        return (groups.flatMap { $0.formats } + settingsGroups.flatMap { $0.formats }).filter { seen.insert($0).inserted }
    }
    static func settingsEntry(_ name: String) -> FormatEntry? {
        settingsGroups.flatMap { $0.entries }.first { $0.name == name }
    }
    static func settingsGroupName(of format: String) -> String { settingsEntry(format)?.group ?? "" }

    /// Search by name, group or alias.
    static func matches(_ entry: FormatEntry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        return entry.name.lowercased().contains(q) || entry.group.lowercased().contains(q)
            || entry.aliases.contains { $0.lowercased().contains(q) }
    }
}

// MARK: - Formats tab

struct FormatsTab: View {
    @ObservedObject private var ui = MargheritaUIState.shared
    var body: some View {
        HStack(spacing: 0) {
            FormatSidebar().frame(width: 190)
            Divider()
            FormatSettingsDetail(format: ui.selectedFormat).id(ui.selectedFormat)
        }
    }
}

struct FormatSidebar: View {
    @ObservedObject private var ui = MargheritaUIState.shared
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search", text: $ui.formatQuery).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10).padding(.top, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(FormatCatalog.settingsGroups) { group in groupView(group) }
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
    }
    private func groupView(_ group: FormatSettingsGroup) -> some View {
        let items = group.entries.filter { FormatCatalog.matches($0, query: ui.formatQuery) }
        return Group {
            if !items.isEmpty {
                Text(group.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.top, 8).padding(.leading, 6)
                ForEach(items) { item in row(item.name) }
            }
        }
    }
    private func row(_ item: String) -> some View {
        let selected = ui.selectedFormat == item
        return Button { ui.selectedFormat = item } label: {
            Text(item).font(.system(size: 13)).foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Detail

struct FormatSettingsDetail: View {
    let format: String
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var capabilities = FormatCapabilities.shared
    @ObservedObject private var store = FormatSettingsStore.shared

    private var key: String { FormatSettingsStore.canonical(format) }
    private var group: String { FormatCatalog.settingsGroupName(of: format) }
    private var entry: FormatEntry? { FormatCatalog.settingsEntry(format) }
    private var profile: FormatProfile { store.profile(for: key) }
    private var ffmpeg: Bool { capabilities.mediaAvailable }

    private func bind<T>(_ path: WritableKeyPath<FormatProfile, T>) -> Binding<T> {
        Binding(get: { store.profile(for: key)[keyPath: path] },
                set: { value in var p = store.profile(for: key); p[keyPath: path] = value; store.set(p, for: key) })
    }

    private var summary: String {
        let outs = FormatCatalog.outputs(of: format)
        let direction: String
        switch entry?.direction ?? .both {
        case .inputOnly: direction = "Input only."
        case .outputOnly: direction = "Output only."
        case .both: direction = "Input and output format."
        }
        if capabilities.isLoading && (entry?.direction ?? .both) != .outputOnly { return direction + " Checking available routes\u{2026}" }
        if (entry?.direction ?? .both) == .outputOnly { return direction + " Other formats convert to " + format + "." }
        return direction + " Converts to " + FormatCatalog.sentence(outs) + "."
    }

    private var profileLine: String {
        let canon = key == format ? "" : " (shared with " + key + ")"
        if entry?.direction == .inputOnly {
            return "This page is the settings profile for " + format + " as a source file" + canon + ". It applies when " + format + " files go through tools such as Compress."
        }
        return "These settings apply when exporting to " + format + canon + ". Compress Tool Settings below apply when a " + format + " file is the source."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(format + " Settings").font(.system(size: 22, weight: .bold))
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !readOnlyArchive { note(profileLine) }
                }
                if readOnlyArchive {
                    note(format + " archives are read-only in Margherita. You can extract them, but not create them, so there are no conversion or compression settings.")
                } else {
                    conversionBlock
                }
                if hasCompression && !readOnlyArchive { Divider(); compressionBlock }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: helpers
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 14, weight: .semibold)) }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func restore(_ title: String, _ action: @escaping () -> Void) -> some View {
        HStack { Spacer(); Button(title, action: action).foregroundStyle(prefs.color) }
    }
    private var ffmpegNote: some View {
        Group { if !ffmpeg { note("Needs FFmpeg. Install it to change the dimmed options. Without it Margherita uses the native Apple encoders with their defaults.") } }
    }

    private var hasCompression: Bool {
        switch group {
        case "Images", "Audio", "Video": return true
        case "Archives": return ["ZIP", "GZIP"].contains(key)
        case "Documents": return key == "PDF"
        default: return false
        }
    }
    private var isGIF: Bool { key == "GIF" }

    // MARK: conversion
    @ViewBuilder private var conversionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Conversion Settings")
            if isGIF { gifRows }
            else {
                switch group {
                case "Images": imageRows
                case "Audio": audioRows
                case "Video": videoRows
                case "Archives": archiveRows
                case "Documents": documentRows
                default: note("No extra options for this format. It follows your output settings in Folders.")
                }
            }
            restore("Restore Defaults") { store.resetConversion(for: key) }
        }
    }

    private var qualityLevel: Binding<String> {
        Binding(get: { let v = profile.imageQuality; return v < 0.7 ? "small" : (v < 0.9 ? "balanced" : "high") },
                set: { value in var p = profile; p.imageQuality = ["small": 0.6, "balanced": 0.82, "high": 0.95][value] ?? 0.82; store.set(p, for: key) })
    }
    private var imageRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            let lossy = !["PNG", "BMP", "TIFF"].contains(key)
            LabeledContent("Quality") {
                Picker("", selection: qualityLevel) {
                    Text("Small").tag("small"); Text("Balanced").tag("balanced"); Text("High").tag("high")
                }.labelsHidden().frame(width: 150).disabled(!lossy)
            }
            if !lossy { note(key + " is lossless, so quality does not change the result.") }
            LabeledContent("Colour") {
                Picker("", selection: bind(\.colorMode)) {
                    Text("Original").tag("original"); Text("sRGB").tag("srgb"); Text("Grayscale").tag("grayscale")
                }.labelsHidden().frame(width: 150)
            }
            Toggle("Preserve metadata", isOn: Binding(get: { !profile.stripMetadata }, set: { value in var p = profile; p.stripMetadata = !value; store.set(p, for: key) }))
            note("Colour mode is saved per format, but not every conversion path applies it yet, so a result can stay in its original colour.")
            ocrRow
        }
    }
    private var ocrRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("OCR language") {
                Picker("", selection: bind(\.ocrLanguage)) {
                    Text("Automatic").tag("auto"); Text("English").tag("en-US"); Text("Chinese (Simplified)").tag("zh-Hans")
                    Text("German").tag("de-DE"); Text("French").tag("fr-FR"); Text("Spanish").tag("es-ES")
                }.labelsHidden().frame(width: 190)
            }
            note("Only used when you run OCR Text or Searchable PDF. Normal conversions never read it.")
        }
    }
    private var gifRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Frame rate") {
                Picker("", selection: bind(\.gifFPS)) {
                    ForEach([5, 10, 12, 15, 20, 24, 30], id: \.self) { Text(String($0) + " fps").tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            LabeledContent("Maximum width") {
                Picker("", selection: bind(\.gifWidth)) {
                    ForEach([240, 320, 480, 640, 960, 1280, 1920], id: \.self) { Text(String($0) + " px").tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            Toggle("Loop forever", isOn: bind(\.gifLoop))
            Toggle("Dithering", isOn: bind(\.gifDither)).disabled(!ffmpeg)
            note("GIFs are never enlarged. Width and frame rate also apply to the built-in encoder.")
            if !ffmpeg { note("Dithering needs FFmpeg. The built-in ImageIO GIF encoder does not dither.") }
        }
    }
    private var videoRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if codecOverridable {
            LabeledContent("Codec") {
                Picker("", selection: bind(\.videoCodec)) {
                    Text("Automatic").tag("auto"); Text("H.264").tag("h264"); Text("HEVC").tag("hevc")
                }.labelsHidden().frame(width: 150).disabled(!ffmpeg)
            }
            }
            LabeledContent("Quality") {
                Picker("", selection: bind(\.videoQuality)) {
                    Text("Smallest").tag("small"); Text("Balanced").tag("balanced"); Text("Best").tag("high")
                }.labelsHidden().frame(width: 150)
            }
            LabeledContent("Maximum video height") {
                Picker("", selection: bind(\.videoHeight)) {
                    Text("Original").tag(0); Text("2160p").tag(2160); Text("1080p").tag(1080)
                    Text("720p").tag(720); Text("480p").tag(480)
                }.labelsHidden().frame(width: 150).disabled(!ffmpeg)
            }
            LabeledContent("Frame rate") {
                Picker("", selection: bind(\.videoFPS)) {
                    Text("Original").tag(0)
                    ForEach([24, 30, 60], id: \.self) { Text(String($0) + " fps").tag($0) }
                }.labelsHidden().frame(width: 150).disabled(!ffmpeg)
            }
            ffmpegNote
        }
    }
    /// Engine rejects codec overrides for every container except MP4 and MOV (M4V included).
    private var codecOverridable: Bool { ["MP4", "MOV"].contains(format) }
    private var lossyAudio: Bool { ["MP3", "M4A", "OGG", "OPUS", "WMA"].contains(format) }
    private var readOnlyArchive: Bool { group == "Archives" && entry?.direction == .inputOnly }
    private var audioRows: some View {
        return VStack(alignment: .leading, spacing: 10) {
            if lossyAudio {
                LabeledContent("Audio bitrate") {
                    Picker("", selection: bind(\.audioBitrate)) {
                        ForEach([128, 192, 256, 320], id: \.self) { Text(String($0) + " kbps").tag($0) }
                    }.labelsHidden().frame(width: 150)
                }
            } else {
                note(format + " is uncompressed or lossless, so there is no bitrate setting.")
            }
            LabeledContent("Sample rate") {
                Picker("", selection: bind(\.audioSampleRate)) {
                    Text("Original").tag(0); Text("44.1 kHz").tag(44100); Text("48 kHz").tag(48000)
                }.labelsHidden().frame(width: 150).disabled(!ffmpeg)
            }
            LabeledContent("Channels") {
                Picker("", selection: bind(\.audioChannels)) {
                    Text("Original").tag(0); Text("Mono").tag(1); Text("Stereo").tag(2)
                }.labelsHidden().frame(width: 150).disabled(!ffmpeg)
            }
            if format == "OGG" { note("Vorbis targets up to 192 kbps to preserve compatibility with mono sources.") }
            ffmpegNote
        }
    }
    private var archiveRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            let inputOnly = entry?.direction == .inputOnly
            if inputOnly { note(key + " archives can be opened, but Margherita cannot create them.") }
            else if key == "TAR" { note("TAR is uncompressed. It bundles files without shrinking them.") }
            else if format == "TGZ" { note("TGZ is a tar.gz input alias. Choose GZIP to package multiple files as tar.gz; its compression settings apply here too.") }
            else { note("Compression for " + key + " is under Compression Settings.") }
        }
    }
    private var layoutCopy: String {
        switch profile.documentLayout {
        case "editable": return "Creates native paragraphs that reflow when edited. Headings and tables are not guaranteed to be rebuilt."
        case "fixed": return "Places each page as a fixed page image. Looks like the original, but text is not editable."
        default: return "Uses Word, LibreOffice or pdf2docx when installed, then falls back to built-in conversion. Best effort, so results can vary."
        }
    }
    @ViewBuilder private var documentRows: some View {
        if key == "PDF" || key == "DOCX" {
            VStack(alignment: .leading, spacing: 8) {
                if key == "PDF" {
                    LabeledContent("PDF layout") {
                        Picker("", selection: bind(\.documentLayout)) {
                            Text("Best available app").tag("auto"); Text("Editable paragraphs").tag("editable"); Text("Match page layout").tag("fixed")
                        }.labelsHidden().frame(width: 190)
                    }
                    note(layoutCopy)
                    LabeledContent("Image quality") {
                        Picker("", selection: bind(\.pdfImageQuality)) {
                            Text("Small").tag(0.6); Text("Balanced").tag(0.82); Text("High").tag(0.95)
                        }.labelsHidden().frame(width: 150)
                    }
                    note("Only used by the built-in image compression when a PDF is exported or compressed. App-based and text conversions ignore it.")
                    ocrRow
                } else {
                    note("DOCX output follows the PDF layout choice in the PDF settings.")
                }
            }
        } else {
            note("No extra options for this format. It follows your output settings in Folders.")
        }
    }

    // MARK: compression
    private var compressionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(group == "Archives" ? "Archive Compression" : "Compress Tool Settings")
            if group == "Archives" {
                note("Used when creating " + format + " archives.")
            } else {
                note("Used only by the Compress tool on " + format + " files. Normal conversions to " + format + " are not compressed by these settings.")
            }
            if group != "Archives" {
            LabeledContent("Compression") {
                Picker("", selection: bind(\.compressionMode)) {
                    Text("Balanced").tag("balanced"); Text("Strong").tag("strong")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            }
            if group == "Images" {
                LabeledContent("Image size") {
                    Picker("", selection: bind(\.maxDimension)) {
                        Text("Keep original dimensions").tag(0)
                        Text("Up to 3840 px").tag(3840); Text("Up to 1920 px").tag(1920)
                        Text("Up to 1280 px").tag(1280); Text("Up to 800 px").tag(800)
                    }.labelsHidden().frame(width: 210)
                }
            }
            if group == "Archives" {
                LabeledContent("Archive level") {
                    Picker("", selection: bind(\.archiveCompression)) {
                        Text("Fast").tag("fast"); Text("Balanced").tag("balanced"); Text("Smallest").tag("small")
                    }.labelsHidden().frame(width: 150)
                }
            }
            if group != "Archives" { note(profile.compressionMode == "balanced"
                 ? "Better visual quality with moderate file-size savings."
                 : "Smaller files with more visible quality loss.") }
            restore("Restore Compress Tool Defaults") { store.resetCompression(for: key) }
        }
    }
}
