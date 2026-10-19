import Foundation
import AppKit
import Combine

/// Remembers explicitly granted folders and retains security-scoped access while running.
/// Removing a grant forgets the bookmark; it never removes anything from disk.
@MainActor
final class FolderAccess: ObservableObject {
    static let shared = FolderAccess()
    @Published private(set) var authorizedFolders: [URL] = []
    @Published private(set) var homeEnabled = false
    @Published private(set) var error = ""
    private let key = "folderAccessBookmarksV6"
    private var active: [URL] = []
    private let defaults = UserDefaults.standard

    private init() { restore() }
    deinit { for url in active { url.stopAccessingSecurityScopedResource() } }

    func grantHomeAccess() {
        choose(initial: FileManager.default.homeDirectoryForCurrentUser, homeOnly: true)
    }
    func grantFolderAccess() { choose(initial: FileManager.default.homeDirectoryForCurrentUser, homeOnly: false) }

    private func choose(initial: URL, homeOnly: Bool) {
        let panel = NSOpenPanel()
        panel.title = homeOnly ? "Allow Home Folder Access" : "Allow Folder Access"
        panel.message = "Margherita saves converted files next to their originals. Choose a folder to remember access."
        panel.directoryURL = initial
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = "Allow Access"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if homeOnly && canonical(url) != canonical(initial) {
            error = "Choose your Home folder to enable Home folder access."
            return
        }
        remember(url)
    }

    func remember(_ url: URL) {
        guard url.isFileURL else { return }
        let started = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var saved = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
            saved[canonical(url)] = bookmark; defaults.set(saved, forKey: key)
            if !authorizedFolders.contains(where: { canonical($0) == canonical(url) }) {
                authorizedFolders.append(url)
                if started { active.append(url) }
            } else if started { url.stopAccessingSecurityScopedResource() }
            error = ""; updateHome()
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            self.error = "Could not remember folder access. " + error.localizedDescription
        }
    }

    func removeAccess(_ url: URL) {
        let path = canonical(url)
        var saved = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        saved.removeValue(forKey: path); defaults.set(saved, forKey: key)
        for item in active where canonical(item) == path { item.stopAccessingSecurityScopedResource() }
        active.removeAll { canonical($0) == path }
        authorizedFolders.removeAll { canonical($0) == path }; updateHome()
    }

    private func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    private func updateHome() {
        let home = canonical(FileManager.default.homeDirectoryForCurrentUser)
        homeEnabled = authorizedFolders.contains { canonical($0) == home }
    }
    private func restore() {
        let saved = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        var refreshed = saved
        for (path, data) in saved {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.isFileURL else { continue }
                let started = url.startAccessingSecurityScopedResource()
                authorizedFolders.append(url); if started { active.append(url) }
                if stale {
                    refreshed[path] = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                }
            } catch { self.error = "Some saved folder access needs to be granted again." }
        }
        defaults.set(refreshed, forKey: key); updateHome()
    }
}
