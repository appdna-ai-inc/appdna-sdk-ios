import Foundation

/// The consent-signal state table: a PURE transition function. `ConsentSignalSender` calls `next` on its serial
/// executor for every event, persists the persisted half of the result, and only then runs the effects — so a SEND's
/// "ack := unknown" is written ahead of the request (a crash at any point leaves either the slot or the unknown
/// mark, and the next `configure` sends again).
///
/// The signal exists because the SDK drops every analytics event of a user who declined, on the device: without it,
/// the server cannot honour that decision on messages it sends itself. Mirrors Android `ConsentSyncTable.kt`; both
/// are held to the shared `event_emission/consent_*` fixtures.
///
/// Rows (numbers are the table's):
///  1  setConsent(v), or a user change while the effective decision is declined → new slot; cancel a timer; EVALUATE if idle
///  2  user change while granted → nothing
///  3  configure → at most ONE send, if (a) a slot, (b) E declined, or (c) ack unknown / known ≠ E and dropped ≠ E
///  4  2xx → ack := known(T), dropped := none; clear the slot if it is that generation, else EVALUATE
///  5  transient → retry the same body (≤ 3 retries), or EVALUATE a newer slot
///  6  exhaustion → keep the slot for the next configure
///  7  retry fire → re-send the same body (a stale generation does nothing)
///  8  drop (any other 4xx) → dropped := T, clear the slot; or EVALUATE a newer slot
/// Rows 0, 9, 10 and 11 (before a sender exists, relaunch, reinstall, end of a sender's epoch) are the sender's.
enum ConsentSyncTable {

    struct Triple: Hashable {
        let anonId: String
        let userId: String?
        let analytics: Bool
    }

    enum Ack: Hashable {
        /// This install has never decided to send.
        case none
        /// A send went out and its outcome is not known (written ahead of every send).
        case unknown
        /// The last triple a 2xx acknowledged.
        case known(Triple)
    }

    /// The pending decision: generation, triple, retries spent, and the body's `ts_ms` (fixed per generation).
    struct Slot: Hashable {
        let generation: Int64
        let triple: Triple
        var attempts: Int
        let tsMs: Int64
    }

    struct State: Hashable {
        // persisted: the ack record (Keychain)
        var ack: Ack = .none
        var dropped: Triple? = nil
        // persisted: the slot store (UserDefaults)
        var slot: Slot? = nil
        var lastBodyTs: Int64? = nil
        var lastGeneration: Int64 = 0
        // in memory
        var inFlight: Slot? = nil
        var timer: Int64? = nil
    }

    enum Event: Equatable {
        case setConsent(effective: Triple, nowMs: Int64)
        case userChanged(effective: Triple, nowMs: Int64)
        case configure(effective: Triple, rowZeroCall: Bool, nowMs: Int64)
        case success(generation: Int64)
        case transient(generation: Int64, retryAfterSeconds: Int64?)
        case drop(generation: Int64)
        case retryFire(generation: Int64)
    }

    enum Effect: Equatable {
        case send(Slot)
        /// Arm the retry for `generation`; `retry` is 1, 2 or 3.
        case armTimer(generation: Int64, retry: Int, retryAfterSeconds: Int64?)
        case cancelTimer
    }

    /// At most three in-session retries per generation (four requests in all), then the next `configure`.
    static let maxRetries = 3

    static func next(_ state: State, _ event: Event) -> (State, [Effect]) {
        var fx: [Effect] = []
        var s = state
        switch event {
        case let .setConsent(e, now):
            s = replace(s, e, now, &fx)
        case let .userChanged(e, now):
            if !e.analytics { s = replace(s, e, now, &fx) } // row 2 (granted): nothing, dropped kept
        case let .configure(e, rowZero, now):
            s = configure(s, e, rowZero, now, &fx)
        case let .success(g):
            guard let f = s.inFlight, f.generation == g else { break }
            s.inFlight = nil
            s.ack = .known(f.triple)
            s.dropped = nil
            if s.slot?.generation == g { s.slot = nil } else { s = evaluate(s, &fx) }
        case let .transient(g, retryAfter):
            guard let f = s.inFlight, f.generation == g else { break }
            s.inFlight = nil
            if var slot = s.slot, slot.generation == g {
                if slot.attempts < maxRetries {
                    slot.attempts += 1
                    fx.append(.armTimer(generation: g, retry: slot.attempts, retryAfterSeconds: retryAfter))
                    s.slot = slot
                    s.timer = g
                } // else row 6: exhausted, kept for configure
            } else {
                s = evaluate(s, &fx)
            }
        case let .drop(g):
            guard let f = s.inFlight, f.generation == g else { break }
            s.inFlight = nil
            if s.slot?.generation == g {
                s.dropped = f.triple
                s.slot = nil
            } else {
                s = evaluate(s, &fx)
            }
        case let .retryFire(g):
            guard s.timer == g else { break }
            s.timer = nil
            if let slot = s.slot, slot.generation == g { s = send(s, slot, &fx) }
        }
        return (s, fx)
    }

    /// Row 1: a new generation with a new body; cancel a timer; EVALUATE when idle, else keep the slot.
    private static func replace(_ state: State, _ e: Triple, _ now: Int64, _ fx: inout [Effect]) -> State {
        var s = newSlot(state, e, now)
        s.dropped = nil
        if s.timer != nil {
            fx.append(.cancelTimer)
            s.timer = nil
        }
        return s.inFlight == nil ? evaluate(s, &fx) : s
    }

    private static func configure(_ state: State, _ e: Triple, _ rowZero: Bool, _ now: Int64, _ fx: inout [Effect]) -> State {
        var s = state
        // A setConsent made before the sender existed clears `dropped` before the triggers are read.
        if rowZero { s.dropped = nil }
        let a = s.slot != nil
        let b = !e.analytics
        let ackDiffers: Bool
        switch s.ack {
        case .unknown: ackDiffers = true
        case .known(let t): ackDiffers = t != e
        case .none: ackDiffers = false
        }
        let c = ackDiffers && s.dropped != e
        guard a || b || c else { return s }
        s = newSlot(s, e, now)
        return send(s, s.slot!, &fx)
    }

    /// EVALUATE: only when nothing is in flight and no timer is armed.
    private static func evaluate(_ state: State, _ fx: inout [Effect]) -> State {
        guard state.inFlight == nil, state.timer == nil, let slot = state.slot else { return state }
        if case .known(let t) = state.ack, t == slot.triple {
            var s = state
            s.slot = nil
            return s
        }
        return send(state, slot, &fx)
    }

    /// SEND: ack := unknown (persisted before the request), in flight := the slot's generation.
    private static func send(_ state: State, _ slot: Slot, _ fx: inout [Effect]) -> State {
        fx.append(.send(slot))
        var s = state
        s.ack = .unknown
        s.inFlight = slot
        return s
    }

    /// A new generation whose body takes `ts_ms = max(now, last_body_ts + 1)`, strictly increasing per device.
    private static func newSlot(_ state: State, _ e: Triple, _ now: Int64) -> State {
        var s = state
        let g = s.lastGeneration + 1
        let ts = s.lastBodyTs.map { max(now, $0 + 1) } ?? now
        s.slot = Slot(generation: g, triple: e, attempts: 0, tsMs: ts)
        s.lastBodyTs = ts
        s.lastGeneration = g
        return s
    }
}
