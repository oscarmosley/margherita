import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import UserNotifications

// MARK: - Format catalogue (drives the Formats and Compatibility tabs)

struct FormatGroup: Identifiable {
    let name: String
    let formats: [String]
    var id: String { name }
}

enum FormatCatalog {
    static let groups: [FormatGroup] = [
        FormatGroup(name: "Images", formats: ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "SVG", "AVIF", "BMP", "GIF"]),
        FormatGroup(name: "Documents", formats: ["PDF", "DOCX", "PAGES", "PPT", "PPTX", "TXT", "MD", "RTF", "RTFD", "HTML", "EPUB", "ODT", "DOC"]),
        FormatGroup(name: "Spreadsheets", formats: ["CSV", "TSV", "XLSX", "XLS", "ODS"]),
        FormatGroup(name: "Audio", formats: ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF", "WMA"]),
        FormatGroup(name: "Video", formats: ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV"]),
        FormatGroup(name: "Archives", formats: ["ZIP", "TAR", "GZIP", "RAR"]),
        FormatGroup(name: "Subtitles", formats: ["SRT", "VTT"])
    ]
    static func group(of format: String) -> String? { groups.first { $0.formats.contains(format) }?.name }

    static let imageInputs = ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "SVG", "AVIF", "BMP"]
    static let imageOutputs = ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF"]
    static let docInputs = ["PDF", "DOCX", "PAGES", "PPT", "PPTX", "TXT", "MD", "RTF", "RTFD"]
    static let docOutputs = ["PDF", "DOCX", "PAGES", "PPTX", "TXT", "MD", "HTML", "EPUB", "JPG", "PNG", "XLSX"]

    /// Pure lookup of the background launch snapshot, never a lazy UI probe.
    @MainActor static func outputs(of input: String) -> [String] {
        FormatCapabilities.shared.outputs(of: input)
    }
    static func rank(_ f: String) -> Int { groups.flatMap { $0.formats }.firstIndex(of: f) ?? 999 }
    static func sentence(_ list: [String]) -> String {
        switch list.count {
        case 0: return "nothing yet"
        case 1: return list[0]
        case 2: return list[0] + " and " + list[1]
        default: return list.dropLast().joined(separator: ", ") + ", and " + list.last!
        }
    }
}

// MARK: - Settings state

/// Per-format options that sit alongside Preferences. Stored in UserDefaults under their own keys.
@MainActor
final class FormatExtras: ObservableObject {
    static let shared = FormatExtras()
    private let defaults = UserDefaults.standard
    @Published var compressionMode: String { didSet { defaults.set(compressionMode, forKey: "fmtCompressionMode") } }
    @Published var documentLayout: String { didSet { defaults.set(documentLayout, forKey: "fmtDocumentLayout") } }
    @Published var videoHeight: Int { didSet { defaults.set(videoHeight, forKey: "fmtVideoHeight") } }
    @Published var archiveCompression: String { didSet { defaults.set(archiveCompression, forKey: "fmtArchiveCompression") } }
    private init() {
        compressionMode = defaults.string(forKey: "fmtCompressionMode") ?? "balanced"
        documentLayout = defaults.string(forKey: "fmtDocumentLayout") ?? "auto"
        videoHeight = defaults.object(forKey: "fmtVideoHeight") as? Int ?? 0
        archiveCompression = defaults.string(forKey: "fmtArchiveCompression") ?? "balanced"
    }
    func resetCompression() { compressionMode = "balanced"; videoHeight = 0; archiveCompression = "balanced" }
}

@MainActor
final class MargheritaUIState: ObservableObject {
    static let shared = MargheritaUIState()
    @Published var selectedTab: Int = 0
    @Published var selectedFormat: String = "JPG"
    @Published var formatQuery: String = ""
    @Published var hexDraft: String = ""
    let convertRecorder = ShortcutRecorder()
    let toolsRecorder = ShortcutRecorder()
    let actionsRecorder = ShortcutRecorder()
    let hotkeyRecorder = ShortcutRecorder()
}

