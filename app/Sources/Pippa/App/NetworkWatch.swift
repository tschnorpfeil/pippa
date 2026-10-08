import Foundation
import Network

/// Whether a network connection is currently available (only for reloading the model).
@MainActor
final class NetworkWatch {
    static let shared = NetworkWatch()
    private let monitor = NWPathMonitor()
    private(set) var online = true

    private init() {
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in NetworkWatch.shared.online = ok }
        }
        monitor.start(queue: DispatchQueue(label: "pippa.network"))
    }

    /// Waits until the network is back (polls every 5 s).
    func waitUntilOnline() async {
        while !online && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
