import AppKit
import SwiftUI
import ApplicationServices

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var wheel: WheelView?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastDragCount = -1
    private var dragStartCount = -1
    private var dragActive = false
    private var dismissTimer: Timer?
    private var previewURLs: [URL] = []
    private var heldKeys: Set<UInt16> = []

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event); return event
        }
    }
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        dismissTimer?.invalidate(); panel?.orderOut(nil)
    }
    /// Drops keys the system no longer reports as down (missed keyUp events). CGEventSource.keyState is a cheap non-blocking read.
    private func pruneHeldKeys() {
        heldKeys = heldKeys.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
    }
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { hide(); return }
            if !event.isARepeat { heldKeys.insert(event.keyCode) }
        case .keyUp:
            heldKeys.remove(event.keyCode)
        case .flagsChanged:
            pruneHeldKeys()
        default: break
        }
        if event.type == .leftMouseDown {
            dragActive = false
            dragStartCount = NSPasteboard(name: .drag).changeCount
            hide(); return
        }
        if event.type == .leftMouseUp {
            // Drag destinations must receive performDragOperation before this panel disappears.
            dismissTimer?.invalidate()
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
            return
        }
        if event.type == .leftMouseDragged { dragActive = true }
        guard dragActive, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        // Ignore stale drag pasteboards left behind by a previous Finder drag.
        guard pasteboard.changeCount != dragStartCount else { return }
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mode = Preferences.shared.dragMode(modifiers: flags, pressedKeys: heldKeys)
        let visible = panel?.isVisible == true
        if !visible || pasteboard.changeCount != lastDragCount {
            // A new wheel needs a live trigger; an open wheel keeps its mode once released.
            guard let mode else { return }
            previewURLs = urls; lastDragCount = pasteboard.changeCount
            show(urls, mode: mode)
        } else if let mode, let wheel {
            if wheel.mode != mode { wheel.setMode(mode, urls: previewURLs) }
        }
    }
    private func show(_ urls: [URL], mode: Preferences.DragMode) {
        dismissTimer?.invalidate()
        let prefs = Preferences.shared
        let size = max(320, min(460, prefs.overlaySize))
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        let window = panel ?? NSPanel(contentRect: frame,
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        window.isFloatingPanel = true; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear; window.isOpaque = false
        window.hasShadow = false; window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        let content = NSView(frame: frame)
        content.wantsLayer = true
        let view = WheelView(frame: frame)
        view.urls = urls; view.setMode(mode, urls: urls)
        view.didDrop = { [weak self] payload, urls in
            self?.hide()
            // Let Finder finish its drag session before opening native dialogs/windows.
            DispatchQueue.main.async {
                switch payload {
                case .convert(let action): AppModel.shared.run(action, urls: urls)
                case .file(let action): FileActionController.shared.perform(action, urls: urls)
                }
            }
        }
        // SwiftUI face underneath; the transparent WheelView on top owns drag destination and hit testing.
        let face = TransparentWheelHostingView(rootView: WheelFaceView(model: view.model))
        face.frame = frame
        content.addSubview(face); content.addSubview(view); window.contentView = content
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = pointer.x - size / 2
        if prefs.overlayPosition == "right" { x = pointer.x + 18 }
        if prefs.overlayPosition == "left" { x = pointer.x - size - 18 }
        let origin = NSPoint(x: min(max(x, available.minX), available.maxX - size),
                             y: min(max(pointer.y - size / 2, available.minY), available.maxY - size))
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true)
        window.alphaValue = 0; window.orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { window.alphaValue = 1 }
        else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16; window.animator().alphaValue = 1
            }
            if let layer = content.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.position = CGPoint(x: size / 2, y: size / 2)
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.88; pop.toValue = 1; pop.damping = 14; pop.stiffness = 220; pop.mass = 0.8
                pop.duration = pop.settlingDuration
                layer.add(pop, forKey: "pop")
            }
        }
        wheel = view; panel = window
    }
    private func hide() { panel?.orderOut(nil); dragActive = false; previewURLs = [] }
}

