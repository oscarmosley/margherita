import Foundation
import Combine

/// Settings consume an immutable route snapshot. No filesystem, codec or application
/// discovery is performed by a SwiftUI body or when selecting a format.
@MainActor
final class FormatCapabilities: ObservableObject {
    static let shared = FormatCapabilities()
    @Published private(set) var outputsByInput: [String: [String]] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var mediaAvailable = false
    private var started = false

    func outputs(of input: String) -> [String] { outputsByInput[input] ?? [] }

    func start() {
        guard !started else { return }
        started = true
        let inputs = FormatCatalog.allFormats
        Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                FormatCapabilityDiscovery.snapshot(inputs: inputs)
            }.value
            outputsByInput = snapshot.outputs
            mediaAvailable = snapshot.mediaAvailable
            isLoading = false
            WatchFolders.shared.start()
            AppModel.shared.objectWillChange.send()
        }
    }
}

/// These are format-level routes, not a guarantee that a damaged or unusual file
/// will convert. File-specific validation remains in the actual conversion engine.
enum FormatCapabilityDiscovery {
    struct Snapshot: Sendable {
        let outputs: [String: [String]]
        let mediaAvailable: Bool
    }

    static func snapshot(inputs: [String]) -> Snapshot {
        let facts = ConversionRoutes.warmUp()
        var outputs: [String: [String]] = [:]
        for input in inputs {
            outputs[input] = ConversionRoutes.outputs(source: input, facts: facts).map(ConversionRoutes.display)
        }
        return Snapshot(outputs: outputs, mediaAvailable: facts.mediaAvailable)
    }
}
