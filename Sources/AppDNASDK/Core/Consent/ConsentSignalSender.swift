import Foundation

/// A cancellable scheduled task.
protocol ConsentScheduledToken: AnyObject {
    func cancel()
}

/// The consent sender's serial executor and clock. Production wraps one serial `DispatchQueue` and `Date`; the test
/// target installs a manual one (`AppDNA.installConsentClockForTesting`) whose tasks run when the test pops them.
protocol ConsentScheduler: AnyObject {
    var nowMs: Int64 { get }
    /// Run `work` on the serial executor, now.
    func async(_ work: @escaping () -> Void)
    /// Run `work` on the serial executor at `atMs` (on this scheduler's clock).
    @discardableResult func schedule(atMs: Int64, _ work: @escaping () -> Void) -> ConsentScheduledToken
    /// The earliest scheduled, uncancelled task's due time, or nil.
    var nextDeadlineMs: Int64? { get }
    /// Cancel every scheduled task (only when an epoch ends).
    func cancelAll()
}

/// Production scheduler: one serial queue, wall-clock milliseconds.
final class DispatchConsentScheduler: ConsentScheduler {
    private let queue = DispatchQueue(label: "ai.appdna.sdk.consent", qos: .utility)
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: (Int64, Token)] = [:]

    final class Token: ConsentScheduledToken {
        let item: DispatchWorkItem
        weak var owner: DispatchConsentScheduler?
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() {
            item.cancel()
            owner?.forget(self)
        }
    }

    var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func async(_ work: @escaping () -> Void) { queue.async(execute: work) }

    func schedule(atMs: Int64, _ work: @escaping () -> Void) -> ConsentScheduledToken {
        var token: Token!
        let item = DispatchWorkItem { [weak self] in
            self?.forget(token)
            work()
        }
        token = Token(item)
        token.owner = self
        lock.lock(); pending[ObjectIdentifier(token)] = (atMs, token); lock.unlock()
        let delay = max(0, Double(atMs - nowMs) / 1000)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }

    fileprivate func forget(_ token: Token) {
        lock.lock(); pending.removeValue(forKey: ObjectIdentifier(token)); lock.unlock()
    }

    var nextDeadlineMs: Int64? {
        lock.lock(); defer { lock.unlock() }
        return pending.values.map { $0.0 }.min()
    }

    func cancelAll() {
        lock.lock(); let all = pending.values.map { $0.1 }; pending.removeAll(); lock.unlock()
        all.forEach { $0.item.cancel() }
    }
}

/// The outcome of one consent-signal POST (`APIClient.postConsentOnce`).
enum ConsentPostOutcome {
    case success
    case transient(retryAfterSeconds: Int64?)
    case drop
}

/// Where the sender's persisted state lives.
protocol ConsentSignalPersisting: AnyObject {
    func load() -> ConsentSyncTable.State
    func save(_ state: ConsentSyncTable.State)
}

/// The ack record (`ack` and `dropped`) lives in the **Keychain**, beside `anon_id`, so it survives an app reinstall
/// with the anon it names. The slot, `last_body_ts` and the generation live in UserDefaults, beside the decision.
final class ConsentSignalPersistence: ConsentSignalPersisting {
    static let ackKey = "consent_ack_record"
    static let slotKey = "ai.appdna.sdk.consent_signal_slot"
    static let lastTsKey = "ai.appdna.sdk.consent_signal_last_body_ts"
    static let generationKey = "ai.appdna.sdk.consent_signal_generation"

    private let keychain: KeychainStoring
    private let defaults: UserDefaults

    init(keychain: KeychainStoring, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    func load() -> ConsentSyncTable.State {
        var s = ConsentSyncTable.State()
        if let raw = keychain.getString(key: Self.ackKey),
           let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            s.ack = Self.ack(from: obj["ack"])
            s.dropped = (obj["dropped"] as? [String: Any]).flatMap(Self.triple(from:))
        }
        if let obj = defaults.dictionary(forKey: Self.slotKey), let slot = Self.slot(from: obj) { s.slot = slot }
        if let ts = defaults.object(forKey: Self.lastTsKey) as? NSNumber { s.lastBodyTs = ts.int64Value }
        s.lastGeneration = (defaults.object(forKey: Self.generationKey) as? NSNumber)?.int64Value ?? 0
        return s
    }

    func save(_ state: ConsentSyncTable.State) {
        if let slot = state.slot { defaults.set(Self.json(slot), forKey: Self.slotKey) } else { defaults.removeObject(forKey: Self.slotKey) }
        if let ts = state.lastBodyTs { defaults.set(NSNumber(value: ts), forKey: Self.lastTsKey) } else { defaults.removeObject(forKey: Self.lastTsKey) }
        defaults.set(NSNumber(value: state.lastGeneration), forKey: Self.generationKey)
        let record = Self.ackRecord(state.ack, state.dropped)
        if let data = try? JSONSerialization.data(withJSONObject: record), let str = String(data: data, encoding: .utf8) {
            keychain.setString(key: Self.ackKey, value: str)
        }
    }

    // MARK: JSON

