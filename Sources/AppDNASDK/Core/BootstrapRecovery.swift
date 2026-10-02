import Foundation
import UIKit

/// Retries a failed bootstrap for the rest of the session — Android `BootstrapRecovery`, same rules.
///
/// A bootstrap that failed (an offline launch, a server that was unreachable or slower than the 15-second
/// limit) used to leave the SDK on cached and bundled config for the whole session: no Firestore path, so
/// no remote config fetch, no Firestore listeners (web entitlements, journey messages), no deferred deep
/// links and no runtime lock until the next `configure()`. Now the SDK tries again:
///  - when a network comes back after none was available (`trigger()` from `NetworkMonitor`);
///  - when the app comes to the foreground (`trigger()` from `willEnterForegroundNotification`);
///  - after a backoff (`backoff`: 5 s, 10 s, 20 s, … capped at 5 min).
/// Offline neither the timer nor a foreground starts an attempt — the loop keeps waiting for the network —
/// so an offline device does not use up its attempts. At most `maxAttempts` attempts per configure.
/// `attempt` answers true when there is nothing more to do: the bootstrap was applied, or its configure has
/// ended (`shutdown()` / a later `configure()` moved the epoch on). `stop()` ends the loop.
final class BootstrapRecovery: @unchecked Sendable {
    static let defaultMaxAttempts = 10

    /// 5 s, 10 s, 20 s, 40 s, … capped at 5 minutes.
    static func defaultBackoff(_ attemptIndex: Int) -> TimeInterval {
        min(5 * pow(2, Double(min(max(attemptIndex, 0), 6))), 300)
    }

    let maxAttempts: Int
    private let backoff: (Int) -> TimeInterval
    private let isOnline: () -> Bool
    /// How often the wait checks for a trigger.
    private let tick: TimeInterval

    private let lock = NSLock()
    private var triggered = false
    private var _attempts = 0
    private var task: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var networkObserver: UUID?

    /// Attempts made so far (test reader).
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }

    init(isOnline: @escaping () -> Bool,
         backoff: @escaping (Int) -> TimeInterval = BootstrapRecovery.defaultBackoff,
         maxAttempts: Int = BootstrapRecovery.defaultMaxAttempts,
         tick: TimeInterval = 0.1) {
        self.isOnline = isOnline
        self.backoff = backoff
        self.maxAttempts = maxAttempts
        self.tick = tick
    }

    /// The network came back, or the app came to the foreground: try now (if the loop is waiting).
    func trigger() {
        lock.lock(); triggered = true; lock.unlock()
    }

    private func consumeTrigger() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = triggered
        triggered = false
        return t
    }

    func start(_ attempt: @escaping () async -> Bool) {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.trigger() }
        networkObserver = NetworkMonitor.shared.addRegainedObserver { [weak self] in self?.trigger() }

        let loop = Task { [self] in
            while !Task.isCancelled && self.attempts < self.maxAttempts {
                let deadline = Date().addingTimeInterval(self.backoff(self.attempts))
                var wasTriggered = false
                while !Task.isCancelled && Date() < deadline {
                    if self.consumeTrigger() { wasTriggered = true; break }
                    try? await Task.sleep(nanoseconds: UInt64(self.tick * 1_000_000_000))
                }
                if Task.isCancelled { return }
                // Offline, neither the timer nor a foreground helps: wait again (no attempt used). The
                // network coming back is a trigger, and starts the attempt.
                if !self.isOnline() { continue }
                self.lock.lock(); self._attempts += 1; let n = self._attempts; self.lock.unlock()
                Log.info("Retrying the bootstrap (attempt \(n) of \(self.maxAttempts)\(wasTriggered ? ", triggered" : ""))")
                if await attempt() { self.removeObservers(); return }
            }
            if !Task.isCancelled {
                Log.warning("Bootstrap still failing after \(self.maxAttempts) retries — cached and bundled config until the next configure()")
            }
            self.removeObservers()
        }
        lock.lock(); task = loop; lock.unlock()
    }

    func stop() {
        lock.lock(); let t = task; task = nil; lock.unlock()
        t?.cancel()
        removeObservers()
    }

    private func removeObservers() {
        lock.lock()
        let fg = foregroundObserver; foregroundObserver = nil
        let net = networkObserver; networkObserver = nil
        lock.unlock()
        if let fg { NotificationCenter.default.removeObserver(fg) }
        if let net { NetworkMonitor.shared.removeRegainedObserver(net) }
    }
}