// MARK: - Shared building blocks

struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
            SettingsCard { content }
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            content
        }.padding(.vertical, 8)
    }
}

struct SettingsCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var ui = MargheritaUIState.shared
    private let tabs = ["General", "Formats", "Compatibility", "Folders", "Permissions", "About"]
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ui.selectedTab) {
                ForEach(0..<tabs.count, id: \.self) { Text(tabs[$0]).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 520)
            .padding(.top, 12).padding(.bottom, 12)
            Divider()
            Group {
                switch ui.selectedTab {
                case 0: GeneralTab()
                case 1: FormatsTab()
                case 2: CompatibilityTab()
                case 3: FoldersTab()
                case 4: PermissionsTab()
                default: AboutTab()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(prefs.color)
        .onChange(of: ui.selectedTab) { _ in CompatibilityViewModel.shared.clearHover() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MargheritaShowAbout"))) { _ in ui.selectedTab = 5 }
    }
}

// MARK: General

private let modifierPresets: [(label: String, value: String)] = [
    ("\u{21E7} Shift", "shift"), ("\u{2325} Option", "option"), ("\u{2303} Control", "control"),
    ("\u{2318} Command", "command"), ("\u{21E7}\u{2325} Shift + Option", "shift+option"),
    ("\u{2303}\u{21E7} Control + Shift", "control+shift")
]

struct GeneralTab: View {
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var updater = UpdateController.shared
    @ObservedObject private var ui = MargheritaUIState.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsSection("Appearance") {
                    SettingsRow("Style") {
                        Picker("", selection: $prefs.wheelStyle) {
                            Text("Glass").tag("glass"); Text("Solid").tag("solid")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    }
                    Divider()
                    SettingsRow("Theme") {
                        Picker("", selection: $prefs.theme) {
                            Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                    Divider()
                    AccentPicker(prefs: prefs, ui: ui).padding(.vertical, 8)
                }
                SettingsSection("General") { generalRows }
                SettingsSection("Updates") {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }))
                        .disabled(!updater.isConfigured).padding(.vertical, 8)
                    Divider()
                    SettingsRow("Margherita updates") {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(updater.isConfigured && !updater.canCheckForUpdates)
                    }
                    SettingsCaption(updater.statusMessage)
                }
                SettingsSection("Drag Modifiers") { modifierRows }
                SettingsSection("Floating wheel") { wheelRows }
                SettingsSection("Open Settings") { hotkeyRows }
            }.padding(20)
        }
    }
    private var generalRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Launch at login", isOn: Binding(get: { prefs.loginEnabled }, set: { prefs.setLogin($0) }))
                .padding(.vertical, 8)
            if !prefs.loginError.isEmpty { Text(prefs.loginError).font(.caption).foregroundStyle(Color.margherita).padding(.bottom, 6) }
            Divider()
            Toggle("Sound and haptic feedback", isOn: Binding(get: { prefs.sounds && prefs.haptics }, set: { prefs.sounds = $0; prefs.haptics = $0 }))
                .padding(.vertical, 8)
                .onChange(of: prefs.sounds) { value in if value { SoundEffects.play(.drop, force: true) } }
            Divider()
            Toggle("Reveal finished outputs in Finder", isOn: $prefs.reveal).padding(.vertical, 8)
            Divider()
            Toggle("Show Margherita in the Dock", isOn: $prefs.dock).padding(.vertical, 8)
            Divider()
            Toggle("Show menu bar icon", isOn: $prefs.menuBar).padding(.vertical, 8)
            SettingsCaption("You can hide both. Opening Margherita again, or pressing your open shortcut, brings Settings back.")
            SettingsCaption("Move Margherita to Applications before enabling launch at login.")
        }
    }
    private var modifierRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Conversion wheel") { presetMenu(prefs.trigger, ui.convertRecorder, "shift") { prefs.trigger = $0 } }
            Divider()
            SettingsRow("Tools wheel") { presetMenu(prefs.toolsTrigger, ui.toolsRecorder, "shift+option") { prefs.toolsTrigger = $0 } }
            Divider()
            SettingsRow("Actions wheel") { presetMenu(prefs.actionsTrigger, ui.actionsRecorder, "control") { prefs.actionsTrigger = $0 } }
            Divider()
            SettingsRow("Float Behaviour") {
                Picker("", selection: $prefs.floatBehaviour) {
                    Text("Create a New Float").tag("new"); Text("Reuse Existing Float").tag("reuse")
                }.labelsHidden().frame(width: 190)
            }
            Divider()
            SettingsRow("Terminal app") {
                Picker("", selection: $prefs.terminalApp) {
                    Text("Terminal").tag("terminal"); Text("iTerm2 (if installed)").tag("iterm")
                }.labelsHidden().frame(width: 190)
            }
            SettingsCaption("Hold the chosen modifier while dragging files. You can release it once the wheel opens. If two shortcuts match, Actions wins, then Tools.")
            Divider()
            DisclosureGroup("Record custom keys") {
                VStack(spacing: 6) {
                    ShortcutRow(title: "Conversion wheel", subtitle: "Hold while dragging files",
                        value: prefs.trigger, fallback: "shift", allowModifierOnly: true,
                        recorder: ui.convertRecorder) { prefs.triggerShortcut = $0 }
                    ShortcutRow(title: "Tools wheel", subtitle: "Hold while dragging files",
                        value: prefs.toolsTrigger, fallback: "shift+option", allowModifierOnly: true,
                        recorder: ui.toolsRecorder) { prefs.toolsShortcut = $0 }
                    ShortcutRow(title: "Actions wheel", subtitle: "Hold while dragging files",
                        value: prefs.actionsTrigger, fallback: "control", allowModifierOnly: true,
                        recorder: ui.actionsRecorder) { prefs.actionsShortcut = $0 }
                    SettingsCaption("Click a shortcut, then press any keys. It saves when you let go. Escape cancels.")
                }.padding(.top, 6)
            }.padding(.vertical, 8)
        }
    }
    private func presetMenu(_ current: String, _ recorder: ShortcutRecorder, _ fallback: String,
                            _ set: @escaping (String) -> Void) -> some View {
        let isPreset = modifierPresets.contains { $0.value == current }
        return Picker("", selection: Binding(get: { current }, set: set)) {
            ForEach(modifierPresets, id: \.value) { Text($0.label).tag($0.value) }
            if !isPreset {
                Text("Custom: " + (KeyboardShortcut(serialized: current)?.display ?? current)).tag(current)
            }
        }.labelsHidden().frame(width: 190)
    }
    private var wheelRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Size") {
                Slider(value: $prefs.overlaySize, in: 320...460, step: 10).frame(width: 180)
                Text(String(Int(prefs.overlaySize)) + " pt").font(.caption).frame(width: 46, alignment: .trailing)
            }
            Divider()
            SettingsRow("Appears") {
                Picker("", selection: $prefs.overlayPosition) {
                    Text("Around cursor").tag("center"); Text("Right of cursor").tag("right"); Text("Left of cursor").tag("left")
                }.labelsHidden().frame(width: 190)
            }
            SettingsCaption("The wheel stays still so it is easy to drop onto. Reduce Motion follows your Mac's accessibility setting.")
        }
    }
    private var hotkeyRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Open Settings from anywhere", isOn: $prefs.hotkeyEnabled).padding(.vertical, 8)
            if prefs.hotkeyEnabled {
                Divider()
                ShortcutRow(title: "Open shortcut", subtitle: "Needs a key, like \u{2325}\u{2318}P",
                    value: prefs.hotkey, fallback: "command+option+#35", allowModifierOnly: false,
                    recorder: ui.hotkeyRecorder) { prefs.hotkeyShortcut = $0 }.padding(.vertical, 8)
            }
        }
    }
}