    static func json(_ t: ConsentSyncTable.Triple) -> [String: Any] {
        ["anon_id": t.anonId, "user_id": t.userId.map { $0 as Any } ?? NSNull(), "analytics": t.analytics]
    }

    static func triple(from o: [String: Any]) -> ConsentSyncTable.Triple? {
        guard let anon = o["anon_id"] as? String, let analytics = o["analytics"] as? Bool else { return nil }
        return ConsentSyncTable.Triple(anonId: anon, userId: o["user_id"] as? String, analytics: analytics)
    }

    static func ackRecord(_ ack: ConsentSyncTable.Ack, _ dropped: ConsentSyncTable.Triple?) -> [String: Any] {
        let a: Any
        switch ack {
        case .none: a = "none"
        case .unknown: a = "unknown"
        case .known(let t): a = json(t)
        }
        return ["ack": a, "dropped": dropped.map { json($0) as Any } ?? NSNull()]
    }

    static func ack(from raw: Any?) -> ConsentSyncTable.Ack {
        if let s = raw as? String, s == "unknown" { return .unknown }
        if let o = raw as? [String: Any], let t = triple(from: o) { return .known(t) }
        return .none
    }

    static func json(_ s: ConsentSyncTable.Slot) -> [String: Any] {
        ["g": NSNumber(value: s.generation), "t": json(s.triple), "attempts": s.attempts, "ts_ms": NSNumber(value: s.tsMs)]
    }

    static func slot(from o: [String: Any]) -> ConsentSyncTable.Slot? {
        guard let g = (o["g"] as? NSNumber)?.int64Value, let t = (o["t"] as? [String: Any]).flatMap(triple(from:)),
              let attempts = (o["attempts"] as? NSNumber)?.intValue, let ts = (o["ts_ms"] as? NSNumber)?.int64Value else { return nil }
        return ConsentSyncTable.Slot(generation: g, triple: t, attempts: attempts, tsMs: ts)
    }

    /// The wire body. An absent user is an explicit `NSNull()`, never a boxed optional, so the key is always sent.
    static func body(_ slot: ConsentSyncTable.Slot) -> [String: Any] {
        var b = json(slot.triple)
        b["ts_ms"] = NSNumber(value: slot.tsMs)
        return b
    }
}

/// The SDK analytics-consent signal: the one request that tells AppDNA a device declined (or granted)
/// analytics, so the server can skip its own analytics-only side effects for that user. It bypasses the event
/// pipeline on purpose — a declined user's events never leave the device, so nothing else would carry the decision.
///
/// Every transition runs on the `ConsentScheduler` (the serial executor) through the pure `ConsentSyncTable`. The
/// persisted half of each new state is written before its effects run, so a SEND's "ack := unknown" is on disk
/// before the request leaves.
///
/// **The epoch fence.** A sender belongs to one configure; `shutdown()` and the test reset end its epoch. Every
/// transition first checks the epoch: a stale completion, retry fire or evaluation writes nothing and sends nothing,
/// and a stale public call is handed to the current sender (or held as a row-0 call when there is none).
final class ConsentSignalSender {
    static let path = "/api/v1/ingest/consent"

    private static let staticLock = NSLock()
    private static var currentEpoch: Int64 = 0
    private static var _staleArrivals = 0
    static var staleArrivals: Int {
        get { staticLock.lock(); defer { staticLock.unlock() }; return _staleArrivals }
        set { staticLock.lock(); _staleArrivals = newValue; staticLock.unlock() }
    }

    let epoch: Int64
    private let scheduler: ConsentScheduler
    private let persistence: ConsentSignalPersisting
    private let post: ([String: Any]) async -> ConsentPostOutcome
    private let handoff: (ConsentSyncTable.Event) -> Void

    private var state: ConsentSyncTable.State
    private var timerToken: ConsentScheduledToken?

    private let counterLock = NSLock()
    private var inFlightCount = 0
    private var completionsPending = 0

    init(
        scheduler: ConsentScheduler,
        persistence: ConsentSignalPersisting,
        post: @escaping ([String: Any]) async -> ConsentPostOutcome,
        handoff: @escaping (ConsentSyncTable.Event) -> Void
    ) {
        Self.staticLock.lock(); epoch = Self.currentEpoch; Self.staticLock.unlock()
        self.scheduler = scheduler
        self.persistence = persistence
        self.post = post
        self.handoff = handoff
        self.state = persistence.load()
        Self.staticLock.lock(); Self.live = self; Self.staticLock.unlock()
    }

    var isCurrent: Bool {
        Self.staticLock.lock(); defer { Self.staticLock.unlock() }
        return Self.currentEpoch == epoch
    }

    // MARK: Public triggers (rows 1, 2, 3)

    func setConsent(_ e: ConsentSyncTable.Triple) { submit(.setConsent(effective: e, nowMs: scheduler.nowMs)) }
    func userChanged(_ e: ConsentSyncTable.Triple) { submit(.userChanged(effective: e, nowMs: scheduler.nowMs)) }
    func configure(_ e: ConsentSyncTable.Triple, rowZeroCall: Bool) {
        submit(.configure(effective: e, rowZeroCall: rowZeroCall, nowMs: scheduler.nowMs))
    }

