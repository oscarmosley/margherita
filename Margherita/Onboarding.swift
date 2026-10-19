import SwiftUI
import AppKit

// MARK: - Controller

private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    private(set) var window: NSWindow?
    var onClose: (() -> Void)?
    private var model = OnboardingModel()

    func show() {
        // Accessory apps must become regular before a key onboarding window is shown.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if let w = window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        model = OnboardingModel()
        model.close = { [weak self] in DispatchQueue.main.async { self?.window?.close() } }
        model.minimize = { [weak self] in DispatchQueue.main.async { self?.window?.miniaturize(nil) } }
        model.finish = { [weak self] in
            DispatchQueue.main.async { self?.window?.close() }
        }
        let size = NSSize(width: 800, height: 440)
        let w = OnboardingWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .miniaturizable, .closable],
                                 backing: .buffered, defer: false)
        w.isRestorable = false
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.title = "Getting Started"
        w.delegate = self
        let host = NSHostingView(rootView: OnboardingRoot(model: model, prefs: Preferences.shared, folders: FolderAccess.shared))
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layer?.cornerRadius = OnboardingChrome.cornerRadius // same arc as the buttons
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        w.contentView = host
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.invalidateShadow()
    }

    private var retired: [NSWindow] = []
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // UserDefaults belongs to the bundle identifier, not the downloaded app.
        // Redownloading preserves completion; manual replay never needs a reset.
        model.converterWheel.stop()
        model.actionsWheel.stop()
        // Completion means the user dismissed or finished setup, never merely saw it.
        UserDefaults.standard.set(true, forKey: "onboardingCompletedV2")
        // Keep the window (and its hosting view) alive until button callbacks have unwound.
        if let w = window { retired.append(w); w.delegate = nil }
        window = nil
        // The closing window can still report isVisible inside this delegate callback.
        // Drop ownership first, then restore policy after AppKit completes the close.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.retired.forEach { $0.contentView = nil }
            self?.retired.removeAll()
        }
    }
}

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    static let pageCount = 5
    @Published var page = 0
    @Published var forward = true
    /// Owned here so SwiftUI re-renders never recreate the wheels or their timers.
    let converterWheel = WheelState(labels: ["PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF"])
    let actionsWheel = WheelState(labels: ["AIRDROP", "FLOAT", "COPY", "MOVE", "COPY PATH", "TERMINAL"],
                                  symbols: ["dot.radiowaves.left.and.right", "pin.fill", "doc.on.doc", "folder", "doc.text", "terminal"], title: "ACTIONS")
    var close: () -> Void = {}
    var minimize: () -> Void = {}
    var finish: () -> Void = {}
    func next() { guard page < Self.pageCount - 1 else { finish(); return }; forward = true; withAnimation(anim) { page += 1 } }
    func back() { guard page > 0 else { return }; forward = false; withAnimation(anim) { page -= 1 } }
    var anim: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.82)
    }
}

private let reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - Root

