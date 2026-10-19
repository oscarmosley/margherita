import SwiftUI
import AppKit
import Combine

enum HUDPhase { case progress, success, failure }

@MainActor
final class HUDState: ObservableObject {
    @Published var phase: HUDPhase = .progress
    @Published var progress: Double = 0
    @Published var text: String = ""
    @Published var detail: String? = nil
    @Published var cancelling = false
    var onDetails: (() -> Void)?
    var onCancel: (() -> Void)?
}

struct ConversionHUDView: View {
    @ObservedObject var state: HUDState
    private let tomato = Color(red: 0.93, green: 0.30, blue: 0.20)
    private let basil = Color(red: 0.36, green: 0.74, blue: 0.40)
    var body: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 5) {
                Text(state.text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                if state.phase == .progress { bar }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 190, maxWidth: 300, alignment: .leading)
        .background(background)
    }
    @ViewBuilder private var trailing: some View {
        if state.phase == .progress {
            if state.cancelling {
                EmptyView()
            } else {
                Button(action: { state.onCancel?() }) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        } else if state.phase == .failure && state.detail != nil {
            Button(action: { state.onDetails?() }) {
                Text("Details")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
    }
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape.fill(.regularMaterial).overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
    @ViewBuilder private var badge: some View {
        switch state.phase {
        case .progress:
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .bold)).foregroundColor(tomato)
        case .success:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .bold)).foregroundColor(basil)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16, weight: .bold)).foregroundColor(tomato)
        }
    }
    private var bar: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(min(max(state.progress, 0.02), 1))
            let width = proxy.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tomato).frame(width: width)
            }
        }
        .frame(height: 5)
    }
}

/// Tiny non-activating floating HUD. Never takes focus and never opens the main window.
@MainActor
final class ConversionHUD {
    static let shared = ConversionHUD()
    private let state = HUDState()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var token = 0
    private var started = false
    private init() {}
    /// Call once at launch, after AppModel.shared exists. dropFirst skips the value set by recovery inspection in init.
    func start() {
        guard !started else { return }
        started = true
        state.onCancel = { [weak self] in self?.requestCancel() }
        state.onDetails = { [weak self] in self?.showDetails() }
        let model = AppModel.shared
        model.$progress.receive(on: DispatchQueue.main).sink { [weak self] value in
            guard let self = self, self.state.phase == .progress else { return }
            self.state.progress = value
        }.store(in: &cancellables)
        model.$status.receive(on: DispatchQueue.main).sink { [weak self] value in
            guard let self = self, self.state.phase == .progress else { return }
            self.state.text = value
        }.store(in: &cancellables)
        model.$error.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] value in
            guard let self = self, let value = value, !value.isEmpty else { return }
            self.fail(value)
        }.store(in: &cancellables)
    }
    private func requestCancel() {
        state.cancelling = true
        state.text = "Cancelling…"
        AppModel.shared.cancel()
    }
    private func showDetails() {
        guard let detail = state.detail else { return }
        hideWork?.cancel()
        let alert = NSAlert()
        alert.messageText = "Margherita"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(detail, forType: .string)
        }
        fade()
    }
    /// True for any window owned by the HUD so activation logic can ignore it.
    func owns(_ window: NSWindow) -> Bool { window === panel }
    func begin(_ title: String) {
        state.phase = .progress; state.progress = 0; state.text = title; state.detail = nil; state.cancelling = false
        present()
    }
    func succeed(_ message: String) {
        state.phase = .success; state.progress = 1; state.text = message; state.detail = nil
        present(); scheduleHide(after: 1.4)
    }
    func fail(_ message: String) {
        let first = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? message
        let long = message.count > 70 || message.contains("\n")
        state.phase = .failure; state.text = long ? String(first.prefix(70)) + "…" : message
        state.detail = long ? message : nil
        present(); scheduleHide(after: long ? 12 : 6)
    }
    func dismiss() { fade() }
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 54),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: ConversionHUDView(state: state))
        panel.contentView = host
        return panel
    }
    private func present() {
        hideWork?.cancel(); token += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let host = panel.contentView as? NSHostingView<ConversionHUDView> {
            let size = host.fittingSize
            panel.setContentSize(size)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            position(panel)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = panel.frame.size
        var x = mouse.x - size.width / 2
        var y = mouse.y + 28
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        y = min(max(y, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fade() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func fade() {
        hideWork?.cancel()
        guard let panel = panel, panel.isVisible else { return }
        let current = token
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self = self, self.token == current else { return }
                panel.orderOut(nil)
            }
        })
    }
}