    private func submit(_ event: ConsentSyncTable.Event) {
        scheduler.async { [self] in apply(event) }
    }

    /// The sender of the current epoch (weak), so `shutdown()` can end it from the caller's thread.
    private static weak var live: ConsentSignalSender?

    /// Row 11: end the current sender's epoch (the public `shutdown()` and the test reset). Its retry is cancelled;
    /// a request in flight is abandoned to the fence. Safe from any thread.
    static func endCurrentEpoch() {
        staticLock.lock()
        currentEpoch += 1
        let dead = live
        live = nil
        staticLock.unlock()
        dead?.cancelTimer()
    }

    private func cancelTimer() {
        counterLock.lock(); let t = timerToken; timerToken = nil; counterLock.unlock()
        t?.cancel()
    }

    // MARK: The serial executor

    private func apply(_ event: ConsentSyncTable.Event) {
        guard isCurrent else {
            Self.staticLock.lock(); Self._staleArrivals += 1; Self.staticLock.unlock()
            switch event {
            case .setConsent, .userChanged: handoff(event)
            default: break
            }
            return
        }
        switch event {
        case .success, .transient, .drop: ConsentTestLatch.pass("check_act")
        default: break
        }
        let (next, effects) = ConsentSyncTable.next(state, event)
        state = next
        persistence.save(state)
        for fx in effects { run(fx) }
    }

    private func run(_ fx: ConsentSyncTable.Effect) {
        switch fx {
        case .send(let slot):
            send(slot)
        case .cancelTimer:
            cancelTimer()
        case let .armTimer(g, retry, retryAfter):
            let delay = Self.retryDelayMs(retry: retry, retryAfterSeconds: retryAfter)
            let token = scheduler.schedule(atMs: scheduler.nowMs + delay) { [self] in
                apply(.retryFire(generation: g))
            }
            counterLock.lock(); timerToken = token; counterLock.unlock()
        }
    }

    /// The request returned: a completion is owed before the request stops counting as in flight.
    private func noteReturned() {
        counterLock.lock(); completionsPending += 1; inFlightCount -= 1; counterLock.unlock()
    }

    private func counters() -> (inFlight: Int, pending: Int) {
        counterLock.lock(); defer { counterLock.unlock() }
        return (inFlightCount, completionsPending)
    }

    private func send(_ slot: ConsentSyncTable.Slot) {
        counterLock.lock(); inFlightCount += 1; counterLock.unlock()
        let body = ConsentSignalPersistence.body(slot)
        let post = self.post
        Task.detached { [self] in
            let outcome = await post(body)
            noteReturned()
            ConsentTestLatch.pass("io_return")
            scheduler.async { [self] in
                counterLock.lock(); completionsPending -= 1; counterLock.unlock()
                switch outcome {
                case .success: apply(.success(generation: slot.generation))
                case .transient(let ra): apply(.transient(generation: slot.generation, retryAfterSeconds: ra))
                case .drop: apply(.drop(generation: slot.generation))
                }
            }
        }
    }

    /// 1 s, 2 s, 4 s, each ±25%; a `Retry-After` replaces the backoff.
    static func retryDelayMs(retry: Int, retryAfterSeconds: Int64?) -> Int64 {
        if let ra = retryAfterSeconds, ra > 0 { return ra * 1000 }
        let base = Int64(1000) << Int64(retry - 1)
        let jitter = base / 4
        return base - jitter + Int64.random(in: 0...(2 * jitter))
    }

    // MARK: Test hooks

    /// Waits until no request is on the wire, then returns the completions not yet run; nil on timeout.
    func awaitIdle(timeoutMs: Int64) async -> Int? {
        let end = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            let (inFlight, pending) = counters()
            if inFlight == 0 { return pending }
            if Date() > end { return nil }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    var stateForTesting: ConsentSyncTable.State { state }
}

/// Test-only hold points (`io_return`, `check_act`): the next pass through the armed point blocks for `holdMs` of
/// real time, once. The reset clears it. Inert in production (nothing arms it).
enum ConsentTestLatch {
    private static let lock = NSLock()
    private static var point: String?
    private static var holdMs: Int64 = 0
    private static var engaged = DispatchSemaphore(value: 0)
    private static var didEngage = false

    static func arm(point p: String, holdMs h: Int64) {
        lock.lock(); point = p; holdMs = h; engaged = DispatchSemaphore(value: 0); didEngage = false; lock.unlock()
    }

    static func clear() { lock.lock(); point = nil; lock.unlock() }

    static func pass(_ at: String) {
        lock.lock()
        guard point == at else { lock.unlock(); return }
        point = nil
        let hold = holdMs
        didEngage = true
        let sem = engaged
        lock.unlock()
        sem.signal()
        Thread.sleep(forTimeInterval: Double(hold) / 1000)
    }

    static func awaitEngaged(timeoutMs: Int64) -> Bool {
        lock.lock(); let sem = engaged; let already = didEngage; lock.unlock()
        if already { return true }
        return sem.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .success
    }
}
