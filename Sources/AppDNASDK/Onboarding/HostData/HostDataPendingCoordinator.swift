import Foundation

/// SPEC-496 §B0 "Host data pending" — the normative state machine, one per flow host, tracking the
/// CURRENT step presentation (one arrival on a step; back-then-forward is a new presentation).
///
/// - **Starts synchronously**: a presentation is pending from its first frame — before the delegate
///   call even starts in `onAppear` — unless the step's override is already cached. That is decided
///   by `isPending(presentation:applies:cached:)`, which needs no call to have started.
/// - **Ends** at min(reply, deadline), with the deadline driven by a timer INDEPENDENT of the host
///   call: a host that awaits something never resumed, and ignores cancellation, still ends pending
///   at 3 s. (The old `withTaskGroup` timeout waited for such a child after `cancelAll()`.)
/// - **Generation tokens**: only the latest call may end pending or apply its reply (`onFinish`).
/// - **Step view** (`onSettled`): fires once for EVERY call that finished — reply or deadline — even
///   when a later presentation superseded it. 🔴 It used to ride on `onFinish`, so leaving a step
///   before the delegate replied (the next step's `start` bumps the generation) meant
///   `onboarding_step_viewed` / `onOnboardingStepChanged` never fired for that step, on every flow,
///   host data or not. Pre-SPEC-496 the step view fired after the await unconditionally.
/// - **Cancelled before replying**: does NOT end pending; the call is re-fired ONCE as the latest
///   generation with a fresh deadline, and that call ends pending itself. A cancelled call fires
///   neither callback, so the re-fire is what counts the step view (exactly once).
///
/// Main-thread only (every caller is a view or the fixture runner on the main actor); replies hop
/// back with `MainActor.run`.
final class HostDataPendingCoordinator: ObservableObject {
    typealias Call = @Sendable () async -> StepConfigOverride?
    /// Schedules `fire` after `seconds`; returns a cancel closure.
    typealias Schedule = (_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void

    static let defaultTimeout: TimeInterval = 3.0

    /// Presentations whose pending phase is over.
    @Published private(set) var endedPresentations: Set<Int> = []

    private let schedule: Schedule
    private var generation = 0
    private var inFlight: InFlight?
    private var refiredPresentations: Set<Int> = []
    /// SPEC-496 §5b C3 — "cached" is sampled ONCE per presentation, on its first `isPending`, and
    /// latched. Plain (not `@Published`): it is written during `body`. Not pruned, like
    /// `endedPresentations`: one entry per presentation of this flow presentation.
    ///
    /// Without the latch an OTP / calendar / press-hold reply carrying `dataContext` during
    /// first-arrival pending would flip "cached" and END pending on iOS only — the empty state would
    /// show, `empty_in_scope` would satisfy the gate and selections would be pruned while
    /// `onBeforeStepRender` is still in flight.
    private var cachedAtArrival: [Int: Bool] = [:]

    private final class InFlight {
        let generation: Int
        let presentation: Int
        let call: Call
        let timeout: TimeInterval
        let onFinish: (StepConfigOverride?, Int) -> Void
        let onSettled: () -> Void
        let seqSource: (() -> Int)?
        /// SPEC-496 §5b C3 — the flow-level `callSeq` this call drew at START.
        let seq: Int
        var task: Task<Void, Never>?
        var cancelDeadline: (() -> Void)?
        var finished = false
        init(generation: Int, presentation: Int, call: @escaping Call, timeout: TimeInterval, seqSource: (() -> Int)?,
             onSettled: @escaping () -> Void, onFinish: @escaping (StepConfigOverride?, Int) -> Void) {
            self.generation = generation
            self.presentation = presentation
            self.call = call
            self.timeout = timeout
            self.seqSource = seqSource
            self.seq = seqSource?() ?? 0
            self.onFinish = onFinish
            self.onSettled = onSettled
        }
    }

    init(schedule: Schedule? = nil) {
        self.schedule = schedule ?? { seconds, fire in
            let t = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !Task.isCancelled { fire() }
            }
            return { t.cancel() }
        }
    }