// MARK: Formats

// MARK: Compatibility

struct CompatibilityTab: View {
    @ObservedObject private var capabilities = FormatCapabilities.shared
    @ObservedObject private var model = CompatibilityViewModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("Format Compatibility", systemImage: "tablecells").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("Detected at launch").font(.caption).foregroundStyle(.secondary)
                }
                if !capabilities.isLoading {
                    ForEach(model.tables, id: \.name) { table in
                        CompatibilityMatrixView(table: table, hover: model.hoverState(for: table.name))
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("A check mark means Margherita offers that route on this Mac right now. An equals sign marks the same format, which needs no conversion. A dash means no route. XLS means Excel 2003 XML only, not binary Excel. Archive targets repack the files rather than convert their contents, SVG input uses a constrained renderer, and PDF recovery routes depend on the PDF's structure. Some routes need an installed app or codec, and results depend on the file's content.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.clearHover(); model.rebuild() }
        .onDisappear { model.clearHover() }
    }
}

// MARK: Permissions

@MainActor
final class PermissionStatus: ObservableObject {
    static let shared = PermissionStatus()
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var notifications = "Not asked"
    func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional: text = "Allowed"
            case .denied: text = "Denied"
            default: text = "Not asked"
            }
            DispatchQueue.main.async { PermissionStatus.shared.notifications = text }
        }
    }
}