/// What a wheel sector does when dropped on.
enum WheelPayload {
    case convert(Action)
    case file(FileAction)
}

struct WheelItem: Identifiable, Equatable {
    var id: Int
    var label: String
    var symbol: String?
    static func == (a: WheelItem, b: WheelItem) -> Bool { a.id == b.id && a.label == b.label && a.symbol == b.symbol }
}

/// Presentation-only label layout. Never change payload titles or the shared hit geometry.
enum WheelLabelLayout {
    static func text(_ label: String) -> String {
        let words = label.uppercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 1 else { return label.uppercased() }
        // Balance at a word boundary, including titles with more than two words.
        var split = 1
        var bestDifference = Int.max
        for boundary in 1..<words.count {
            let left = words[..<boundary].joined(separator: " ").count
            let right = words[boundary...].joined(separator: " ").count
            let difference = abs(left - right)
            if difference < bestDifference {
                split = boundary
                bestDifference = difference
            }
        }
        return words[..<split].joined(separator: " ") + "\n" + words[split...].joined(separator: " ")
    }

    static func bounds(inner: CGFloat, outer: CGFloat, lo: CGFloat, hi: CGFloat, gap: CGFloat) -> CGSize {
        let radius = (inner + outer) / 2
        let halfAngle = max(0, (hi - lo) / 2 - gap / (2 * max(1, radius)))
        // A circle at the sector midpoint stays inside both arcs and both radial edges.
        // Inscribe a horizontal 4:3 rectangle in it, with breathing room for rounded corners.
        let clearance = max(0, min((outer - inner) / 2,
                                  radius * sin(min(.pi / 2, halfAngle))) - 4)
        return CGSize(width: clearance * 1.6, height: clearance * 1.2)
    }
}

/// Observable state shared between the AppKit drop view and the SwiftUI face.
@MainActor
final class WheelModel: ObservableObject {
    @Published var items: [WheelItem] = []
    @Published var highlighted: Int?
    @Published var page = 0
    @Published var sizeText = ""
    @Published var modeTitle = "CONVERT TO"
    @Published var showIcons = false
    var geometry: WheelGeometry { WheelGeometry(count: items.count, page: page, size: side) }
    var side: CGFloat = 360
}

/// Margherita wheel palette: wood-fired dark, cream text, tomato accent (accent itself comes from Preferences).
enum WheelPalette {
    static let ovenDark = Color.woodFired
    static let oven = Color(red: 0.22, green: 0.16, blue: 0.13)
    static let crust = Color(red: 0.30, green: 0.22, blue: 0.17)
    static let cream = Color.mozzarella
    static let parchment = Color(red: 0.97, green: 0.93, blue: 0.85)
    static let flour = Color(red: 0.90, green: 0.85, blue: 0.76)
    static let basil = Color.basil
    static let tomato = Color.margherita
}

/// Keep the hosting surface transparent so the native backdrop can sample the desktop.
final class TransparentWheelHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// Mask the effect in AppKit, not with SwiftUI clipShape/compositingGroup.
/// A SwiftUI offscreen mask can flatten the native backdrop into an opaque texture.
final class CircularWheelEffectView: NSVisualEffectView {
    override var isOpaque: Bool { false }
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: bounds.size)).fill()
        image.unlockFocus()
        maskImage = image
    }
}

struct BlurBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> CircularWheelEffectView {
        let v = CircularWheelEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active; v.isEmphasized = false
        return v
    }
    func updateNSView(_ v: CircularWheelEffectView, context: Context) { v.material = material }
}

/// Glass legibility constants; Tests/test_v10_glass.py checks them against a pure white backdrop.
enum WheelContrast {
    static let backing = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let discBackingAlpha = 0.58
    static let sectorBackingAlpha = 0.22
    static let hubBackingAlpha = 0.45
    static let hoverAccentAlpha = 0.80
    static let hoverShadeAlpha = 0.52 // darkens even a pure yellow accent
}

