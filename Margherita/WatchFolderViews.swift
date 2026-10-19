#if os(macOS)
import SwiftUI
import AppKit

// MARK: Watch folders

/// Rules persist their own profile snapshots, independent of subsequent global changes.
struct WatchFolderSettings: View {
    @ObservedObject private var watcher = WatchFolders.shared
    @ObservedObject private var capabilities = FormatCapabilities.shared
    private var targets: [String] {
        Array(Set(capabilities.outputsByInput.values.flatMap { $0 })).sorted()
    }
    var body: some View {
        SettingsSection("Watch folders") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(watcher.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add folder…", action: addFolder)
                        .disabled(capabilities.isLoading || targets.isEmpty)
                }.padding(.vertical, 8)
                SettingsCaption("Enabled rules convert existing and newly added files automatically. Originals are kept unless you explicitly choose otherwise.")
                ForEach(watcher.rules) { rule in
                    Divider()
                    WatchFolderRuleEditor(rule: rule, targets: targets)
                }
            }
        }
    }
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Watch this folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let target = targets.contains("PNG") ? "PNG" : (targets.first ?? "PNG")
        do {
            try watcher.add(folder: folder, targetFormat: target,
                profiles: Preferences.shared.options.formatProfiles, deleteOriginal: false)
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not add watch folder"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
}

