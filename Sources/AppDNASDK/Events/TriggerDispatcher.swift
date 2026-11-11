import Foundation

/**
 Routes every tracked event — the host's AND the SDK's own — to in-app message and survey trigger
 evaluation, exactly once per event, in tracking order.

 🔴 Why this exists. Trigger evaluation used to be called from one place: the public
 `AppDNA.track`. Every event the SDK tracks itself (`app_open`, `session_start`,
 `onboarding_flow_completed`, the billing events, `paywall_dismissed`, …) goes to `EventTracker.track`
 directly, so none of them could ever show a message or a survey — including the console's default
 in-app message trigger, `app_open`. `EventTracker.track` is the one place every event passes
 through, so it hands each event here, and nothing else calls the managers' `onEvent`.

 Three rules, each pinned by the shared fixture `event_emission/sdk_events_reach_message_and_survey_triggers`:

 1. **Held until the SDK can answer.** An event tracked before the managers exist (the session start
    and the cold-launch `app_open` fire long before the bootstrap finishes) or before the config is
    ready (no config cached on disk and the first fetch not yet back) is HELD, in order, and evaluated
    once both are true. A config already cached on disk, or bundled in the app, counts as ready at once — a stale cache is the
    config the SDK serves everywhere else too, and the fetch refreshes it for the next event. The hold
    is bounded (`pendingCap`, oldest dropped) so an app that never reaches the server cannot grow it.
 2. **A surface never triggers on its own events.** A message does not evaluate `in_app_message_*`, a
    survey does not evaluate `survey_*` — the events a presentation emits — so a presentation cannot
    re-trigger its own surface. The other surface still sees them (a message authored on
    `survey_completed` is a deliberate follow-up). Internal `_`-prefixed events reach neither.
 3. **No re-entry.** An event tracked WHILE an event is being evaluated (a presentation tracking its
    `*_shown`) is queued behind it and evaluated after, never recursively. One drain loop at a time.
 */
final class TriggerDispatcher {
    enum Surface: String {
        case message
        case survey
    }

    /// The events an in-app message presentation tracks. A message never triggers on these.
    static let messageOwnEvents: Set<String> = [
        "in_app_message_shown",
        "in_app_message_clicked",
        "in_app_message_dismissed",
        "in_app_message_received",
    ]

    /// The events a survey presentation tracks. A survey never triggers on these.
    static let surveyOwnEvents: Set<String> = [
        "survey_shown",
        "survey_question_answered",
        "survey_completed",
        "survey_dismissed",
        "survey_feedback_submitted",
        "survey_followup_feedback_form",
        "survey_followup_prompt_review",
        "survey_followup_winback",
    ]

    /// Events held while the SDK is not ready to evaluate. Oldest dropped beyond this.
    static let pendingCap = 32

    /// Which surfaces evaluate `event`, in evaluation order (message, then survey — the order a host
    /// event has always used, and the order Android uses).
    static func surfaces(for event: String) -> [Surface] {
        if event.isEmpty || event.hasPrefix("_") { return [] }
        var out: [Surface] = []
        if !messageOwnEvents.contains(event) { out.append(.message) }
        if !surveyOwnEvents.contains(event) { out.append(.survey) }
        return out
    }

    typealias Evaluator = (_ surface: Surface, _ event: String, _ properties: [String: Any]?) -> Void
    private typealias Item = (event: String, properties: [String: Any]?)

    private let lock = NSLock()
    private let executor: (@escaping () -> Void) -> Void
    private var evaluator: Evaluator?
    private var configReady = false
    private var pending: [Item] = []
    private var inbox: [Item] = []
    private var draining = false
    private var _droppedWhileHeld = 0

    /// - Parameter executor: where the drain loop runs. Production: the SDK's serial queue, where host
    ///   events have always been evaluated. Tests: inline.
    init(executor: @escaping (@escaping () -> Void) -> Void) {
        self.executor = executor
    }

    /// Events dropped from the hold because it was full.
    var droppedWhileHeld: Int {
        lock.lock(); defer { lock.unlock() }
        return _droppedWhileHeld
    }

    /// Events currently held, oldest first. Test reader.
    var heldEventNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return pending.map { $0.event }
    }

    /// Called by `EventTracker.track` for every event it is handed.
    func record(event: String, properties: [String: Any]?) {
        guard !Self.surfaces(for: event).isEmpty else { return }
        lock.lock()
        guard evaluator != nil, configReady else {
            if pending.count >= Self.pendingCap {
                pending.removeFirst()
                _droppedWhileHeld += 1
            }
            pending.append((event, properties))
            lock.unlock()
            return
        }
        inbox.append((event, properties))
        let start = !draining
        if start { draining = true }
        lock.unlock()
        if start { executor { [self] in drain() } }
    }

    /// The managers exist. Releases the hold if the config is also ready.
    func attach(_ evaluator: @escaping Evaluator) {
        lock.lock()
        self.evaluator = evaluator
        let start = releaseHeldLocked()
        lock.unlock()
        if start { executor { [self] in drain() } }
    }

    /// The config is ready (cached on disk at launch, or the first fetch reached the server). Releases
    /// the hold if the managers also exist. Idempotent: a later fetch changes nothing.
    func markConfigReady() {
        lock.lock()
        configReady = true
        let start = releaseHeldLocked()
        lock.unlock()
        if start { executor { [self] in drain() } }
    }

    /// `shutdown()`: forget the managers and everything held or queued.
    func detach() {
        lock.lock()
        evaluator = nil
        configReady = false
        pending.removeAll()
        inbox.removeAll()
        lock.unlock()
    }

    private func releaseHeldLocked() -> Bool {
        guard evaluator != nil, configReady, !pending.isEmpty else { return false }
        inbox.append(contentsOf: pending)
        pending.removeAll()
        guard !draining else { return false }
        draining = true
        return true
    }

    private func drain() {
        while true {
            lock.lock()
            guard !inbox.isEmpty, let evaluator else {
                draining = false
                lock.unlock()
                return
            }
            let item = inbox.removeFirst()
            lock.unlock()
            for surface in Self.surfaces(for: item.event) {
                evaluator(surface, item.event, item.properties)
            }
        }
    }
}
