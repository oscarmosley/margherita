#if os(macOS)
import Foundation
import Combine
import CoreServices
import Darwin

/// Call start() once local conversion engines have finished bootstrapping.
/// No window or Dock presence is required.
@MainActor
final class WatchFolders: ObservableObject {
    static let shared = WatchFolders()
    @Published private(set) var rules: [WatchFolderRule] = []
    @Published private(set) var status = "Watch folders paused"
    private let defaults: UserDefaults
    private let worker = WatchFolderWorker()
    private var ready = false
    private var revision = 0
    private var activeCancellation: ConversionCancellation?
    private var transition: Task<Void, Never>?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "watchFolderRules.v1"),
           let saved = try? JSONDecoder().decode([WatchFolderRule].self, from: data) { rules = saved }
    }
    func start() { ready = true; restart() }
    func stop() { ready = false; restart() }
    @discardableResult
    func add(folder: URL, destination: URL? = nil, targetFormat: String,
             profiles: [String: FormatProfile] = [:], suffix: String = "-{action}",
             deleteOriginal: Bool = false, includeSubfolders: Bool = false) throws -> UUID {
        let output = destination ?? folder
        let rule = WatchFolderRule(name: folder.lastPathComponent,
            folderPath: folder.path, destinationPath: output.path,
            folderBookmark: try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
            destinationBookmark: try output.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
            targetFormat: targetFormat, profiles: profiles, suffix: suffix,
            deleteOriginal: deleteOriginal, includeSubfolders: includeSubfolders)
        rules.append(rule); persist(); return rule.id
    }
    func update(_ rule: WatchFolderRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule; persist()
    }
    func remove(id: UUID) { rules.removeAll { $0.id == id }; persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "watchFolderRules.v1") }
        restart()
    }
    private func restart() {
        activeCancellation?.cancel() // Cancel immediately on removal, before awaiting teardown.
        let runCancellation = ConversionCancellation()
        activeCancellation = runCancellation
        revision += 1
        let version = revision, snapshot = ready ? rules.filter(\.enabled) : []
        // Chain transitions so scopes from an old run cannot outlive its teardown.
        let previous = transition
        transition = Task {
            await previous?.value
            await worker.stop()
            guard version == revision else { return }
            if !snapshot.isEmpty {
                let errors = await worker.start(snapshot, cancellation: runCancellation, report: { [weak self] message in
                    Task { @MainActor in self?.status = message }
                })
                status = errors.isEmpty ? "Watching \(snapshot.count) folder(s)" : errors.joined(separator: "\n")
            } else { status = "Watch folders paused" }
        }
    }
}

private final class WatchEventFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty = true
    func signal() { lock.lock(); dirty = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let value = dirty; dirty = false; return value }
}