struct WatchFolderRuleEditor: View {
    let rule: WatchFolderRule
    let targets: [String]
    private func binding<Value>(_ key: WritableKeyPath<WatchFolderRule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: key] }, set: { value in
            guard var current = WatchFolders.shared.rules.first(where: { $0.id == rule.id }) else { return }
            current[keyPath: key] = value
            WatchFolders.shared.update(current)
        })
    }
    private func profile<Value>(_ key: WritableKeyPath<FormatProfile, Value>) -> Binding<Value> {
        let canonical = FormatSettingsStore.canonical(rule.targetFormat)
        return Binding(get: { (rule.profiles[canonical] ?? FormatProfile())[keyPath: key] }, set: { value in
            guard var current = WatchFolders.shared.rules.first(where: { $0.id == rule.id }) else { return }
            var settings = current.profiles[canonical] ?? FormatProfile()
            settings[keyPath: key] = value; current.profiles[canonical] = settings
            WatchFolders.shared.update(current)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(rule.name, isOn: binding(\.enabled)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Remove") { WatchFolders.shared.remove(id: rule.id) }.controlSize(.small)
            }
            Text(rule.folderPath).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
            SettingsRow("Convert to") {
                Picker("Output format", selection: binding(\.targetFormat)) {
                    ForEach(Array(Set(targets + [rule.targetFormat])).sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 160)
            }
            SettingsRow("Filename suffix") {
                TextField("-{action}", text: binding(\.suffix)).frame(width: 160)
            }
            Toggle("Include files in subfolders", isOn: binding(\.includeSubfolders))
            Toggle("Move originals to Trash after successful conversion", isOn: Binding(
                get: { rule.deleteOriginal }, set: setDeleteOriginal))
            SettingsCaption("Keep originals is the default. Trash only happens after a verified conversion; failed inputs are kept.")
            Text("Output folder").font(.caption).foregroundStyle(.secondary)
            SettingsCaption("Converted files are saved inside the reserved hidden .Margherita Outputs subfolder of the chosen output folder. This keeps generated files out of watched scans.")
            HStack {
                Text(rule.destinationPath).font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Open outputs") {
                    let parent = URL(fileURLWithPath: rule.destinationPath, isDirectory: true)
                    let outputs = parent.appendingPathComponent(".Margherita Outputs", isDirectory: true)
                    if FileManager.default.fileExists(atPath: outputs.path) {
                        NSWorkspace.shared.open(outputs)
                    } else {
                        NSWorkspace.shared.open(parent)
                    }
                }.controlSize(.small).help("Open converted files, or the chosen output folder before any exist.")
                Button("Choose…", action: chooseDestination).controlSize(.small)
            }
            DisclosureGroup("Per-format settings · " + rule.targetFormat) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsCaption("These settings belong to this rule. Changing global format settings does not change this saved snapshot.")
                    profileControls
                    Button("Copy current format defaults") {
                        guard var current = WatchFolders.shared.rules.first(where: { $0.id == rule.id }) else { return }
                        let key = FormatSettingsStore.canonical(current.targetFormat)
                        current.profiles[key] = FormatSettingsStore.shared.profile(for: key)
                        WatchFolders.shared.update(current)
                    }.controlSize(.small)
                }.padding(.vertical, 8)
            }.padding(.vertical, 8)
        }.padding(.vertical, 8)
    }
    @ViewBuilder private var profileControls: some View {
        let target = FormatSettingsStore.canonical(rule.targetFormat)
        if ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF"].contains(target) {
            SettingsRow("Quality") {
                if target == "PDF" { Slider(value: profile(\.pdfImageQuality), in: 0.1...1).frame(width: 160) }
                else { Slider(value: profile(\.imageQuality), in: 0.1...1).frame(width: 160) }
            }
            SettingsRow("Maximum dimension") {
                Picker("", selection: profile(\.maxDimension)) {
                    Text("Original").tag(0); Text("1280 px").tag(1280)
                    Text("1920 px").tag(1920); Text("3840 px").tag(3840)
                }.labelsHidden().frame(width: 160)
            }
            Toggle("Remove metadata", isOn: profile(\.stripMetadata))
        }
        if ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV"].contains(target) {
            SettingsRow("Video quality") {
                Picker("", selection: profile(\.videoQuality)) {
                    Text("Smallest").tag("small"); Text("Balanced").tag("balanced"); Text("Best").tag("high")
                }.labelsHidden().frame(width: 160)
            }
        }
        if ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF"].contains(target) {
            SettingsRow("Audio bitrate") {
                Picker("", selection: profile(\.audioBitrate)) {
                    Text("128 kbps").tag(128); Text("192 kbps").tag(192)
                    Text("256 kbps").tag(256); Text("320 kbps").tag(320)
                }.labelsHidden().frame(width: 160)
            }
        }
        if target == "GIF" {
            SettingsRow("Frames per second") {
                Picker("", selection: profile(\.gifFPS)) {
                    Text("10").tag(10); Text("15").tag(15); Text("24").tag(24); Text("30").tag(30)
                }.labelsHidden().frame(width: 160)
            }
            Toggle("Loop animation", isOn: profile(\.gifLoop))
        }
        if target == "PDF" {
            SettingsRow("Document layout") {
                Picker("", selection: profile(\.documentLayout)) {
                    Text("Automatic").tag("auto"); Text("Preserve layout").tag("fixed")
                    Text("Editable paragraphs").tag("editable")
                }.labelsHidden().frame(width: 160)
            }
        }
        if ["ZIP", "TAR", "GZIP"].contains(target) {
            SettingsRow("Archive compression") {
                Picker("", selection: profile(\.archiveCompression)) {
                    Text("Fast").tag("fast"); Text("Balanced").tag("balanced"); Text("Smallest").tag("small")
                }.labelsHidden().frame(width: 160)
            }
        }
    }
    private func setDeleteOriginal(_ enabled: Bool) {
        if enabled {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move original files to Trash?"
            alert.informativeText = "This rule runs automatically, including on existing files. After each verified successful conversion, the source file will be moved to Trash. Keep originals unless you are sure."
            alert.addButton(withTitle: "Keep originals")
            alert.addButton(withTitle: "Move originals to Trash")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        binding(\.deleteOriginal).wrappedValue = enabled
    }
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Save converted files here"
        guard panel.runModal() == .OK, let destination = panel.url,
              var current = WatchFolders.shared.rules.first(where: { $0.id == rule.id }) else { return }
        do {
            current.destinationBookmark = try destination.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            current.destinationPath = destination.path
            WatchFolders.shared.update(current)
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not save folder access"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
}

#endif