struct PermissionsTab: View {
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var access = FolderAccess.shared
    @ObservedObject private var status = PermissionStatus.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsSection("Wheel (drag and modifier keys)") { wheelRows }
                SettingsSection("Folder access") { folderRows }
                SettingsSection("Notifications") { notificationRows }
                SettingsSection("Office and iWork automation") { automationRows }
                SettingsSection("Full Disk Access") { diskRows }
            }.padding(20)
        }
        .onAppear { status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status.refresh() }
    }
    private func badge(_ on: Bool, _ yes: String = "Allowed", _ no: String = "Not allowed") -> some View {
        Label(on ? yes : no, systemImage: on ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 12)).foregroundStyle(on ? Color.basil : Color.secondary)
    }
    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
    private var wheelRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Margherita listens for drag and modifier-key events, not what you type. macOS may need Accessibility and Input Monitoring before the wheel works across apps.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            Divider()
            SettingsRow("Accessibility") {
                badge(status.accessibility)
                Button("Request") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }.controlSize(.small)
            }
            Divider()
            SettingsRow("Input Monitoring") {
                badge(status.inputMonitoring)
                Button("Request") { _ = CGRequestListenEventAccess() }.controlSize(.small)
            }
            Divider()
            HStack {
                Button("Open Accessibility settings") { open("Privacy_Accessibility") }
                Button("Open Input Monitoring settings") { open("Privacy_ListenEvent") }
                Spacer()
            }.controlSize(.small).padding(.vertical, 8)
            SettingsCaption("After granting, quit and reopen Margherita. Some apps use private drag formats or intercept modifier keys.")
        }
    }
    private var folderRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Home folder") {
                if access.homeEnabled { badge(true) } else { Button("Allow Home Access\u{2026}") { access.grantHomeAccess() } }
            }
            ForEach(access.authorizedFolders, id: \.self) { url in
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(url.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { access.removeAccess(url) }.controlSize(.small)
                }.padding(.vertical, 8)
            }
            Divider()
            HStack { Button("Add Folder\u{2026}") { access.grantFolderAccess() }; Spacer() }.padding(.vertical, 8)
            if !access.error.isEmpty { Text(access.error).font(.caption).foregroundStyle(Color.margherita).padding(.bottom, 8) }
            SettingsCaption("Margherita saves converted files next to their originals, so it needs access to the folders you convert from. Removing access never deletes anything.")
        }
    }
    private var notificationRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Show a finish notification", isOn: $prefs.notifications).padding(.vertical, 8)
                .onChange(of: prefs.notifications) { value in if value { AppModel.shared.enableNotifications() } }
            Divider()
            SettingsRow("macOS permission") {
                Text(status.notifications).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Open Notifications settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }.controlSize(.small)
            }
            SettingsCaption("If macOS says Denied, turn notifications on there. The toggle above only controls whether Margherita sends one.")
        }
    }
    private var automationRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For better layout, document exports first use installed Word, PowerPoint or Excel, then Pages, Keynote or Numbers, then LibreOffice, before native recovery. PDF-to-Word tries Word PDF import when supported, then LibreOffice and an already-installed Python/pdf2docx. PDF reconstruction is not guaranteed to match the original.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            Text("macOS asks the first time a conversion controls an installed app. Allow Margherita under Privacy & Security > Automation. Cancel any offer to upload a PDF for online conversion; Margherita never approves it for you. Denying access falls back to another engine, and the success message names the engine used. macOS gives no way to check this in advance, so status is only shown by macOS itself.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Automation settings") { open("Privacy_Automation") }.controlSize(.small)
            SettingsCaption("Private copies are opened, not your original documents. Only convert trusted files; installed apps keep their own macro and external-link policies.")
        }
    }
    private var diskRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not required for normal use. Only grant it if conversions fail in protected locations that folder access cannot reach. Margherita cannot detect whether it is on.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            Button("Open Full Disk Access settings") { open("Privacy_AllFiles") }.controlSize(.small).padding(.bottom, 8)
        }
    }
}

