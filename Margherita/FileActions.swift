import AppKit

enum FileAction: String, CaseIterable {
    case airdrop, float, copy, move, copyPath, terminal

    var title: String {
        switch self {
        case .airdrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .airdrop: return "airplayaudio"
        case .float: return "rectangle.on.rectangle"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "link"
        case .terminal: return "terminal"
        }
    }
}

@MainActor
final class FileActionController: NSObject, NSSharingServiceDelegate {
    static let shared = FileActionController()
    private var service: NSSharingService?
    private var moving = false

    func perform(_ action: FileAction, urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        switch action {
        case .airdrop: airdrop(files)
        case .float: ShelfController.shared.add(files)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(files as [NSURL])
        case .move: move(files)
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(files.map { $0.path }.joined(separator: "\n"), forType: .string)
        case .terminal: terminal(files)
        }
    }

    private func fail(_ message: String) {
        AppModel.shared.error = message
    }

    private func airdrop(_ files: [URL]) {
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: files) else {
            fail("AirDrop isn't available right now. Check that it is turned on.")
            return
        }
        s.delegate = self
        service = s
        s.perform(withItems: files)
    }

    nonisolated func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in
            self.fail("AirDrop failed: " + text)
            self.service = nil
        }
    }

    nonisolated func sharingService(_ s: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in self.service = nil }
    }

    /// Drops duplicates and any item whose ancestor is also selected.
    /// Returns an error message if the destination is unsafe.
    nonisolated static func planMove(_ files: [URL], to dest: URL) -> (items: [URL], error: String?) {
        // Item identity is the standardized original URL, so a selected symlink moves as the link itself.
        // The "location" resolves only the parent directories, never the item, and is used for safety checks.
        func location(_ u: URL) -> String {
            u.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(u.lastPathComponent).path
        }
        var unique: [URL] = []
        var seen = Set<String>()
        for f in files {
            let u = f.standardizedFileURL
            if seen.insert(location(u)).inserted { unique.append(u) }
        }
        let locs = unique.map { location($0) }
        var items: [URL] = []
        for (i, u) in unique.enumerated() {
            let covered = locs.enumerated().contains { j, other in
                j != i && locs[i].hasPrefix(other.hasSuffix("/") ? other : other + "/")
            }
            if !covered { items.append(u) }
        }
        let d = dest.standardizedFileURL.resolvingSymlinksInPath().path
        for u in items {
            let l = location(u)
            if d == l || d.hasPrefix(l + "/") {
                return (items, "Can't move \"" + u.lastPathComponent + "\" into itself or one of its own folders.")
            }
            if (l as NSString).deletingLastPathComponent == d {
                return (items, "\"" + u.lastPathComponent + "\" is already in that folder.")
            }
        }
        return (items, nil)
    }

    private func move(_ files: [URL]) {
        guard !moving else { fail("A file move is already in progress."); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where to move the file" + (files.count == 1 ? "" : "s")
        panel.level = .floating
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let plan = FileActionController.planMove(files, to: dest)
        if let e = plan.error { fail(e); return }
        let items = plan.items

        let alert = NSAlert()
        alert.messageText = "Move \(items.count) item" + (items.count == 1 ? "" : "s") + "?"
        alert.informativeText = "The originals will be moved to " + dest.path + ". Nothing is overwritten."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        moving = true
        Task {
            let message = await Task.detached(priority: .userInitiated) {
                Self.moveItems(items, to: dest)
            }.value
            moving = false
            if let message { fail(message) }
        }
    }

    /// FileManager may copy across volumes. Never block the main actor with that work.
    nonisolated static func moveItems(_ items: [URL], to dest: URL) -> String? {
        let fm = FileManager.default
        var done: [(from: URL, to: URL)] = []
        do {
            for src in items {
                let target = Self.uniqueURL(for: src.lastPathComponent, in: dest)
                try fm.moveItem(at: src, to: target)
                done.append((src, target))
            }
        } catch {
            var stuck: [(from: URL, to: URL)] = []
            for pair in done.reversed() {
                do { try fm.moveItem(at: pair.to, to: pair.from) } catch { stuck.append(pair) }
            }
            if stuck.isEmpty {
                return "Move failed and everything was put back: " + error.localizedDescription
            } else {
                let lines = stuck.map { "\($0.to.path) should go back to \($0.from.path)" }.joined(separator: "; ")
                return "Move failed (" + error.localizedDescription + ") and some files could not be put back. Move them back by hand: " + lines
            }
        }
        return nil
    }

    nonisolated private static func uniqueURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            url = dir.appendingPathComponent(next)
            n += 1
        }
        return url
    }

    private func terminal(_ files: [URL]) {
        var seen = Set<String>()
        var dirs: [String] = []
        for f in files {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir)
            let d = (exists && isDir.boolValue) ? f.path : f.deletingLastPathComponent().path
            if seen.insert(d).inserted { dirs.append(d) }
        }
        let ws = NSWorkspace.shared
        var appURL = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        if Preferences.shared.terminalApp.lowercased() == "iterm",
           let iterm = ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
            appURL = iterm
        }
        guard let app = appURL else { fail("Couldn't find Terminal."); return }
        let config = NSWorkspace.OpenConfiguration()
        ws.open(dirs.map { URL(fileURLWithPath: $0, isDirectory: true) }, withApplicationAt: app, configuration: config) { _, error in
            if let error = error {
                let text = error.localizedDescription
                Task { @MainActor in self.fail("Couldn't open the terminal: " + text) }
            }
        }
    }
}