struct OnboardingRoot: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var folders: FolderAccess

    var body: some View { content }

    private var accent: Color { prefs.color }

    private var content: some View {
        ZStack {
            if model.page == 0 {
                ZStack {
                    LinearGradient(colors: [WheelPalette.tomato, Color(red: 0.62, green: 0.13, blue: 0.11), WheelPalette.ovenDark], startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [WheelPalette.cream.opacity(0.55), WheelPalette.cream.opacity(0)], center: UnitPoint(x: 0.5, y: 0.78), startRadius: 4, endRadius: 360)
                    RadialGradient(colors: [WheelPalette.basil.opacity(0.7), WheelPalette.basil.opacity(0)], center: UnitPoint(x: 0.92, y: 0.05), startRadius: 4, endRadius: 300)
                }
                    .transition(.opacity)
            } else {
                WheelPalette.ovenDark.transition(.opacity)
            }
            ZStack {
                pageView.id(model.page)
                    .transition(.asymmetric(
                        insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .clipped()
            VStack { Spacer(); if model.page > 0 { dots.padding(.bottom, 22) } }
            VStack { HStack { TrafficLights(model: model); Spacer(minLength: 0) }; Spacer(minLength: 0) }
            KeyCatcher(left: { model.back() }, right: { model.next() }, enter: { model.next() })
                .frame(width: 0, height: 0)
        }
        .frame(width: 800, height: 440)
        .animation(model.anim, value: model.page)
    }

    @ViewBuilder private var pageView: some View {
        switch model.page {
        case 0: welcome
        case 1: converter
        case 2: actions
        case 3: folder
        default: finishPage
        }
    }

    private var dots: some View {
        HStack(spacing: 9) {
            ForEach(0..<OnboardingModel.pageCount, id: \.self) { i in
                Capsule().fill(i == model.page ? accent : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(model.anim, value: model.page)
        .accessibilityHidden(true)
    }

    // MARK: pages
    private var welcome: some View {
        VStack(spacing: 6) {
            Text("Welcome to").font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.78))
            Text("Margherita").font(.system(size: 84, weight: .bold)).foregroundStyle(.white.opacity(0.86))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            Button(action: model.next) {
                Text("Continue").font(.system(size: 16, weight: .semibold)).foregroundStyle(WheelPalette.tomato)
                    .padding(.horizontal, 50).padding(.vertical, 13).background(Capsule().fill(WheelPalette.cream))
            }.buttonStyle(.plain).padding(.top, 22)
        }
    }

    private func side<Content: View>(_ title: String, @ViewBuilder _ body: () -> Content, cta: String = "Continue") -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: model.back) {
                HStack(spacing: 4) { Image(systemName: "arrow.left"); Text("Back") }
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }.buttonStyle(.plain)
            Text(title).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
            body()
            Spacer(minLength: 0)
            Button(action: model.next) {
                Text(cta).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12).background(Capsule().fill(accent))
            }.buttonStyle(.plain)
        }
        .padding(.top, 84).padding(.bottom, 56)
    }

    private func steps(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Drag files").font(.system(size: 17)).foregroundStyle(.white)
            HStack(spacing: 7) { Text("2. Hold").font(.system(size: 17)).foregroundStyle(.white); KeyCap(text: key) }
        }
    }

    private var converter: some View {
        HStack(spacing: 30) {
            DemoWheel(st: model.converterWheel).frame(width: 270, height: 270)
            side("File Converter") { steps(prefs.triggerLabel) }.frame(width: 230)
        }.padding(.leading, 135).padding(.trailing, 135)
    }

    private var actions: some View {
        HStack(spacing: 30) {
            DemoWheel(st: model.actionsWheel).frame(width: 270, height: 270)
            side("File Actions") { steps(prefs.actionsShortcut.display) }.frame(width: 230)
        }.padding(.leading, 135).padding(.trailing, 135)
    }

    private var folder: some View {
        HStack(spacing: 30) {
            VStack(spacing: 14) {
                ZStack {
                    FolderSilhouette()
                        .fill(LinearGradient(
                            colors: [WheelPalette.tomato, Color(red: 0.62, green: 0.13, blue: 0.11)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(FolderSilhouette().stroke(WheelPalette.cream.opacity(0.22), lineWidth: 1))
                        .shadow(color: WheelPalette.tomato.opacity(0.20), radius: 18, y: 8)
                    Image(systemName: "house.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(WheelPalette.cream)
                        .offset(y: 8)
                }
                .frame(width: 154, height: 120)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
                if folders.homeEnabled {
                    Text("Home folder access enabled").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    Text("Manage access in Settings \u{2192} Permissions.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                } else {
                    Button("Allow home folder\u{2026}") { folders.grantHomeAccess() }
                        .buttonStyle(.plain).font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 16).padding(.vertical, 8).background(Capsule().fill(Color.white.opacity(0.08)))
                    Text("Manage access in Settings \u{2192} Permissions.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
            }.frame(width: 250)
            side("Folder access") {
                Text("Remember access to your home folder for conversions. You can manage saved access in Settings \u{2192} Permissions.")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 240)
        }.padding(.leading, 135).padding(.trailing, 135)
    }

    private var finishPage: some View {
        HStack(spacing: 30) {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "wifi").foregroundStyle(.white.opacity(0.7)).frame(height: 24)
                    Image(nsImage: AppDelegate.pizzaMenuBarIcon()).renderingMode(.template).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent.opacity(0.6)))
                        .overlay(alignment: .bottom) {
                            Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(WheelPalette.cream)
                                .fixedSize().offset(y: 26)
                        }
                    Text("9:41").foregroundStyle(.white.opacity(0.8)).frame(height: 24)
                }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                    .padding(.bottom, 24)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Launch at login").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text("Ready whenever you turn on your Mac.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        if !prefs.loginError.isEmpty { Text(prefs.loginError).font(.system(size: 11)).foregroundStyle(accent) }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { prefs.loginEnabled }, set: { prefs.setLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(accent)
                }.padding(14).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
            }.frame(width: 260)
            VStack(alignment: .leading, spacing: 14) {
                Button(action: model.back) {
                    HStack(spacing: 4) { Image(systemName: "arrow.left"); Text("Back") }.font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }.buttonStyle(.plain)
                Text("Finish setup").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Choose whether Margherita launches at login. You can change these options and your shortcuts in Settings.")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: model.finish) {
                    Text("Done").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12).background(Capsule().fill(accent))
                }.buttonStyle(.plain)
            }.padding(.top, 84).padding(.bottom, 56).frame(width: 240)
        }.padding(.leading, 135).padding(.trailing, 135)
    }
}

/// One continuous outline keeps the tab and body visually connected.
private struct FolderSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: w * 0.10, y: 0))
        p.addLine(to: CGPoint(x: w * 0.36, y: 0))
        p.addQuadCurve(to: CGPoint(x: w * 0.44, y: h * 0.05),
                       control: CGPoint(x: w * 0.41, y: 0))
        p.addLine(to: CGPoint(x: w * 0.53, y: h * 0.16))
        p.addLine(to: CGPoint(x: w * 0.90, y: h * 0.16))
        p.addQuadCurve(to: CGPoint(x: w, y: h * 0.29),
                       control: CGPoint(x: w, y: h * 0.16))
        p.addLine(to: CGPoint(x: w, y: h * 0.87))
        p.addQuadCurve(to: CGPoint(x: w * 0.90, y: h),
                       control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w * 0.10, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h * 0.87),
                       control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.13))
        p.addQuadCurve(to: CGPoint(x: w * 0.10, y: 0),
                       control: .zero)
        p.closeSubpath()
        return p
    }
}