// MARK: Folders

struct FoldersTab: View {
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var access = FolderAccess.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                WatchFolderSettings()
                SettingsSection("Save your fresh files") { destinationRows }
                SettingsSection("Defaults") { qualityRows }
                SettingsSection("Your files stay here") { privacy }
            }.padding(20)
        }
    }
    private var destinationRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Output location") {
                Picker("", selection: $prefs.location) {
                    Text("Next to original").tag("beside"); Text("A chosen folder").tag("folder"); Text("Ask each time").tag("ask")
                }.labelsHidden().frame(width: 190)
            }
            if prefs.location == "folder" {
                Divider()
                HStack {
                    Text(prefs.folder.isEmpty ? "No folder selected" : prefs.folder)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(); Button("Choose\u{2026}") { prefs.chooseFolder() }
                }.padding(.vertical, 8)
            }
            Divider()
            SettingsRow("Filename suffix") { TextField("", text: $prefs.suffix).frame(width: 190) }
            HStack(spacing: 6) {
                ForEach(["-{action}", "-margherita", "_converted"], id: \.self) { preset in
                    Button(preset) { prefs.suffix = preset }.buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Button("Reset") { prefs.suffix = "-{action}" }.controlSize(.small)
            }.padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("{action} becomes the conversion, such as compressed or jpgconvert.").font(.caption).foregroundStyle(.secondary)
                Text("holiday.heic  \u{2192}  " + prefs.suffixPreview(name: "holiday", action: "jpgconvert", ext: "jpg"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(prefs.color)
                Text("holiday.mov  \u{2192}  " + prefs.suffixPreview(name: "holiday", action: "compressed", ext: "mp4"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(prefs.color)
            }.padding(.bottom, 8)
            Divider()
            SettingsRow("If an output exists") {
                Picker("", selection: $prefs.collision) {
                    Text("Keep both (add a number)").tag("unique"); Text("Skip that file").tag("skip")
                    Text("Replace (keep a recovery copy)").tag("replace")
                }.labelsHidden().frame(width: 220)
            }
            SettingsCaption("Original input files are never overwritten, even with an empty suffix.")
        }
    }
    private var qualityRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Image / PDF quality") {
                Slider(value: $prefs.imageQuality, in: 0.1...1).frame(width: 160)
                Text(prefs.imageQuality, format: .percent.precision(.fractionLength(0))).frame(width: 42, alignment: .trailing)
            }
            Divider()
            SettingsRow("Video compression") {
                Picker("", selection: $prefs.videoQuality) {
                    Text("Smallest").tag("small"); Text("Balanced").tag("balanced"); Text("Best quality").tag("high")
                }.labelsHidden().frame(width: 150)
            }
            Divider()
            SettingsRow("M4A size budget") { Slider(value: $prefs.audioQuality, in: 0...1).frame(width: 160) }
            Divider()
            Toggle("Remove image and media metadata", isOn: $prefs.stripMetadata).padding(.vertical, 8)
            SettingsCaption("Metadata removal is best effort, not a guarantee of anonymity.")
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No accounts. No uploads. No analytics. Conversions run locally using Apple's built-in frameworks and, where needed, trusted codec tools already on your Mac.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            SettingsCaption("Margherita is not sandboxed so it can save beside files dragged from Finder. Only give it files you trust.")
        }
    }
}