/// FSEvents is only a wake-up hint. Full scans also recover dropped/coalesced events.
private final class WatchEventStream {
    private var stream: FSEventStreamRef?
    private let flag: WatchEventFlag
    init?(roots: [String], flag: WatchEventFlag) {
        self.flag = flag
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(flag).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<WatchEventFlag>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<WatchEventFlag>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        guard let value = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WatchEventFlag>.fromOpaque(info).takeUnretainedValue().signal()
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        stream = value
        FSEventStreamSetDispatchQueue(value, DispatchQueue(label: "Margherita.watch.events"))
        guard FSEventStreamStart(value) else { FSEventStreamInvalidate(value); FSEventStreamRelease(value); stream = nil; return nil }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

private actor WatchFolderWorker {
    private struct Resolved {
        let rule: WatchFolderRule
        let root: URL
        let destination: URL
    }
    private struct Ledger: Codable {
        var outputs: Set<String>
        var completed: [String: WatchFileStamp]
    }
    private var task: Task<Void, Never>?
    private var token: ConversionCancellation?
    private var stream: WatchEventStream?
    private var scopes: [URL] = []
    private var outputs: Set<String> = []
    private var completed: [String: WatchFileStamp] = [:]
    private var retries: [String: WatchRetry] = [:]
    private var report: (@Sendable (String) -> Void)?
    private var stability: [String: WatchStability] = [:]
    private let engine = ConversionEngine()
    private let ledger = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Margherita/watchOutputs.json")

    private var pendingJournal: URL { ledger.deletingLastPathComponent().appendingPathComponent("watchPending.json") }
    func start(_ rules: [WatchFolderRule], cancellation: ConversionCancellation,
               report: @escaping @Sendable (String) -> Void) -> [String] {
        self.report = report
        // A write-ahead marker survives a failed ledger write or process interruption.
        // Fail closed rather than rediscovering unknown generated files in other roots.
        if FileManager.default.fileExists(atPath: pendingJournal.path) {
            return ["Watch folders paused after an interrupted output ledger write. Review generated files before removing watchPending.json in Application Support/Margherita."]
        }
        if let data = try? Data(contentsOf: ledger) {
            if let saved = try? JSONDecoder().decode(Ledger.self, from: data) {
                outputs = saved.outputs; completed = saved.completed
            } else if let saved = try? JSONDecoder().decode(Set<String>.self, from: data) { outputs = saved }
        }
        var active: [Resolved] = [], errors: [String] = []
        for rule in rules {
            do {
                var staleRoot = false, staleOutput = false
                let root = try URL(resolvingBookmarkData: rule.folderBookmark, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &staleRoot)
                let output = try URL(resolvingBookmarkData: rule.destinationBookmark, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &staleOutput)
                guard WatchPathPolicy.allowedRoot(root), WatchPathPolicy.allowedRoot(output),
                      WatchPathPolicy.rootIsNotSymlink(root),
                      WatchPathPolicy.rootIsNotSymlink(output) else {
                    throw MargheritaError.message("Symbolic-link folders are not supported.")
                }
                // Stale grants need explicit re-selection rather than falling back to unsafe saved paths.
                guard !staleRoot, !staleOutput else { throw MargheritaError.message("Re-add this folder to renew its permission.") }
                if root.startAccessingSecurityScopedResource() { scopes.append(root) }
                if output.startAccessingSecurityScopedResource() { scopes.append(output) }
                guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      (try? output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    throw MargheritaError.message("Folder is unavailable.")
                }
                guard action(rule.targetFormat) != nil else { throw MargheritaError.message("Unknown target format.") }
                let reserved = output.appendingPathComponent(WatchPathPolicy.outputDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
                guard WatchPathPolicy.rootIsNotSymlink(reserved) else {
                    throw MargheritaError.message("Output folder must not be a symbolic link.")
                }
                active.append(Resolved(rule: rule, root: root, destination: reserved))
            } catch { errors.append(rule.name + " · " + error.localizedDescription) }
        }
        guard !active.isEmpty else { releaseScopes(); return errors }
        let flag = WatchEventFlag()
        stream = WatchEventStream(roots: active.map { $0.root.path }, flag: flag)
        if stream == nil { errors.append("Event monitoring unavailable; using periodic folder scans.") }
        token = cancellation
        task = Task.detached(priority: .utility) { [weak self] in
            var tick = 0
            while !Task.isCancelled && !cancellation.isCancelled {
                if flag.take() || tick % 10 == 0 {
                    await self?.scan(active, cancellation: cancellation)
                } else {
                    await self?.samplePending(active, cancellation: cancellation)
                }
                tick += 1
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        return errors
    }
    func stop() async {
        token?.cancel(); task?.cancel()
        let running = task
        stream = nil
        await running?.value
        task = nil; token = nil; stability.removeAll(); completed.removeAll()
        releaseScopes()
    }
    private func releaseScopes() {
        for scope in scopes { scope.stopAccessingSecurityScopedResource() }
        scopes.removeAll()
    }
    private func action(_ format: String) -> Action? {
        Action.allCases.first { $0.rawValue.lowercased() == format.lowercased() || $0.format.lowercased() == format.lowercased() }
            .flatMap { ConversionRoutes.isNormal($0) ? $0 : nil }
    }
    private func samplePending(_ rules: [Resolved], cancellation: ConversionCancellation) async {
        if !stability.isEmpty { await scan(rules, cancellation: cancellation) }
    }
    private func scan(_ rules: [Resolved], cancellation: ConversionCancellation) async {
        var visited = Set<String>()
        for entry in rules {
            if cancellation.isCancelled || Task.isCancelled { return }
            let recursive = entry.rule.includeSubfolders
            let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            guard let files = FileManager.default.enumerator(at: entry.root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: options) else { continue }
            for case let url as URL in files {
                if cancellation.isCancelled || Task.isCancelled { return }
                // More-specific roots own overlapping inputs, independent of rule enumeration order.
                let path = WatchPathPolicy.canonical(url)
                if rules.contains(where: { $0.rule.id != entry.rule.id &&
                    WatchPathPolicy.canonical($0.root).count > WatchPathPolicy.canonical(entry.root).count &&
                    WatchPathPolicy.contains(path, in: WatchPathPolicy.canonical($0.root)) }) { continue }
                guard WatchPathPolicy.eligible(url, root: entry.root, recursive: recursive, outputs: outputs),
                      let stamp = WatchFileStamp.read(url), let action = action(entry.rule.targetFormat),
                      ConversionRoutes.allows(url, action: action, facts: ConversionRoutes.current) else { continue }
                let key = entry.rule.id.uuidString + "|" + path
                visited.insert(key)
                guard completed[key] != stamp, Date() >= (retries[key]?.nextAttempt ?? .distantPast) else { continue }
                var samples = stability[key] ?? WatchStability()
                let stable = samples.sample(stamp, now: Date())
                stability[key] = samples
                guard stable else { continue }
                var conversion = ConversionOptions()
                conversion.destination = entry.destination
                conversion.formatProfiles = entry.rule.profiles
                conversion.suffix = entry.rule.suffix
                conversion.collision = "unique"
                do {
                    try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode([url.path, entry.destination.path]).write(to: pendingJournal, options: .atomic)
                } catch { cancellation.cancel(); return }
                let result = await ConversionCancellation.$current.withValue(cancellation) {
                    await engine.run([url], action: action, options: conversion, progress: { _, _ in })
                }
                // Record all committed outputs even on cancellation, before any next root scan.
                for output in result.outputs { outputs.insert(WatchPathPolicy.canonical(output)) }
                let success = !result.outputs.isEmpty && result.notes.isEmpty
                if success { completed[key] = stamp; retries.removeValue(forKey: key) }
                else {
                    var retry = retries[key] ?? WatchRetry()
                    retry.failed(now: Date()); retries[key] = retry
                    report?("Conversion failed; retry scheduled for " + url.lastPathComponent)
                }
                guard saveLedger() else { cancellation.cancel(); return }
                do { try FileManager.default.removeItem(at: pendingJournal) }
                catch { cancellation.cancel(); return }
                if cancellation.isCancelled || Task.isCancelled { return }
                stability.removeValue(forKey: key)
                if entry.rule.deleteOriginal, result.notes.isEmpty, result.outputs.count == 1,
                   let output = result.outputs.first,
                   WatchPathPolicy.eligible(url, root: entry.root, recursive: recursive, outputs: outputs),
                   WatchPathPolicy.canDelete(source: url, before: stamp, output: output) {
                    await stageAndTrash(url, before: stamp, root: entry.root)
                }
            }
        }
        stability = stability.filter { visited.contains($0.key) }
    }
    private func stageAndTrash(_ source: URL, before: WatchFileStamp, root: URL) async {
        let fm = FileManager.default
        let holding = root.appendingPathComponent(".Margherita Recovery", isDirectory: true)
        let privateFolder = holding.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = privateFolder.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: holding, withIntermediateDirectories: true)
            guard WatchPathPolicy.rootIsNotSymlink(holding) else { throw MargheritaError.message("Recovery folder is a symbolic link.") }
            try fm.createDirectory(at: privateFolder, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            // Same-volume rename captures whichever candidate is actually at the source path.
            guard rename(source.path, staged.path) == 0 else { throw MargheritaError.message("Could not stage original.") }
            guard let captured = WatchFileStamp.read(staged),
                  WatchPathPolicy.sameStagedIdentity(before, captured) else {
                // Never overwrite a replacement at the old name. A unique alternate is safe.
                let restored = source.deletingLastPathComponent().appendingPathComponent(
                    source.deletingPathExtension().lastPathComponent + "-recovered-" + UUID().uuidString)
                    .appendingPathExtension(source.pathExtension)
                do { try fm.moveItem(at: staged, to: restored)
                    report?("Original changed; kept safely at " + restored.path)
                } catch { report?("Original changed; retained for recovery at " + staged.path) }
                return
            }
            if token?.isCancelled == true {
                report?("Cancelled; original retained at " + staged.path); return
            }
            try fm.trashItem(at: staged, resultingItemURL: nil)
            try? fm.removeItem(at: privateFolder)
        } catch { report?("Original was not deleted. Check recovery location " + staged.path + " · " + error.localizedDescription) }
    }
    private func saveLedger() -> Bool {
        do {
            try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Ledger(outputs: outputs, completed: completed)).write(to: ledger, options: .atomic)
            return true
        } catch {
            // Never delete originals if loop protection cannot survive a restart.
            token?.cancel()
            return false
        }
    }
}
#endif
