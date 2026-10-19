import Foundation
import CryptoKit
import AVFoundation

struct FileStamp: Codable, Equatable {
    var size: Int
    var modified: Date?
    var directory: Bool
    var sha256: String?
    static func manifest(_ url: URL) throws -> [String: FileStamp] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        func stamp(_ item: URL) throws -> FileStamp {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw MargheritaError.message("Refusing to undo an output that contains symbolic links.")
            }
            var digest: String?
            if values.isDirectory != true {
                let handle = try FileHandle(forReadingFrom: item)
                defer { try? handle.close() }
                var hash = SHA256()
                while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
                digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate,
                             directory: values.isDirectory == true, sha256: digest)
        }
        let first = try stamp(url)
        var entries = [".": first]
        if first.directory {
            var enumerationError: Error?
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                    options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
                throw MargheritaError.message("Could not inspect output folder.")
            }
            for case let item as URL in walker {
                let relative = String(item.path.dropFirst(url.path.count + 1))
                entries[relative] = try stamp(item)
            }
            if let enumerationError { throw enumerationError }
        }
        return entries
    }
}

// A durable breadcrumb is written before touching any existing output.
struct RecoveryRecord: Codable {
    var target: URL
    var backup: URL
    var stage: URL
    var installed = false
}

final class ExportLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    func start(_ completion: @escaping @Sendable () -> Void) {
        lock.lock()
        exporter.exportAsynchronously(completionHandler: completion)
        started = true
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { exporter.cancelExport() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let shouldCancel = started; lock.unlock()
        if shouldCancel { exporter.cancelExport() }
    }
}
