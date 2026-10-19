import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// No AppKit dependency: these policies are also compiled by the portable test harness.
struct WatchFileStamp: Codable, Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let identity: UInt64
    let changed: Date
    var device: UInt64 = 0
    var modifiedNanoseconds: Int64 = 0
    var changedNanoseconds: Int64 = 0
    static func read(_ url: URL) -> WatchFileStamp? {
        // lstat refuses the leaf link. Eligibility separately refuses relative parent links.
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        #endif
        return WatchFileStamp(size: UInt64(info.st_size),
            modified: Date(timeIntervalSince1970: Double(modified.tv_sec)),
            identity: UInt64(info.st_ino),
            changed: Date(timeIntervalSince1970: Double(changed.tv_sec)),
            device: UInt64(info.st_dev),
            modifiedNanoseconds: Int64(modified.tv_nsec),
            changedNanoseconds: Int64(changed.tv_nsec))
    }
}

struct WatchStability {
    private var previous: WatchFileStamp?
    private var count = 0
    private var since = Date.distantPast
    mutating func sample(_ stamp: WatchFileStamp, now: Date, samples: Int = 3, quiet: TimeInterval = 2) -> Bool {
        if previous == stamp { count += 1 }
        else { previous = stamp; count = 1; since = now }
        return stamp.size > 0 && count >= max(3, samples) && now.timeIntervalSince(since) >= quiet
    }
}

struct WatchRetry {
    var failures = 0
    var nextAttempt = Date.distantPast
    mutating func failed(now: Date) {
        failures = min(failures + 1, 10)
        nextAttempt = now.addingTimeInterval(min(300, pow(2, Double(failures))))
    }
}
enum WatchPathPolicy {
    static let outputDirectory = ".Margherita Outputs"
    static func allowedRoot(_ url: URL) -> Bool {
        !url.standardizedFileURL.pathComponents.contains(outputDirectory) &&
        !url.resolvingSymlinksInPath().pathComponents.contains(outputDirectory) &&
        !url.standardizedFileURL.pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "/" })
    }
    static func sameStagedIdentity(_ before: WatchFileStamp, _ after: WatchFileStamp) -> Bool {
        // Rename changes ctime. Device/inode/size/nanosecond mtime must remain identical.
        before.device == after.device && before.identity == after.identity &&
        before.size == after.size && before.modified == after.modified &&
        before.modifiedNanoseconds == after.modifiedNanoseconds
    }
    static func rootIsNotSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 &&
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }
    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    }
    static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    static func eligible(_ url: URL, root: URL, recursive: Bool, outputs: Set<String>) -> Bool {
        let raw = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        let canonical = canonical(url)
        guard rootIsNotSymlink(root), contains(raw, in: base), raw != base,
              contains(canonical, in: self.canonical(root)), !outputs.contains(canonical) else { return false }
        let relative = String(raw.dropFirst(base.count)).split(separator: "/")
        guard recursive || relative.count == 1 else { return false }
        let temporary = ["tmp", "temp", "part", "partial", "download", "crdownload", "swp"]
        guard !temporary.contains(url.pathExtension.lowercased()),
              !relative.contains(where: { $0.hasPrefix(".") || $0.hasPrefix("~") || $0.hasSuffix("~") }) else { return false }
        // Reject symlinks anywhere along the relative path, not only the leaf.
        var cursor = root
        for component in relative {
            cursor.appendPathComponent(String(component))
            guard let a = try? FileManager.default.attributesOfItem(atPath: cursor.path),
                  a[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
        }
        return WatchFileStamp.read(url) != nil
    }
    static func canDelete(source: URL, before: WatchFileStamp, output: URL) -> Bool {
        guard canonical(source) != canonical(output),
              let after = WatchFileStamp.read(source), before == after,
              let generated = WatchFileStamp.read(output), generated.size > 0,
              (generated.device != after.device || generated.identity != after.identity) else { return false }
        return true
    }
}

#if os(macOS)
struct WatchFolderRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var folderPath: String
    var destinationPath: String
    var folderBookmark: Data
    var destinationBookmark: Data
    var targetFormat: String
    var profiles: [String: FormatProfile] = [:]
    var suffix = "-{action}"
    var deleteOriginal = false
    var includeSubfolders = false
    var enabled = true
}
#endif
