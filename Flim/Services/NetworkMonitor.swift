import Foundation
import Network
import Observation

/// Tracks connectivity so the UI can show a gentle "no connection" banner instead of failing
/// silently. Reads `isConnected` anywhere it's injected.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "flim.network.monitor")

    init() {
        #if DEBUG
        // `-forceOffline`: reads as offline for the whole run, for checking the offline states.
        if ProcessInfo.processInfo.arguments.contains("-forceOffline") {
            isConnected = false
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in self?.isConnected = connected }
        }
        monitor.start(queue: queue)
    }
}