// MARK: About

struct AboutTab: View {
    @EnvironmentObject var prefs: Preferences
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version " + short + " (" + build + ")"
    }
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Margherita").font(.system(size: 26, weight: .bold, design: .rounded))
            Text(version).font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Free. Offline. No conversion limits.").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Getting Started\u{2026}") { AppDelegate.shared?.openGettingStarted() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(.top, 8)
            Text("FFmpeg & ffprobe © FFmpeg developers. GPL v3 or later; separate executables.").font(.caption2).foregroundStyle(.secondary)
            Link("FFmpeg licence and source information", destination: URL(string: "https://ffmpeg.org/legal.html")!)
                .font(.caption)
            Text("Static builds by Martin Riedl").font(.caption2).foregroundStyle(.secondary)
            Button {
                AppDelegate.shared?.openSupport()
            } label: {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .tint(Color(nsColor: prefs.accentNS))
            .controlSize(.regular)
            .padding(.top, 4)
            .help("Support Margherita in your browser")
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

@MainActor
struct ShortcutRow: View {
    let title: String
    let subtitle: String
    let value: String
    let fallback: String
    let allowModifierOnly: Bool
    @ObservedObject var recorder: ShortcutRecorder
    let commit: (KeyboardShortcut) -> Void

    private var shortcut: KeyboardShortcut? {
        KeyboardShortcut(serialized: value) ?? KeyboardShortcut(serialized: fallback)
    }
    private var buttonTitle: String {
        if recorder.recording { return recorder.live.isEmpty ? "Press keys…" : recorder.live }
        return shortcut?.display ?? "Record shortcut"
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(buttonTitle) {
                recorder.toggle(allowModifierOnly: allowModifierOnly, commit: commit)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .frame(minWidth: 100)
            .help(recorder.recording ? "Release keys to save. Escape cancels." : "Click to record a shortcut")
        }
        .onDisappear { recorder.stop() }
    }
}

@MainActor
struct AccentPicker: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var ui: MargheritaUIState

    private var colorBinding: Binding<Color> {
        Binding(get: { prefs.color }, set: { color in
            prefs.accent = Preferences.hex(of: NSColor(color))
            ui.hexDraft = prefs.accentHex
        })
    }
    private var validHex: Bool { Preferences.parseHex(ui.hexDraft) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorPicker("Accent colour", selection: colorBinding, supportsOpacity: false)
            swatches
            hexEditor
        }
        .onAppear { ui.hexDraft = prefs.accentHex }
        .onChange(of: prefs.accent) { _ in ui.hexDraft = prefs.accentHex }
    }
    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(Preferences.swatches, id: \.name) { swatch in
                swatchButton(name: swatch.name, hex: swatch.hex)
            }
        }
    }
    private func swatchButton(name: String, hex: String) -> some View {
        let selected = prefs.accentHex.caseInsensitiveCompare(hex) == .orderedSame
        let color = Color(nsColor: Preferences.parseHex(hex) ?? NSColor(Color.margherita))
        return Button {
            prefs.accent = hex
        } label: {
            Circle().fill(color).frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(selected ? Color.primary : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain).help(name).accessibilityLabel(name)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
    private var hexEditor: some View {
        HStack {
            TextField("Hex colour", text: $ui.hexDraft)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 115).onSubmit { applyHex() }
            Button("Apply") { applyHex() }.disabled(!validHex)
            if !validHex { Text("Use #RGB or #RRGGBB").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func applyHex() {
        guard let color = Preferences.parseHex(ui.hexDraft) else { return }
        prefs.accent = Preferences.hex(of: color)
        ui.hexDraft = prefs.accentHex
    }
}
