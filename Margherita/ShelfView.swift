import AppKit

private let shelfType = NSPasteboard.PasteboardType("margherita.shelf.item")

/// Root (`shared`) dispatches Float actions into retained child shelves; each child owns one panel.
@MainActor
final class ShelfController: NSObject, NSWindowDelegate {
    static let shared = ShelfController(isRoot: true)
    private let isRoot: Bool
    private var children: [ShelfController] = []
    private weak var parent: ShelfController?
    private var panel: NSPanel?
    private var list: ShelfListView?
    private(set) var items: [URL] = []

    private init(isRoot: Bool) { self.isRoot = isRoot; super.init() }

    /// Public entry used by FileActionController. "new" opens an independent shelf; "reuse" adds to the most recent live one.
    func add(_ urls: [URL]) {
        guard isRoot else { addHere(urls); return }
        guard !urls.isEmpty else { return }
        if Preferences.shared.floatBehaviour == "reuse", let last = children.last {
            last.addHere(urls)
        } else {
            let child = ShelfController(isRoot: false)
            child.parent = self
            children.append(child)
            child.addHere(urls)
        }
    }

    private func addHere(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        show()
        list?.reload(items)
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        list?.reload(items)
        if items.isEmpty { close() }
    }

    func clear() {
        items.removeAll()
        list?.reload(items)
        close()
    }

    /// Closes the panel and releases it; only shelf references are dropped, never files.
    private func close() {
        guard !isRoot else { return }
        let p = panel
        panel = nil; list = nil
        p?.delegate = nil
        p?.orderOut(nil)
        DispatchQueue.main.async { p?.contentView = nil }
        items.removeAll()
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !isRoot, let p = panel, notification.object as? NSPanel === p else { return }
        panel = nil; list = nil
        p.delegate = nil
        items.removeAll()
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 320),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.title = "Shelf"
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.delegate = self
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            let l = ShelfListView(frame: p.contentView!.bounds)
            l.autoresizingMask = [.width, .height]
            l.onRemove = { [weak self] in self?.remove($0) }
            l.onClear = { [weak self] in self?.clear() }
            l.onDrop = { [weak self] in self?.addHere($0) }
            l.onPin = { [weak self] in self?.pin(left: $0) }
            p.contentView?.addSubview(l)
            panel = p
            list = l
            // Cascade so independent shelves don't stack exactly on top of each other.
            let index = max(0, (parent?.children.firstIndex { $0 === self } ?? 0) % 6)
            if let f = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 8 - CGFloat(index) * 26,
                                         y: f.midY - p.frame.height / 2 - CGFloat(index) * 26))
            }
        }
        panel?.orderFrontRegardless()
    }

    func pin(left: Bool) {
        guard let p = panel, let f = (p.screen ?? NSScreen.main)?.visibleFrame else { return }
        let x = left ? f.minX + 8 : f.maxX - p.frame.width - 8
        p.setFrame(NSRect(x: x, y: p.frame.minY, width: p.frame.width, height: p.frame.height), display: true, animate: true)
    }
}

final class ShelfListView: NSView {
    var onRemove: ((URL) -> Void)?
    var onClear: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onPin: ((Bool) -> Void)?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let bar = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        let fx = NSVisualEffectView(frame: bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        addSubview(fx)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let left = NSButton(title: "◀", target: self, action: #selector(pinLeft))
        let right = NSButton(title: "▶", target: self, action: #selector(pinRight))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        [left, right, clear].forEach { $0.bezelStyle = .inline }
        left.setAccessibilityLabel("Pin shelf to left edge")
        right.setAccessibilityLabel("Pin shelf to right edge")
        clear.setAccessibilityLabel("Clear shelf, files are not deleted")
        left.toolTip = "Pin to left edge"; right.toolTip = "Pin to right edge"
        bar.setViews([left, right, clear], in: .leading)
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pinLeft() { onPin?(true) }
    @objc private func pinRight() { onPin?(false) }
    @objc private func clearAll() { onClear?() }

    func reload(_ urls: [URL]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for u in urls {
            let row = ShelfRow(url: u)
            row.onRemove = { [weak self] in self?.onRemove?($0) }
            stack.addArrangedSubview(row)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
              options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ShelfRow: NSView, NSDraggingSource {
    let url: URL
    var onRemove: ((URL) -> Void)?

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        let x = NSButton(title: "✕", target: self, action: #selector(removeMe))
        x.isBordered = false
        x.setAccessibilityLabel("Remove " + url.lastPathComponent + " from shelf")
        x.toolTip = "Remove from shelf"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(url.lastPathComponent)
        let row = NSStackView(views: [icon, label, x])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 36), widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeMe() { onRemove?(url) }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