struct WheelFaceView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject private var prefs = Preferences.shared
    private var accent: Color { prefs.color }
    private var glass: Bool { prefs.wheelStyle != "solid" }
    private let cream = WheelPalette.cream

    var body: some View {
        let g = model.geometry
        let side = g.size
        ZStack {
            disc(g)
            ForEach(g.sectors, id: \.index) { s in
                if model.items.indices.contains(s.index) {
                    sectorView(s, g: g, item: model.items[s.index])
                }
            }
            hub(g)
        }
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.12), value: model.highlighted)
    }

    @ViewBuilder private func disc(_ g: WheelGeometry) -> some View {
        let d = g.discRadius * 2
        ZStack {
            if glass {
                // One native backdrop only. Stacking a blur per slice hides the translucency.
                BlurBackdrop(material: .hudWindow)
                Circle().fill(WheelContrast.backing.opacity(WheelContrast.discBackingAlpha))
                Circle().fill(LinearGradient(
                    colors: [.white.opacity(0.10), .clear, .black.opacity(0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.85), .white.opacity(0.06), .white.opacity(0.30)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.4)
            } else {
                Circle().fill(WheelPalette.ovenDark)
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .frame(width: d, height: d)
        // No shadow/compositing modifier around the NSVisualEffectView.
    }

    @ViewBuilder private func sectorView(_ s: WheelGeometry.Sector, g: WheelGeometry, item: WheelItem) -> some View {
        let on = model.highlighted == s.index
        let shape = WheelSectorShape(geometry: g, sector: s, grow: on ? 2.5 : 0)
        let rad = s.midRadius
        let pos = CGPoint(x: g.size / 2 + rad * cos(s.mid), y: g.size / 2 - rad * sin(s.mid))
        ZStack {
            Group {
                if on {
                    if glass { shape.fill(WheelContrast.backing.opacity(WheelContrast.sectorBackingAlpha)) }
                    shape.fill(accent.opacity(glass ? WheelContrast.hoverAccentAlpha : 1))
                    if glass { shape.fill(WheelContrast.backing.opacity(WheelContrast.hoverShadeAlpha)) }
                } else if glass {
                    shape.fill(LinearGradient(
                        colors: [WheelContrast.backing.opacity(WheelContrast.sectorBackingAlpha), WheelPalette.cream.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom))
                } else {
                    // Solid is intentionally opaque and flat, not a second glass treatment.
                    shape.fill(WheelPalette.oven)
                }
            }
            if glass {
                // Polished top rim and a gentle inner reflection over the native blur.
                shape.stroke(LinearGradient(
                    colors: [.white.opacity(on ? 0.90 : 0.65), .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
            } else {
                shape.stroke(Color.white.opacity(0.10), lineWidth: 0.8)
            }
            let small = g.ringCount > 1
            let labelBounds = WheelLabelLayout.bounds(inner: s.innerRadius, outer: s.outerRadius,
                                                      lo: s.lo, hi: s.hi, gap: g.gap)
            let hasIcon = model.showIcons && item.symbol != nil
            let iconSize = min(small ? 10.0 : 16.0, labelBounds.height * 0.30)
            let spacing: CGFloat = hasIcon ? 2 : 0
            let textHeight = max(0, labelBounds.height - (hasIcon ? iconSize + spacing : 0))
            VStack(spacing: spacing) {
                if hasIcon, let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold))
                        .frame(height: iconSize)
                }
                Text(WheelLabelLayout.text(item.label))
                    .font(.system(size: min(small ? 9 : (item.label.count > 5 ? 10.5 : 13),
                                            textHeight / 2.4), weight: .bold))
                    .lineLimit(2).minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
                    .frame(width: max(0, labelBounds.width - 4), height: textHeight)
                    .padding(.horizontal, 2)
            }
            .foregroundColor(glass ? .white : cream)
            .shadow(color: .black.opacity(0.85), radius: 1.5, x: 0, y: 0.5)
            .shadow(color: .black.opacity(0.55), radius: 3.5, x: 0, y: 1)
            .frame(width: labelBounds.width, height: labelBounds.height)
            .clipped()
            .accessibilityLabel(item.label)
            .position(pos)
        }
        .frame(width: g.size, height: g.size)
    }

    private func hub(_ g: WheelGeometry) -> some View {
        let hover = model.highlighted.flatMap { model.items.indices.contains($0) ? model.items[$0].label.uppercased() : nil }
        var text = hover ?? model.sizeText
        if hover == nil, g.pageCount > 1 { text = String(model.page + 1) + "/" + String(g.pageCount) }
        let d = g.hubRadius * 2 - g.gap * 2
        return ZStack {
            Circle().fill(glass ? WheelContrast.backing.opacity(WheelContrast.hubBackingAlpha) : WheelPalette.ovenDark)
                .frame(width: d, height: d)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
            VStack(spacing: 3) {
                Text(model.modeTitle)
                    .font(.system(size: 7.5, weight: .bold)).tracking(0.5).foregroundColor(glass ? Color.white.opacity(0.85) : cream.opacity(0.6))
                    .shadow(color: .black.opacity(0.8), radius: 1.5)
                Text(text)
                    .font(.system(size: g.ringCount > 1 ? 9 : 11, weight: .semibold))
                    .foregroundColor(glass ? .white : cream)
                    .shadow(color: .black.opacity(0.85), radius: 1.5)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(glass ? Color.black.opacity(0.35) : Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .frame(width: g.hubRadius * 1.7)
        }
    }
}

@MainActor
final class WheelView: NSView {
    let model = WheelModel()
    var urls: [URL] = []
    private(set) var mode: Preferences.DragMode = .convert
    private var payloads: [WheelPayload] = []
    var didDrop: ((WheelPayload, [URL]) -> Void)?
    private var lastPageFlip = Date.distantPast
    private var geometry: WheelGeometry { WheelGeometry(count: payloads.count, page: model.page, size: bounds.width) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); registerForDraggedTypes([.fileURL])
        model.side = frameRect.width
        setAccessibilityLabel("Margherita wheel. Drop onto an option.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}

    func setMode(_ mode: Preferences.DragMode, urls: [URL]) {
        self.mode = mode
        model.side = bounds.width > 0 ? bounds.width : model.side
        model.page = 0; model.highlighted = nil
        switch mode {
        case .convert, .tools:
            let list = Action.available(urls, advanced: mode == .tools)
            payloads = list.map { .convert($0) }
            model.items = list.enumerated().map { WheelItem(id: $0.offset, label: $0.element.title, symbol: mode == .tools ? $0.element.symbol : nil) }
            model.showIcons = mode == .tools
            model.modeTitle = mode == .tools ? "FILE TOOLS" : "CONVERT TO"
        case .actions:
            let list = Array(FileAction.allCases)
            payloads = list.map { .file($0) }
            model.items = list.enumerated().map { WheelItem(id: $0.offset, label: $0.element.title, symbol: $0.element.symbol) }
            model.showIcons = true; model.modeTitle = "ACTIONS"
        }
        let total = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        model.sizeText = urls.count > 1 ? String(urls.count) + " files" : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { model.highlighted = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { index(at: sender.draggingLocation) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = index(at: sender.draggingLocation), payloads.indices.contains(i),
              let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty else { return false }
        let payload = payloads[i]
        if case .convert(let action) = payload, !Action.available(files, advanced: mode == .tools).contains(action) { return false }
        SoundEffects.play(.drop)
        didDrop?(payload, files); return true
    }
    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = convert(info.draggingLocation, from: nil)
        let current = geometry
        // Hovering the hub flips pages when there are more than 18 choices.
        if current.pageCount > 1, current.inHub(p), Date().timeIntervalSince(lastPageFlip) > 0.7 {
            lastPageFlip = Date(); model.page = (model.page + 1) % current.pageCount
            model.highlighted = nil; SoundEffects.play(.hover)
            return []
        }
        let hit = index(at: info.draggingLocation)
        if hit != model.highlighted {
            model.highlighted = hit
            if hit != nil { SoundEffects.play(.hover) }
        }
        return hit == nil ? [] : .copy
    }
    private func index(at windowPoint: NSPoint) -> Int? {
        let p = convert(windowPoint, from: nil)
        guard let i = geometry.sectorIndex(at: p), payloads.indices.contains(i) else { return nil }
        return i
    }
}