    /// §B0 "Applies" + "Starts synchronously" — pending iff the step can be pending (a delegate is set
    /// and its raw blocks reference `hook_data`), its override is not already cached, and this
    /// presentation has not ended its pending phase.
    /// `cached` is an autoclosure: it is evaluated only for a serial with no latch yet, so the
    /// referenced-keys walk runs once per presentation, not on every body pass.
    func isPending(presentation: Int, applies: Bool, cached: @autoclosure () -> Bool) -> Bool {
        let latched: Bool
        if let c = cachedAtArrival[presentation] {
            latched = c
        } else {
            let cached = cached()
            cachedAtArrival[presentation] = cached
            latched = cached
        }
        return applies && !latched && !endedPresentations.contains(presentation)
    }

    /// Start the delegate call for `presentation` as the LATEST generation. `onFinish` receives the
    /// reply (nil on deadline or when the host returned nil) exactly once, and only if this call is
    /// still the latest when it finishes. `onSettled` runs once when the call finishes (reply or
    /// deadline) WHETHER OR NOT it is still the latest — the step-view side effect — after `onFinish`.
    ///
    /// SPEC-496 §5b C3 — `seq` draws the flow-level `callSeq` at the call's START (every re-fire draws
    /// a fresh, larger value), and `onFinish` receives it beside the reply: the renderer records it as
    /// the step's `baseStamp`.
    func start(
        presentation: Int,
        timeout: TimeInterval = HostDataPendingCoordinator.defaultTimeout,
        seq: (() -> Int)? = nil,
        call: @escaping Call,
        onSettled: @escaping () -> Void = {},
        onFinish: @escaping (StepConfigOverride?, Int) -> Void
    ) {
        generation += 1
        let f = InFlight(generation: generation, presentation: presentation, call: call, timeout: timeout,
                         seqSource: seq, onSettled: onSettled, onFinish: onFinish)
        inFlight = f
        launch(f)
    }

    private func launch(_ f: InFlight) {
        f.task = Task { [weak self] in
            let reply = await f.call()
            await MainActor.run { self?.finish(f, reply: reply, timedOut: false) }
        }
        f.cancelDeadline = schedule(f.timeout) { [weak self] in
            self?.finish(f, reply: nil, timedOut: true)
        }
    }

    /// Resumed exactly once per call: whichever of reply / deadline comes first.
    private func finish(_ f: InFlight, reply: StepConfigOverride?, timedOut: Bool) {
        guard !f.finished else { return } // a reply after the deadline is dropped
        f.finished = true
        f.cancelDeadline?()
        if timedOut { f.task?.cancel() } // cooperative only — the deadline never waits on it
        // Only the latest call ends pending and applies its reply; a superseded one (the user left
        // the step, or it was re-presented) must not rewrite the current presentation.
        if f.generation == generation {
            if inFlight === f { inFlight = nil }
            endedPresentations.insert(f.presentation)
            f.onFinish(reply, f.seq)
        }
        // The step view is NOT generation-gated: every call that finished was a step view.
        f.onSettled()
    }

    /// §B0 "Cancelled before replying" — cancel the in-flight call (e.g. its owner went away). A
    /// cancellation before the reply does not end pending: the call is re-fired once, as the latest
    /// generation, with a fresh deadline.
    func cancelInFlight() {
        guard let f = inFlight, !f.finished else { return }
        f.finished = true
        f.cancelDeadline?()
        f.task?.cancel()
        inFlight = nil
        guard !refiredPresentations.contains(f.presentation) else { return }
        refiredPresentations.insert(f.presentation)
        start(presentation: f.presentation, timeout: f.timeout, seq: f.seqSource, call: f.call, onSettled: f.onSettled, onFinish: f.onFinish)
    }
}

/// Races an async producer against a deadline — a race between an unstructured `Task` and a
/// continuation resumed EXACTLY ONCE by whichever side finishes first. Returns nil on expiry.
///
/// 🔴 SPEC-496 §B0 — this used to be a task group that called `cancelAll()` and then implicitly
/// awaited every child before returning, so a host that ignored cancellation held the step past its
/// "3 s" timeout indefinitely. The losing producer is cancelled but never awaited.
func withOverrideTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T?
) async -> T? {
    let once = ResumeOnce()
    return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let producer = Task {
            let v = await operation()
            if once.claim() { cont.resume(returning: v) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if once.claim() {
                producer.cancel()
                cont.resume(returning: nil)
            }
        }
    }
}

/// A one-shot latch: the first `claim()` wins, every later one loses.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    init() {}
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
