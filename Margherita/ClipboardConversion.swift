import AppKit
import Foundation
import UniformTypeIdentifiers

/// A menu probe never reads image bytes or decodes pixels. Finder URLs take
/// precedence over preview images and filenames published alongside them.
struct ClipboardDescriptor {
    var urls: [URL] = []
    var type: NSPasteboard.PasteboardType?
    var ext = ""
    var changeCount: Int

    static func inspect(_ board: NSPasteboard) -> ClipboardDescriptor {
        let version = board.changeCount
        let files = (board.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.isFileURL && $0.fileExists }
        if !files.isEmpty { return ClipboardDescriptor(urls: files, changeCount: version) }
        let preferred: [(String, String)] = [
            ("public.png", "png"), ("public.tiff", "tiff"),
            ("public.heic", "heic"), ("public.heif", "heif"),
            ("public.jpeg", "jpg"), ("com.compuserve.gif", "gif"),
            ("org.webmproject.webp", "webp"), ("public.avif", "avif"),
            ("com.microsoft.bmp", "bmp"), ("com.adobe.pdf", "pdf"),
            ("public.rtf", "rtf"), ("public.html", "html"),
            ("public.utf8-plain-text", "txt"),
            ("public.utf16-external-plain-text", "txt"),
            ("public.utf16-plain-text", "txt")]
        for (name, ext) in preferred {
            let type = NSPasteboard.PasteboardType(name)
            if board.types?.contains(type) == true {
                return ClipboardDescriptor(type: type, ext: ext, changeCount: version)
            }
        }
        return ClipboardDescriptor(changeCount: version)
    }
    var convertible: Bool { !urls.isEmpty || type != nil }
    var routeURLs: [URL] {
        urls.isEmpty ? [URL(fileURLWithPath: "/Clipboard." + ext)] : urls
    }
    var actions: [Action] { convertible ? Action.available(routeURLs) : [] }
}

/// Immutable input bytes are captured only after a menu choice. The private
/// source is staged on the conversion worker, never decoded on the menu thread.
struct ClipboardInput: Sendable {
    let data: Data
    let directory: URL
    let url: URL
    let changeCount: Int
    init(data: Data, ext: String, changeCount: Int) {
        self.data = data
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Margherita-Clipboard-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("Clipboard").appendingPathExtension(ext)
        self.changeCount = changeCount
    }
    func stage() throws {
        try ConversionCancellation.current?.check()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try ConversionCancellation.current?.check()
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class ClipboardConversion: NSObject {
    static let shared = ClipboardConversion()
    private var descriptor = ClipboardDescriptor(changeCount: -1)

    func refresh(_ item: NSMenuItem) {
        descriptor = ClipboardDescriptor.inspect(.general)
        let actions = descriptor.actions
        item.submenu = nil
        item.title = "Convert Clipboard"
        item.isEnabled = !actions.isEmpty && !AppModel.shared.busy
        guard !AppModel.shared.busy else {
            item.title = "Convert Clipboard (conversion in progress)"
            return
        }
        guard !actions.isEmpty else {
            item.title = descriptor.convertible
                ? "Convert Clipboard (no supported formats)" : "Convert Clipboard (nothing convertible)"
            return
        }
        let menu = NSMenu(title: "Convert Clipboard")
        menu.autoenablesItems = false
        for action in actions {
            let child = NSMenuItem(title: action.title, action: #selector(convert(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = action.rawValue
            menu.addItem(child)
        }
        item.submenu = menu
    }

    @objc private func convert(_ sender: NSMenuItem) {
        guard !AppModel.shared.busy else { return }
        let board = NSPasteboard.general
        guard board.changeCount == descriptor.changeCount else {
            ConversionHUD.shared.fail("The clipboard changed. Open the menu again to choose a format.")
            return
        }
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw),
              descriptor.actions.contains(action) else { return }
        if !descriptor.urls.isEmpty {
            AppModel.shared.run(action, urls: descriptor.urls)
            return
        }
        guard let type = descriptor.type else { return }
        // Normalize text to UTF-8 so UTF-16 clipboard providers also use the
        // existing TXT conversion routes without guessing a file encoding.
        let bytes: Data?
        if descriptor.ext == "txt", let text = board.string(forType: type) {
            bytes = text.data(using: .utf8)
        } else {
            bytes = board.data(forType: type)
        }
        guard let data = bytes, !data.isEmpty, board.changeCount == descriptor.changeCount else {
            ConversionHUD.shared.fail("Could not read the clipboard. Copy the content again and retry.")
            return
        }
        let input = ClipboardInput(data: data, ext: descriptor.ext, changeCount: board.changeCount)
        AppModel.shared.run(action, urls: [input.url], clipboard: input)
    }

    /// Read encoded output without expanding a large image to a bitmap.
    nonisolated static func resultData(_ outputs: [URL]) -> (Data, String)? {
        guard outputs.count == 1, let url = outputs.first,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .text),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (data, type.identifier)
    }
    static func publish(_ result: (Data, String)?, changeCount: Int) {
        let board = NSPasteboard.general
        // Never overwrite something the user copied while conversion ran.
        guard board.changeCount == changeCount, let (data, identifier) = result else { return }
        board.clearContents()
        board.setData(data, forType: NSPasteboard.PasteboardType(identifier))
    }
}