// MARK: - Pieces

/// Button centres share a concentric arc with the stadium's top-left corner.
/// A 19pt clearance from each button's edge keeps all three equally inset.
enum OnboardingChrome {
    static let cornerRadius: CGFloat = 220
    static let buttonDiameter: CGFloat = 13
    static let edgeInset: CGFloat = 19
    static let buttonPitch: CGFloat = 21
    static func centre(_ index: Int) -> CGPoint {
        let radius = cornerRadius - edgeInset - buttonDiameter / 2
        let step = 2 * asin(buttonPitch / (2 * radius))
        let angle = -3 * CGFloat.pi / 4 + CGFloat(index) * step
        return CGPoint(x: cornerRadius + radius * cos(angle),
                       y: cornerRadius + radius * sin(angle))
    }
}

struct TrafficLights: View {
    let model: OnboardingModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            light(Color(red: 1, green: 0.37, blue: 0.34), "Close", model.close)
                .position(OnboardingChrome.centre(0))
            light(Color(red: 1, green: 0.74, blue: 0.18), "Minimize", model.minimize)
                .position(OnboardingChrome.centre(1))
            light(Color(red: 0.16, green: 0.78, blue: 0.25), "Zoom (unavailable)", {})
                .position(OnboardingChrome.centre(2))
        }
        .frame(width: 145, height: 105, alignment: .topLeading)
    }
    private func light(_ c: Color, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Circle().fill(c).frame(width: OnboardingChrome.buttonDiameter, height: OnboardingChrome.buttonDiameter)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: 0.75))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5).padding(0.5))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// Small inline keycap, about the height of the 17pt line beside it.
struct KeyCap: View {
    let text: String
    var body: some View {
        let words = text.lowercased()
        let glyphs = ["shift": "\u{21E7}", "control": "\u{2303}", "option": "\u{2325}", "command": "\u{2318}"]
        let glyph = glyphs.first(where: { words.contains($0.key) })?.value ?? ""
        HStack(spacing: 4) {
            if !glyph.isEmpty { Text(glyph).font(.system(size: 13, weight: .medium)) }
            Text(words).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(WheelPalette.cream)
        .padding(.horizontal, 8).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WheelPalette.crust))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.5), radius: 0, y: 1.5)
        .fixedSize()
    }
}

/// Demo wheel: the real WheelFaceView driven by a scripted WheelModel.
struct DemoWheel: View {
    @ObservedObject var st: WheelState
    var body: some View {
        WheelFaceView(model: st.model)
            .overlay(alignment: .top) {
                HStack(spacing: 7) {
                    Image(systemName: "photo").foregroundStyle(WheelPalette.cream.opacity(0.8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("photo.jpg").font(.system(size: 10, weight: .semibold))
                        Text("JPEG image \u{00B7} 2.4 MB").font(.system(size: 8)).foregroundStyle(WheelPalette.cream.opacity(0.55))
                    }.foregroundStyle(WheelPalette.cream)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(WheelPalette.oven))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                .offset(y: -40)
            }
            .scaleEffect(st.appeared ? 1 : 0.85)
            .opacity(st.appeared ? 1 : 0)
            .animation(reduceMotion() ? nil : .spring(response: 0.45, dampingFraction: 0.75), value: st.appeared)
            .onAppear { st.start() }
            .onDisappear { st.stop() }
            .accessibilityHidden(true)
    }
}

// Keyboard: left/right arrows and return.
struct KeyCatcher: NSViewRepresentable {
    let left: () -> Void, right: () -> Void, enter: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyView(); v.left = left; v.right = right; v.enter = enter; return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        guard let k = v as? KeyView else { return }
        k.left = left; k.right = right; k.enter = enter
    }
    final class KeyView: NSView {
        var left: () -> Void = {}, right: () -> Void = {}, enter: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) } }
        override func keyDown(with e: NSEvent) {
            switch e.keyCode {
            case 123: left()
            case 124, 36, 76: if e.keyCode == 124 { right() } else { enter() }
            default: super.keyDown(with: e)
            }
        }
    }
}

@MainActor
final class WheelState: ObservableObject {
    @Published var appeared = false
    let model = WheelModel()
    private var timer: Timer?
    init(labels: [String] = [], symbols: [String]? = nil, title: String = "CONVERT TO", size: CGFloat = 270) {
        model.side = size
        model.modeTitle = title
        model.sizeText = "2.4 MB"
        model.showIcons = symbols != nil
        model.items = labels.enumerated().map { WheelItem(id: $0.offset, label: $0.element, symbol: symbols?[$0.offset]) }
        model.highlighted = nil
    }
    func start() {
        appeared = true
        guard timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let n = max(self.model.items.count, 1)
                self.model.highlighted = ((self.model.highlighted ?? -1) + 1) % n
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}
