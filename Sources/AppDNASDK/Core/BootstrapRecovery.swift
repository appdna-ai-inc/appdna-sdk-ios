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
///  - after a backoff (`backoff`: 5 s, 10 s, 20 s, … capped at 5 min, each ±25 % jitter).
/// A trigger starts its attempt after a short random delay (up to `triggerDelayMax`), so a fleet that
/// regains the network together does not reach the server in the same instant.
/// Offline neither the timer nor a foreground starts an attempt — the loop keeps waiting for the network —
/// so an offline device does not use up its attempts. At most `maxAttempts` attempts per configure.
///
/// The wait is event-driven: the loop sleeps on a continuation that `trigger()` resumes, with the backoff
/// as its timeout. It does not wake in between (it used to poll ten times a second for the whole offline
/// session).
///
/// `attempt` answers an `Outcome`: `.done` when there is nothing more to do (the bootstrap was applied, or
/// its configure has ended), `.retry` after a failure worth retrying, `.retryAfter(s)` when the server
/// rate-limited the request (no attempt — not even a triggered one — before `s` seconds), `.stop` when the
/// server refused the key (401 / 403: retrying cannot help). `stop()` ends the loop; a `start()` after
/// `stop()` does nothing. When the loop ends — for any reason — it removes its observers.
final class BootstrapRecovery: @unchecked Sendable {
    static let defaultMaxAttempts = 10
    /// The jitter applied to every backoff wait: ±25 %.
    static let jitterFraction = 0.25
    /// The longest random delay before a triggered attempt.
    static let defaultTriggerDelayMax: TimeInterval = 1.0

    /// What one attempt came to.
    enum Outcome: Equatable {
        case done
        case retry
        case retryAfter(TimeInterval)
        case stop
    }

    /// The outcome of a failed bootstrap request. `status` is the HTTP status, nil when no HTTP answer came
    /// (network error, timeout, unreadable answer). 401 / 403 end the loop; a 429 with a `Retry-After`
    /// (already parsed and capped by `APIClient.parseRetryAfter`) is honoured; everything else is retried
    /// on the backoff schedule.
    static func outcome(failureStatus status: Int?, retryAfter: TimeInterval?) -> Outcome {
        switch status {
        case 401, 403: return .stop
        case 429: return retryAfter.map { .retryAfter($0) } ?? .retry
        default: return .retry
        }
    }

    /// The outcome of a bootstrap request that threw.
    static func outcome(for error: Error) -> Outcome {
        guard let api = error as? APIError else { return .retry }
        switch api {
        case .httpError(let status, _): return outcome(failureStatus: status, retryAfter: nil)
        case .rateLimited(let retryAfter, _): return outcome(failureStatus: 429, retryAfter: retryAfter)
        default: return .retry
        }
    }

    /// 5 s, 10 s, 20 s, 40 s, … capped at 5 minutes (before jitter).
    static func defaultBackoff(_ attemptIndex: Int) -> TimeInterval {
        min(5 * pow(2, Double(min(max(attemptIndex, 0), 6))), 300)
    }

    /// `base` with ±`jitterFraction` jitter; `unit` is a random number in [0, 1).
    static func jittered(_ base: TimeInterval, unit: Double) -> TimeInterval {
        max(0, base * (1 - jitterFraction + 2 * jitterFraction * unit))
    }

    let maxAttempts: Int
    private let backoff: (Int) -> TimeInterval
    private let isOnline: () -> Bool
    private let random: () -> Double
    private let triggerDelayMax: TimeInterval

    private let lock = NSLock()
    private var triggered = false
    private var stopped = false
    private var _attempts = 0
    private var _wakeups = 0
    private var _registrations = 0
    private var task: Task<Void, Never>?
    private var waiter: (id: UInt64, cont: CheckedContinuation<Bool, Never>)?
    private var nextWaiterId: UInt64 = 0
    private var foregroundObserver: NSObjectProtocol?
    private var networkObserver: UUID?

