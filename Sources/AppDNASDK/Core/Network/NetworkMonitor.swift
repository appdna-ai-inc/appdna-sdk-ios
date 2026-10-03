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

    /// The state is written on the monitor's queue and read from any thread (the event queue, the background
    /// uploader, the bootstrap retry loop): every access goes through `stateLock`.
    private let stateLock = NSLock()
    private var _currentConnectionType: ConnectionType = .wifi
    private var _isExpensive: Bool = false

    var currentConnectionType: ConnectionType { stateLock.lock(); defer { stateLock.unlock() }; return _currentConnectionType }
    var isExpensive: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _isExpensive }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type = NetworkMonitor.connectionType(
                satisfied: path.status == .satisfied,
                usesWifi: path.usesInterfaceType(.wifi),
                usesCellular: path.usesInterfaceType(.cellular)
            )
            self.apply(type: type, expensive: path.isExpensive)
        }
        monitor.start(queue: monitorQueue)
    }

    /// The connection type of a path: not satisfied → none; Wi-Fi → wifi; cellular → cellular; a wired or any other
    /// connected interface → wifi (Android `ConnectivityMonitor.typeOf`, same mapping).
    static func connectionType(satisfied: Bool, usesWifi: Bool, usesCellular: Bool) -> ConnectionType {
        guard satisfied else { return .none }
        if usesWifi { return .wifi }
        if usesCellular { return .cellular }
        return .wifi
    }

    /// Applies a new state atomically; "was none" is decided under the same lock, so concurrent updates report a
    /// regain exactly once per none → connected transition. Observers run outside the lock. Internal: the test seam
    /// drives it without an `NWPath`.
    func apply(type: ConnectionType, expensive: Bool) {
        stateLock.lock()
        let wasNone = _currentConnectionType == .none
        _currentConnectionType = type
        _isExpensive = expensive
        stateLock.unlock()
        Log.debug("Network changed: \(type), expensive=\(expensive)")
        if wasNone && type != .none { notifyRegained() }
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
        stateLock.lock()
        let type = _currentConnectionType, expensive = _isExpensive
        stateLock.unlock()
        switch type {
        case .wifi:
            return 100
        case .cellular:
            return expensive ? 20 : 50
        case .none:
            return 0
        }
    }
}
