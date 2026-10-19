// Conditional native integration harness. Run with test_watch_folders_mac.sh on macOS.
#if os(macOS)
import Foundation
import AppKit

@main
struct WatchFoldersMacHarness {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WatchHarness-" + UUID().uuidString)
        let sourceFolder = root.appendingPathComponent("in")
        let outputFolder = root.appendingPathComponent("out")
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        rep.setColor(.red, atX: 0, y: 0)
        let source = sourceFolder.appendingPathComponent("sample.tiff")
        try rep.representation(using: .tiff, properties: [:])!.write(to: source)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let watcher = WatchFolders(defaults: defaults)
        let id = try watcher.add(folder: sourceFolder, destination: outputFolder, targetFormat: "png")
        // Output folder is another watched root: PNG must not feed back into TIFF.
        _ = try watcher.add(folder: outputFolder, destination: sourceFolder, targetFormat: "tiff")
        watcher.start()
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let actualOutput = outputFolder.appendingPathComponent(".Margherita Outputs")
        let first = try fm.contentsOfDirectory(at: actualOutput, includingPropertiesForKeys: nil)
        precondition(first.count == 1 && first[0].pathExtension == "png", watcher.status)
        precondition(fm.fileExists(atPath: source.path), "Default must keep source")
        let sourceCount = try fm.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).count
        precondition(sourceCount == 1,
                     "Cross-root output loop")
        watcher.remove(id: id)
        watcher.stop()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try Data([1,2,3]).write(to: sourceFolder.appendingPathComponent("later.tiff"))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let finalCount = try fm.contentsOfDirectory(at: actualOutput, includingPropertiesForKeys: nil).count
        precondition(finalCount == 1)
        print("macOS native FSEvents/bookmark/conversion/loop/stop harness passed")
    }
}
#endif