    /// Attempts made so far (test reader).
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }
    /// Times the loop's wait returned — a trigger, a timeout or a stop (test reader).
    var wakeups: Int { lock.lock(); defer { lock.unlock() }; return _wakeups }
    /// Times a loop kept its observers — 1 for a loop that started, 0 for one refused (test reader).
    var observerRegistrations: Int { lock.lock(); defer { lock.unlock() }; return _registrations }
    /// Whether observers are registered now (test reader).
    var isObserving: Bool { lock.lock(); defer { lock.unlock() }; return foregroundObserver != nil || networkObserver != nil }

    init(isOnline: @escaping () -> Bool,
         backoff: @escaping (Int) -> TimeInterval = BootstrapRecovery.defaultBackoff,
         maxAttempts: Int = BootstrapRecovery.defaultMaxAttempts,
         random: @escaping () -> Double = { Double.random(in: 0..<1) },
         triggerDelayMax: TimeInterval = BootstrapRecovery.defaultTriggerDelayMax) {
        self.isOnline = isOnline
        self.backoff = backoff
        self.maxAttempts = maxAttempts
        self.random = random
        self.triggerDelayMax = triggerDelayMax
    }

    /// The network came back, or the app came to the foreground: try now (if the loop is waiting).
    func trigger() {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.cont.resume(returning: true)
        } else {
            triggered = true
            lock.unlock()
        }
    }

    private func resumeWaiter(_ id: UInt64, with value: Bool) {
        lock.lock()
        guard let w = waiter, w.id == id else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        w.cont.resume(returning: value)
    }

    /// Sleeps until `trigger()` (true), `timeout` (false) or `stop()` / cancellation (false). A trigger that
    /// came while the loop was not waiting is consumed at once.
    private func waitForTrigger(timeout: TimeInterval) async -> Bool {
        let id: UInt64 = { lock.lock(); defer { lock.unlock() }; nextWaiterId += 1; return nextWaiterId }()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if triggered { triggered = false; lock.unlock(); cont.resume(returning: true); return }
                if stopped || Task.isCancelled { lock.unlock(); cont.resume(returning: false); return }
                waiter = (id, cont)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                    self?.resumeWaiter(id, with: false)
                }
            }
        } onCancel: {
            self.resumeWaiter(id, with: false)
        }
        lock.lock(); _wakeups += 1; lock.unlock()
        return result
    }

    private var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return stopped || Task.isCancelled }

    func start(_ attempt: @escaping () async -> Outcome) {
        // Observers first, then — under the lock — the stop check: a `stop()` that came before (or while)
        // they were added removes them here, and the loop never starts.
        let fg = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.trigger() }
        let net = NetworkMonitor.shared.addRegainedObserver { [weak self] in self?.trigger() }
        lock.lock()
        guard !stopped, task == nil else {
            lock.unlock()
            NotificationCenter.default.removeObserver(fg)
            NetworkMonitor.shared.removeRegainedObserver(net)
            return
        }
        foregroundObserver = fg
        networkObserver = net
        _registrations += 1
        task = Task { [self] in
            await self.run(attempt)
            self.removeObservers()
        }
        lock.unlock()
    }

    private func run(_ attempt: @escaping () async -> Outcome) async {
        var notBefore: Date?
        while !isEnded && attempts < maxAttempts {
            var deadline = Date().addingTimeInterval(Self.jittered(backoff(attempts), unit: random()))
            if let nb = notBefore, nb > deadline { deadline = nb }
            var wasTriggered = false
            while !isEnded {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                if await waitForTrigger(timeout: remaining) {
                    // Rate limited: a trigger does not shorten the wait the server asked for.
                    if let nb = notBefore, Date() < nb { continue }
                    wasTriggered = true
                    break
                }
            }
            if isEnded { return }
            if wasTriggered, triggerDelayMax > 0 {
                try? await Task.sleep(nanoseconds: UInt64(triggerDelayMax * random() * 1_000_000_000))
                if isEnded { return }
            }
            // Offline, neither the timer nor a foreground helps: wait again (no attempt used). The
            // network coming back is a trigger, and starts the attempt.
            if !isOnline() { continue }
            notBefore = nil
            lock.lock(); _attempts += 1; let n = _attempts; lock.unlock()
            Log.info("Retrying the bootstrap (attempt \(n) of \(maxAttempts)\(wasTriggered ? ", triggered" : ""))")
            switch await attempt() {
            case .done:
                return
            case .stop:
                Log.warning("Bootstrap retries stopped — the server refused the API key; cached and bundled config until the next configure()")
                return
            case .retry:
                break
            case .retryAfter(let seconds):
                notBefore = Date().addingTimeInterval(seconds)
            }
        }
        if !isEnded {
            Log.warning("Bootstrap still failing after \(maxAttempts) retries — cached and bundled config until the next configure()")
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let t = task; task = nil
        let w = waiter; waiter = nil
        lock.unlock()
        t?.cancel()
        w?.cont.resume(returning: false)
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
