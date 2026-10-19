import Foundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var files: [URL] = []
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "Ready when you are."
    @Published var history: [HistoryEntry] = []
    @Published var error: String?
    private var activeBatch: UUID?
    private var progressBatch: UUID?
    private var task: Task<Void, Never>?
    private var wasCancelled = false
    private var cancellation: ConversionCancellation?
    private var cancelFallback: Task<Void, Never>?
    private var stallWatchdog: Task<Void, Never>?
    private var lastProgressAt = Date()
    let preferences = Preferences.shared
    private var historyURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Margherita/history.json")
    }
    private init() {
        if let data = try? Data(contentsOf: historyURL),
           let items = try? JSONDecoder().decode([HistoryEntry].self, from: data) { history = items }
        inspectRecovery()
    }
    private func inspectRecovery() {
        let folder = historyURL.deletingLastPathComponent().appendingPathComponent("Recovery")
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let known = Set(history.flatMap { Array($0.backups.values) }.map(\.path))
        for item in items where item.lastPathComponent.hasSuffix(".recovery.json") {
            guard let data = try? Data(contentsOf: item),
                  let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data),
                  record.backup.fileExists, !known.contains(record.backup.path) else { continue }
            error = "An interrupted replacement has a safe recovery copy at " + record.backup.path +
                ". Its original location was " + record.target.path +
                ". Neither file was changed on launch. Open the Recovery folder in Finder to restore it manually."
        }
    }
    func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        panel.prompt = "Add to Margherita"
        if panel.runModal() == .OK { files = panel.urls }
    }
    func accept(_ urls: [URL]) {
        files = urls.filter { $0.isFileURL && $0.fileExists }
        status = files.count == 1 ? files[0].lastPathComponent : String(files.count) + " files, ready."
    }
    func run(_ action: Action, urls provided: [URL]? = nil) {
        let inputs = provided ?? files
        guard !inputs.isEmpty else { return }
        if action == .copyPath {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(inputs.map(\.path).joined(separator: "\n"), forType: .string)
            status = "Paths copied."; return
        }
        if action == .reveal { NSWorkspace.shared.activateFileViewerSelecting(inputs); return }
        guard !busy else { status = "A batch is already running. Wait or cancel it."; return }
        if action == .compress && inputs.contains(where: { FileKind.of($0) == .pdf }) {
            let alert = NSAlert()
            alert.messageText = "Make an image-only PDF?"
            alert.informativeText = "Compression redraws every page as a JPEG. Searchable text, links, forms, accessibility tags and signatures will not be preserved. Your original stays untouched. A small PDF may become larger."
            alert.addButton(withTitle: "Compress a copy"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        var options = preferences.options
        if preferences.location == "folder" {
            guard !preferences.folder.isEmpty else { preferences.chooseFolder(); return }
            options.destination = URL(fileURLWithPath: preferences.folder, isDirectory: true)
        } else if preferences.location == "ask" {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.prompt = "Save here"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            FolderAccess.shared.remember(url)
            options.destination = url
        }
        // Modal panels run a nested event loop; another request may have started meanwhile.
        guard !busy else { return }
        let batch = UUID()
        cancelFallback?.cancel()
        let cancellation = ConversionCancellation()
        self.cancellation = cancellation
        let engine = ConversionEngine()
        activeBatch = batch; progressBatch = batch; error = nil; wasCancelled = false; lastProgressAt = Date()
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.activeBatch == batch else { return }
                if Date().timeIntervalSince(self.lastProgressAt) > 300 {
                    self.cancel()
                    return
                }
            }
        }
        busy = true; progress = 0; status = "Starting " + action.title.lowercased() + "…"
        ConversionHUD.shared.begin(status)
        let snapshot = options
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                await ConversionCancellation.$current.withValue(cancellation) {
                    await engine.run(inputs, action: action, options: snapshot) { amount, message in
                        Task { @MainActor [weak self] in
                            guard let self, self.busy, self.activeBatch == batch, self.progressBatch == batch,
                                  !cancellation.isCancelled else { return }
                            self.lastProgressAt = Date()
                            self.progress = amount; self.status = message
                        }
                    }
                }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value },
                onCancel: { cancellation.cancel(); worker.cancel() })
            let isCurrent = activeBatch == batch
            if isCurrent { progressBatch = nil; progress = 1 }
            guard isCurrent else {
                // A cancelled framework may unwind late. Keep recovery ownership,
                // but never let an old batch overwrite a new HUD or busy state.
                if !result.outputs.isEmpty {
                    let entry = HistoryEntry(operation: action.title, inputs: inputs, outputs: result.outputs,
                        backups: result.backups, modified: [:], message: result.notes.joined(separator: "\n"))
                    history.insert(entry, at: 0); persist()
                }
                return
            }
            let count = result.outputs.count
            status = count == 0 ? "No files created." : String(count) + (count == 1 ? " output ready." : " outputs ready.")
            var dates: [String: Date] = [:]
            for url in result.outputs {
                dates[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            }
            let message = result.notes.joined(separator: "\n")
            status = "Verifying finished files…"
            let manifests = await Task.detached(priority: .utility) {
                var values: [String: [String: FileStamp]] = [:]
                for url in result.outputs {
                    if let manifest = try? FileStamp.manifest(url) { values[url.path] = manifest }
                }
                return values
            }.value
            guard activeBatch == batch else {
                if !result.outputs.isEmpty {
                    var entry = HistoryEntry(operation: action.title, inputs: inputs, outputs: result.outputs,
                        backups: result.backups, modified: dates, message: message)
                    entry.manifests = manifests; history.insert(entry, at: 0); persist()
                }
                return
            }
            cancelFallback?.cancel(); stallWatchdog?.cancel()
            status = count == 0 ? "No files created." : String(count) + (count == 1 ? " output ready." : " outputs ready.")
            if !result.engines.isEmpty { status += " " + result.engines.joined(separator: ", ") }
            var entry = HistoryEntry(operation: action.title, inputs: inputs, outputs: result.outputs,
                                     backups: result.backups, modified: dates, message: message)
            entry.manifests = manifests
            history.insert(entry, at: 0)
            // Do not trim history automatically: it owns recovery locations for replaced outputs.
            persist()
            if !message.isEmpty && !wasCancelled { error = message }
            if wasCancelled && count == 0 {
                status = "Cancelled."
                ConversionHUD.shared.dismiss()
            } else if count == 0 && message.isEmpty {
                ConversionHUD.shared.fail("No files created.")
            } else if wasCancelled {
                ConversionHUD.shared.succeed("Cancelled. Completed files were kept.")
            } else if message.isEmpty {
                ConversionHUD.shared.succeed(status)
            }
            // A non-empty message was assigned to error above, and the HUD observes error.
            if count > 0 {
                SoundEffects.play(.success)
                if preferences.reveal { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
                if preferences.notifications {
                    let content = UNMutableNotificationContent()
                    content.title = "Fresh from Margherita"
                    content.body = status
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request) { _ in }
                }
            }
            activeBatch = nil; cancellation.cancel()
            self.cancellation = nil; busy = false; task = nil
        }
    }
    func cancel() {
        guard busy, let batch = activeBatch, !wasCancelled else { return }
        wasCancelled = true
        progressBatch = nil
        stallWatchdog?.cancel()
        cancellation?.cancel(); task?.cancel()
        status = "Cancelling…"
        cancelFallback?.cancel()
        cancelFallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.activeBatch == batch else { return }
            // The token prevents a late worker from installing any partial output.
            // A fresh batch owns a fresh engine rather than queueing behind it.
            self.activeBatch = nil; self.busy = false; self.task = nil
            self.cancellation = nil; self.progress = 0
            self.status = "Cancelled. Temporary-file cleanup may finish in the background."
            ConversionHUD.shared.dismiss()
        }
    }
    func undo(_ entry: HistoryEntry) {
        guard !busy && !entry.undone else { return }
        let alert = NSAlert()
        alert.messageText = "Undo this conversion?"
        alert.informativeText = "Margherita will move its outputs to the Trash and restore any older outputs it replaced. Original input files are not touched."
        alert.addButton(withTitle: "Move outputs to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        do {
            // Reconcile an interrupted restore. Never delete a possible restored original.
            for output in entry.outputs {
                if (history[index].trashedPaths ?? []).contains(output.path),
                   !(history[index].undonePaths ?? []).contains(output.path),
                   let backup = entry.backups[output.path], !backup.fileExists, output.fileExists {
                    history[index].undonePaths = (history[index].undonePaths ?? []) + [output.path]
                    try saveHistory()
                }
            }
            let done = Set(history[index].undonePaths ?? [])
            let trashed = Set(history[index].trashedPaths ?? [])
            // Validate every outstanding output and recovery copy before changing anything.
            for output in entry.outputs where !done.contains(output.path) {
                if let saved = entry.backups[output.path], !saved.fileExists {
                    throw MargheritaError.message("Recovery copy is missing. Undo stopped without replacing anything.")
                }
                if !trashed.contains(output.path), output.fileExists {
                    guard let expected = entry.manifests?[output.path],
                          try FileStamp.manifest(output) == expected else {
                        throw MargheritaError.message(output.lastPathComponent + " changed or cannot be safely checked. Move it manually if you no longer need it.")
                    }
                }
            }
            for output in entry.outputs where !done.contains(output.path) {
                if !(history[index].trashedPaths ?? []).contains(output.path) {
                    if output.fileExists { try FileManager.default.trashItem(at: output, resultingItemURL: nil) }
                    history[index].trashedPaths = (history[index].trashedPaths ?? []) + [output.path]
                    try saveHistory()
                }
                if let saved = entry.backups[output.path] {
                    guard !output.fileExists else {
                        throw MargheritaError.message("A file now occupies " + output.path + ". Recovery copy left untouched.")
                    }
                    try FileManager.default.moveItem(at: saved, to: output)
                }
                history[index].undonePaths = (history[index].undonePaths ?? []) + [output.path]
                try saveHistory()
            }
            history[index].undone = true
            try saveHistory(); status = "Undone. Your originals are safe."
        } catch { self.error = error.localizedDescription }
    }
    private func saveHistory() throws {
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    }
    func persist() {
        do {
            try saveHistory()
        } catch { self.error = "Could not save history. " + error.localizedDescription }
    }
    func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if let error { self.error = error.localizedDescription }
                if !granted { self.preferences.notifications = false }
            }
        }
    }
}
