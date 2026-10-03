import Foundation

/// Builds SDKEvent envelopes from current identity and queues them.
final class EventTracker {
    private let identityManager: IdentityManager
    private weak var eventQueue: EventQueue?
    private var analyticsConsent = true

    /// Lazy supplier of the currently-visible screen name, so every
    /// envelope carries `context.screen`. Returns nil before any screen is announced. This is the
    /// iOS half of a chain Android already had end to end (`EventTracker.kt:65`).
    private var screenProvider: (() -> String?)?

    /// Source of the active experiment exposures, attached to EVERY event envelope as
    /// `context.experiment_exposures`. Android wires this end to end (`AppDNA.kt` →
    /// `setExperimentExposureProvider`); iOS had the envelope field and a `trackWithExposures` method
    /// with ZERO callers, so every iOS event shipped `experiment_exposures = nil`. Nil in tests.
    private var experimentExposureProvider: (() -> [ExperimentExposure]?)?

    /// Source of the current push_id (within the 30-min window), attached to every envelope as
    /// `context.push_id`. Mirrors Android's push-id provider. Nil in tests.
    private var pushIdProvider: (() -> String?)?

    init(identityManager: IdentityManager) {
        self.identityManager = identityManager
    }

    func setEventQueue(_ queue: EventQueue) {
        self.eventQueue = queue
    }

    /// Wire the screen-name source. Passing nil disables the field (used in tests).
    func setScreenProvider(_ provider: (() -> String?)?) {
        self.screenProvider = provider
    }

    /// Wire the experiment-exposure source. Passing nil disables the field. Mirrors Android's
    /// `setExperimentExposureProvider`.
    func setExperimentExposureProvider(_ provider: (() -> [ExperimentExposure]?)?) {
        self.experimentExposureProvider = provider
    }

    /// Wire the push-id source. Passing nil disables the field. Mirrors Android's push-id provider.
    func setPushIdProvider(_ provider: (() -> String?)?) {
        self.pushIdProvider = provider
    }

    /// Test-only observation seam. The built envelope is otherwise unobservable — it goes straight
    /// into `EventQueue` (a concrete final class that needs an APIClient + EventStore), so a test can
    /// never see what the SDK actually emitted. That is why the shared-fixture runner used to MIRROR
    /// the SDK's logic instead of calling it, which meant the fixtures asserted against the test's own
    /// copy of the rules, not the SDK's. Nil in production: zero cost, no behavior change.
    internal var eventSink: ((SDKEvent) -> Void)?

    /// Apply the persisted consent decision at `configure()` time.
    /// Unlike `setConsent`, this does NOT purge the queue — events persisted during an earlier,
    /// consented session are not a revocation, and startup is not the moment to delete them.
    func setInitialConsent(analytics: Bool) {
        analyticsConsent = analytics
    }

    /// Set analytics consent. When false, track() silently drops events AND any already-queued
    /// events are purged.
    func setConsent(analytics: Bool) {
        analyticsConsent = analytics
        // Revoking consent MUST purge any queued-but-unsent events (in-memory + on-disk) WITHOUT
        // uploading — else the server-side consent gate is defeated by a later flush of events
        // captured while consent was true.
        if !analytics {
            eventQueue?.clear()
        }
    }

    /// Whether analytics consent is currently granted.
    var isConsentGranted: Bool { analyticsConsent }

    /// Track an event. If consent is false, the event is silently dropped.
    func track(event: String, properties: [String: Any]?, clientSeq: Int64? = nil) {
        guard analyticsConsent else {
            Log.debug("Event '\(event)' dropped — analytics consent is false")
            return
        }

        // Surface any silently-dropped events (cap/quota evictions) as a
        // _sdk_events_dropped meta-event so the loss is SERVER-VISIBLE. Drain before the real event;
        // guard against the meta-event itself re-triggering the drain.
        if event != "_sdk_events_dropped" {
            // PEEK (don't reset) — the count is decremented only after the meta is durable
            // (in emitDroppedMeta's onPersisted), so a crash before the meta lands re-emits it (no under-count).
            let dropped = DroppedEventsCounter.peek()
            if dropped > 0 { emitDroppedMeta(count: dropped) }
        }

        let identity = identityManager.currentIdentity
        let sessionId = identityManager.sessionManager?.sessionId ?? "unknown"

        let sdkEvent = EventEnvelopeBuilder.build(
            event: event,
            properties: properties,
            identity: identity,
            sessionId: sessionId,
            analyticsConsent: analyticsConsent,
            experimentExposures: experimentExposureProvider?() ?? nil,
            screen: screenProvider?(),
            pushId: pushIdProvider?() ?? nil,
            clientSeq: clientSeq // A pre-init event carries the seq it stamped at track() time
        )

        eventQueue?.enqueue(sdkEvent)
        eventSink?(sdkEvent)
        Log.debug("Tracked event: \(event)")
    }

    /// Build + enqueue the _sdk_events_dropped meta-event directly (NOT via track(),
    /// to avoid re-entrancy). The count reflects events evicted since the last drain.
    private func emitDroppedMeta(count: Int) {
        let identity = identityManager.currentIdentity
        let sessionId = identityManager.sessionManager?.sessionId ?? "unknown"
        let ev = EventEnvelopeBuilder.build(
            event: "_sdk_events_dropped",
            properties: ["count": count],
            identity: identity,
            sessionId: sessionId,
            analyticsConsent: analyticsConsent,
            experimentExposures: experimentExposureProvider?() ?? nil,
            screen: screenProvider?(),
            pushId: pushIdProvider?() ?? nil
        )
        // Decrement by exactly `count` ONLY after the meta is durably persisted (never a
        // zero-reset). Crash before persist → counter keeps `count` → re-emit (no under-count).
        eventQueue?.enqueue(ev, onPersisted: { DroppedEventsCounter.subtract(count) })
        eventSink?(ev)
        Log.debug("Emitted _sdk_events_dropped meta-event (count=\(count))")
    }

    // NB: the old `trackWithExposures(...)` method was removed — it had ZERO callers, so iOS shipped
    // `experiment_exposures = nil` on every event. `track(...)` now attaches exposures from
    // `experimentExposureProvider` on the primary path, matching Android.
}
