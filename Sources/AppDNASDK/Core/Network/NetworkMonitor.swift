import Foundation
import Network

/// SPEC-067: Network condition monitoring for adaptive batch sizing.
/// Wraps NWPathMonitor to expose current connection type.
final class NetworkMonitor {
    /// Shared singleton instance.
    static let shared = NetworkMonitor()

    /// Connection type categories for adaptive batching.
    enum ConnectionType {
        case wifi
        case cellular
        case none
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "ai.appdna.sdk.networkmonitor")
    private(set) var currentConnectionType: ConnectionType = .wifi
    private(set) var isExpensive: Bool = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasNone = self.currentConnectionType == .none
            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi) {
                    self.currentConnectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.currentConnectionType = .cellular
                } else {
                    // Wired or other connected interface — treat as wifi
                    self.currentConnectionType = .wifi
                }
            } else {
                self.currentConnectionType = .none
            }
            self.isExpensive = path.isExpensive
            Log.debug("Network changed: \(self.currentConnectionType), expensive=\(self.isExpensive)")
            if wasNone && self.currentConnectionType != .none { self.notifyRegained() }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Whether a network is available now.
    var isConnected: Bool { currentConnectionType != .none }

    /// Observers called (on the monitor's queue) when a network comes back after none was available —
    /// the SDK retries a failed bootstrap then.
    private let observerLock = NSLock()
    private var regainedObservers: [UUID: () -> Void] = [:]

    @discardableResult
    func addRegainedObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observerLock.lock(); regainedObservers[id] = observer; observerLock.unlock()
        return id
    }

    func removeRegainedObserver(_ id: UUID) {
        observerLock.lock(); regainedObservers[id] = nil; observerLock.unlock()
    }

    private func notifyRegained() {
        observerLock.lock(); let observers = Array(regainedObservers.values); observerLock.unlock()
        for observer in observers { observer() }
    }

    deinit {
        monitor.cancel()
    }

    /// Test seam: when set, `adaptiveBatchSize` returns it (the simulator's network is not a test input).
    static var adaptiveBatchSizeOverrideForTesting: Int?

    /// Returns the adaptive batch size based on current network conditions.
    var adaptiveBatchSize: Int {
        if let forced = Self.adaptiveBatchSizeOverrideForTesting { return forced }
        switch currentConnectionType {
        case .wifi:
            return 100
        case .cellular:
            return isExpensive ? 20 : 50
        case .none:
            return 0
        }
    }
}
