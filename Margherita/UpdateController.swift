import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// A single updater shared by the app menu and Settings. No placeholder network traffic.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksEnabled = false
    @Published private(set) var isConfigured = false
    @Published private(set) var statusMessage = "Updates will be available once the release feed is configured."
#if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
#endif

    static func validConfiguration(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              !feed.uppercased().contains("REPLACE"),
              !feed.uppercased().contains("YOUR_"),
              !host.hasSuffix(".invalid"), !host.hasSuffix(".example"),
              let key = info["SUPublicEDKey"] as? String,
              let decoded = Data(base64Encoded: key), decoded.count == 32
        else { return false }
        return true
    }

    /// Call after applicationDidFinishLaunching, never during static initialization.
    func start() {
#if canImport(Sparkle)
        guard controller == nil,
              Self.validConfiguration(Bundle.main.infoDictionary ?? [:]) else { return }
        let candidate = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        controller = candidate
        // Subscribe before starting, so menus follow Sparkle's busy/idle state.
        candidate.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        candidate.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecksEnabled = $0 }
            .store(in: &subscriptions)
        do {
            try candidate.updater.start()
            isConfigured = true
            statusMessage = "Updates are checked securely using Sparkle."
        } catch {
            subscriptions.removeAll()
            controller = nil
            statusMessage = "The updater could not start: \(error.localizedDescription)"
        }
#else
        statusMessage = "This build does not include Sparkle. Rebuild online to enable updates."
#endif
    }

    var automaticallyChecksForUpdates: Bool {
        get { automaticallyChecksEnabled }
        set {
#if canImport(Sparkle)
            guard isConfigured, let controller = controller else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            automaticallyChecksEnabled = controller.updater.automaticallyChecksForUpdates
#endif
        }
    }

    func checkForUpdates() {
        start()
#if canImport(Sparkle)
        if isConfigured, let controller = controller {
            guard controller.updater.canCheckForUpdates else { return }
            controller.checkForUpdates(nil)
            return
        }
#endif
        let alert = NSAlert()
        alert.messageText = "Updates aren't available yet"
        alert.informativeText = statusMessage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
