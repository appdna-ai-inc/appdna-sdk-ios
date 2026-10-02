import Foundation
import UIKit

/// SPEC-428 CL-9/D4 — process-wide single upload owner. The in-process flush (EventQueue) and the
/// background uploader (BackgroundUploader) must be mutually exclusive, else both POST the same rows
/// concurrently (DUP). A non-blocking claim: whoever holds it uploads; the other skips this cycle.
enum EventUploadCoordinator {
    private static let lock = NSLock()
    private static var uploading = false

    static func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if uploading { return false }
        uploading = true
        return true
    }

    static func release() {
        lock.lock()
        defer { lock.unlock() }
        uploading = false
    }

    /// The `event_id`s an upload owner resolved (delivered, or dropped on a permanent 4xx) in this process,
    /// most recent `maxResolved`. The claim stops two owners POSTing at once, not one owner re-sending what
    /// another already sent: a queue holds in-memory copies of the events it loaded from disk, and the
    /// background uploader — or the last upload of a queue `shutdown()` ended, while the next `configure()`'s
    /// queue loaded the same events — removes them from disk only. Every owner records what it resolved
    /// here while it holds the claim; a queue drops those from memory before it uploads. Android
    /// `EventUploadCoordinator.markResolved`, same rule.
    static let maxResolved = 10_000
    private static var resolved: [String] = []
    private static var resolvedSet: Set<String> = []

    static func markResolved<S: Sequence>(_ ids: S) where S.Element == String {
        lock.lock()
        defer { lock.unlock() }
        for id in ids where !id.isEmpty && !resolvedSet.contains(id) {
            resolved.append(id)
            resolvedSet.insert(id)
        }
        if resolved.count > maxResolved {
            let drop = resolved.count - maxResolved
            for id in resolved.prefix(drop) { resolvedSet.remove(id) }
            resolved.removeFirst(drop)
        }
    }

    static func wasResolved(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolvedSet.contains(id)
    }

    static func clearResolvedForTesting() {
        lock.lock(); resolved.removeAll(); resolvedSet.removeAll(); lock.unlock()
    }
}

/// The event queue's failure pause (paused after `maxConsecutiveFailures` failed upload cycles), persisted so
/// the background uploader can honour it. The pause lives in the queue's memory; the BGProcessingTask runs
/// outside the queue and used to upload whatever the pause said, so backgrounding a paused app started exactly
/// the uploads the pause stops. The queue writes the gate when it pauses and when a foreground or
/// `AppDNA.flush()` clears the pause, and clears it when a new queue starts (a new `configure()` starts
/// unpaused, in memory and here alike); the uploader reads it before it uploads. Android `UploadPauseGate`,
/// same rule.
enum UploadPauseGate {
    private static let key = "ai.appdna.sdk.upload_paused"
    static func set(_ paused: Bool) { UserDefaults.standard.set(paused, forKey: key) }
    static var isPaused: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Manages in-memory + disk event queue with automatic flushing.
/// SPEC-067: Adaptive batch sizing based on network conditions.
final class EventQueue {
    private let queue = DispatchQueue(label: "ai.appdna.sdk.eventqueue")
    private let apiClient: APIClient
    private let eventStore: EventStore
    private let baseBatchSize: Int
    private let flushInterval: TimeInterval
    /// SPEC-070-B AC-35 (`backoff_bounded_and_jittered`) — the retry schedule is a STATIC seam, so the
    /// shared resilience fixture can assert the same three numbers against iOS and Android. As
    /// instance-private `let`s they were unreachable from a test, and the two platforms' schedules
    /// could drift with nothing to notice: bounded backoff is only bounded if somebody checks the
    /// bound. Mirrors Android `EventQueue.MAX_RETRIES` / `RETRY_DELAYS_MS`.
    static let maxRetries = 3
    static let retryBaseDelays: [TimeInterval] = [1, 2, 4]

    private let maxRetries = EventQueue.maxRetries
    private let retryDelays: [TimeInterval] = EventQueue.retryBaseDelays

    /// The jitter fraction applied to every backoff delay. Mirrors Android `EventQueue.JITTER_PCT`.
    /// A named constant, not a literal inside `jittered`, so the shared `backoff_bounded_and_jittered`
    /// fixture can assert that the two platforms spread by the SAME amount.
    static let jitterFraction = 0.25

    /// Applies ±25% full jitter to a backoff delay, matching Android's
    /// `EventQueue.kt`. Without it, every client throttled by the same 429 retries
    /// on the identical wall clock and stampedes the server again.
    static func jittered(_ base: TimeInterval) -> TimeInterval {
        let spread = base * jitterFraction
        return max(0, base + TimeInterval.random(in: -spread...spread))
    }
    // SPEC-428 CL-2/D5: client redelivery horizon — never re-send an event older than this (past the
    // server dedup window it would double-count). Compiled default 7d, tracking SPEC-426's horizon.
    private let redeliveryHorizonMs: Int64 = 7 * 24 * 60 * 60 * 1000

    private var pendingEvents: [SDKEvent] = []
    private var flushTimer: Timer?
    private var retryCount = 0
    private var consecutiveFailures = 0
    // SPEC-428 CL-5/D4: single-flush-authority guard (mirrors Android's flushMutex). Set on the serial
    // `queue`; a second performFlush while a batch is in-flight would grab the same prefix + POST it
    // twice (removal happens only AFTER the async upload awaits).
    private var isFlushing = false
    private let maxConsecutiveFailures = 5
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// SPEC-067: Returns the current effective batch size based on network conditions.
    private var effectiveBatchSize: Int {
        NetworkMonitor.shared.adaptiveBatchSize
    }

    init(
        apiClient: APIClient,
        eventStore: EventStore,
        eventTracker: EventTracker,
        batchSize: Int,
        flushInterval: TimeInterval
    ) {
        self.apiClient = apiClient
        self.eventStore = eventStore
        self.baseBatchSize = batchSize
        self.flushInterval = flushInterval

        // A new queue (a new `configure()`) starts unpaused; so does the gate the background uploader reads.
        UploadPauseGate.set(false)

        // Load persisted events from disk
        let persisted = eventStore.loadPending()
        if !persisted.isEmpty {
            // SPEC-428 P1: trim the in-memory window to maxInMemoryEvents on load — disk keeps them
            // all, RAM holds only the most-recent 1000. iOS previously assigned the full disk load
            // (up to the 10k disk cap) into RAM after restart, violating its own maxInMemoryEvents
            // (Android already trims after load).
            self.pendingEvents = persisted.count > maxInMemoryEvents
                ? Array(persisted.suffix(maxInMemoryEvents))
                : persisted
            Log.info("Loaded \(persisted.count) persisted events from disk (\(self.pendingEvents.count) held in memory)")
        }

        // Start flush timer on main run loop
        DispatchQueue.main.async { [weak self] in
            self?.startFlushTimer()
        }

        // Observe app backgrounding for flush + background upload
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        // Round-14 F1 — observe foregrounding to CLEAR the consecutive-failure pause latch and retry.
        // Without this, 5 transient upload failures paused the in-process queue for the REMAINDER of the
        // process's life (consecutiveFailures only reset on a successful upload or a fresh EventQueue), so
        // after a transient ingest outage iOS event delivery stalled until force-quit — while Android
        // self-heals on the next foreground (ProcessLifecycleOwner onStart). This brings iOS into parity.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        flushTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// Maximum in-memory events. Beyond this, oldest events are dropped (still on disk).
    private let maxInMemoryEvents = 1000

    /// Add an event to the queue. Triggers threshold flush if adaptive batch size reached.
    /// `onPersisted` (SPEC-428 STEP-4) fires on the serial queue AFTER the event is durably on disk —
    /// used by the dropped-meta path to decrement the loss counter only once its meta is safe.
    func enqueue(_ event: SDKEvent, onPersisted: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }

            // Cap in-memory events to prevent memory pressure
            if self.pendingEvents.count >= self.maxInMemoryEvents {
                self.pendingEvents.removeFirst(self.pendingEvents.count - self.maxInMemoryEvents + 1)
            }
            self.pendingEvents.append(event)

            // Persist to disk immediately
            self.eventStore.save(events: [event])
            onPersisted?() // SPEC-428 STEP-4: meta now durable → safe to decrement the drop counter

            // SPEC-067: Check adaptive threshold. A threshold flush keeps the failure pause: during an
            // outage every `track()` reaching the batch size would otherwise run a full upload cycle.
            let currentBatchSize = self.effectiveBatchSize
            if currentBatchSize > 0 && self.pendingEvents.count >= currentBatchSize {
                self.runFlush(.threshold)
            }
        }
    }

    /// Who asked for a flush — and so whether it clears the failure pause (`consecutiveFailures`,
    /// paused at `maxConsecutiveFailures`). Only the app coming to the foreground and the host's own
    /// `AppDNA.flush()` give a paused queue another chance; the batch threshold, the interval timer,
    /// a retry's backoff, backgrounding and `shutdown()` keep the pause, so a failing server is not
    /// hammered by every `track()` or every 30 s tick. Android's `EventQueue.FlushTrigger` is the same
    /// table; the shared `flush_pause_gate` fixture asserts both.
    enum FlushTrigger: String, CaseIterable {
        case threshold, scheduled, background, shutdown, foreground, explicit

        var clearsPauseGate: Bool {
            switch self {
            case .foreground, .explicit: return true
            case .threshold, .scheduled, .background, .shutdown: return false
            }
        }
    }

    /// A scheduled flush — the interval timer and a retry's backoff. Keeps the failure pause.
    func flush() {
        flush(.scheduled)
    }

    /// Host-initiated flush (`AppDNA.flush()`): clears the failure-pause gate first so a queue paused
    /// after N failures gets another chance. Matches Android's public `flush()`.
    func flushClearingPause() {
        flush(.explicit)
    }

    /// `AppDNA.shutdown()`'s one last upload attempt of the queued events. The queue is captured
    /// strongly until the attempt has finished: `shutdown()` drops its reference right after this call,
    /// and with a weak capture the attempt never ran — or ran without its queue and left the process-wide
    /// upload claim (`EventUploadCoordinator`) held, so no later queue in the process could upload.
    /// What the attempt does not send stays on disk for the next `configure`. Keeps the failure pause.
    func flushForShutdown() {
        Self.uploadActivity.begin()
        queue.async { [self] in
            self.runFlush(.shutdown)
            Self.uploadActivity.end()
        }
    }

    /// Shutdown flushes not yet run plus uploads not yet resolved, process-wide. Test-only reader
    /// (`uploadsInFlightForTesting`): a test that shuts a configured SDK down waits for this to reach 0
    /// before it restores what the upload's outcome may have touched (the dropped-events counter).
    final class ActivityCounter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func begin() { lock.lock(); n += 1; lock.unlock() }
        func end() { lock.lock(); n -= 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    static let uploadActivity = ActivityCounter()
    static var uploadsInFlightForTesting: Int { uploadActivity.value }

    func flush(_ trigger: FlushTrigger) {
        queue.async { [weak self] in
            self?.runFlush(trigger)
        }
    }

    /// On `queue`.
    private func runFlush(_ trigger: FlushTrigger) {
        if trigger.clearsPauseGate {
            consecutiveFailures = 0
            UploadPauseGate.set(false)
        }
        performFlush()
    }

    /// SPEC-424 STEP-1a (CL-7): purge ALL pending events (in-memory + on-disk) WITHOUT uploading —
    /// called when analytics consent is revoked so queued-but-unsent events are never transmitted.
    /// A server-side consent gate is defeated if the SDK later flushes events captured while consent
    /// was true, so revoke must drop them at the source.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingEvents.removeAll()
            self.eventStore.clearAll()
            Log.info("Event queue purged — analytics consent revoked")
        }
    }

    // MARK: - Private

    private func startFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }

    @objc private func appWillEnterForeground() {
        // Round-14 F1 — clear the failure-pause latch on foreground so a queue paused by a transient
        // outage resumes (mirrors Android onAppForeground: paused=false; consecutiveFailures=0), then
        // attempt a drain. Reset on the serial queue to stay consistent with all other failure-count writes.
        queue.async { [weak self] in
            guard let self else { return }
            if self.consecutiveFailures >= self.maxConsecutiveFailures {
                Log.info("Foregrounded — clearing event-upload pause and retrying")
            }
            self.runFlush(.foreground)
        }
    }

    @objc private func appDidEnterBackground() {
        enterBackground(holdBackgroundTask: true)
    }

    /// The app went to the background: flush, then schedule the background upload unless paused. A test drives
    /// it with `holdBackgroundTask: false` (no `UIApplication` background task).
    func enterBackground(holdBackgroundTask: Bool) {
        if holdBackgroundTask {
            // Guard against duplicate background tasks
            guard backgroundTask == .invalid else { return }

            // Request background time to ensure flush completes before suspension
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                self?.endBackgroundTask()
            }
        }
        flush(.background)
        // End background task after flush dispatch completes on the same serial queue
        queue.async { [weak self] in
            guard let self else { return }
            self.endBackgroundTask()
            // SPEC-067: Schedule background upload for remaining events — unless the queue is paused:
            // backgrounding keeps the pause, and a background upload would bypass it.
            if self.consecutiveFailures >= self.maxConsecutiveFailures {
                Log.debug("Uploads paused — no background upload scheduled until the next foreground / AppDNA.flush()")
            } else {
                (Self.scheduleBackgroundUploadForTesting ?? { BackgroundUploader.shared?.scheduleUploadIfNeeded() })()
            }
        }
    }

    /// Test seam: replaces the background-upload schedule `appDidEnterBackground` makes (nil in production).
    static var scheduleBackgroundUploadForTesting: (() -> Void)?

    /// Test seam: the state after `maxConsecutiveFailures` failed cycles (the pause, and its persisted gate).
    func pauseForTesting() {
        queue.sync {
            consecutiveFailures = maxConsecutiveFailures
            UploadPauseGate.set(true)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// SPEC-428 CL-2/D5: drop events past the redelivery horizon before any flush — re-sending them
    /// past the server dedup window would double-count. The drop is counted (CL-1).
    private func pruneStaleEvents() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Remove stale from the in-memory working set only (NO count here); eventStore.pruneStale is the
        // SINGLE, meta-aware count source (the persisted copies of these events live on disk), so the loss
        // metric can't be double-incremented by the in-process flush AND the background upload both pruning.
        // SPEC-070-B PN row 19 (W14): the same clock-jump clamp the store uses — otherwise the
        // in-memory set and the disk set disagree about what is stale.
        pendingEvents.removeAll { EventStore.isStale(tsMs: $0.ts_ms, nowMs: nowMs, horizonMs: redeliveryHorizonMs) }
        eventStore.pruneStale(horizonMs: redeliveryHorizonMs)
    }

    private func performFlush() {
        // Already on queue
        pruneStaleEvents()
        guard !pendingEvents.isEmpty else { return }

        // Stop hammering the server after repeated failures — wait for next app session
        if consecutiveFailures >= maxConsecutiveFailures {
            Log.debug("Paused event flush after \(consecutiveFailures) consecutive failures. Events saved to disk.")
            return
        }

        // SPEC-067: Skip flush if no network
        let currentBatchSize = effectiveBatchSize
        guard currentBatchSize > 0 else {
            Log.debug("No network — skipping flush, \(pendingEvents.count) events queued")
            return
        }

        // SPEC-428 CL-5: only one flush may be in-flight — otherwise a timer/threshold/retry/background
        // flush grabs the same prefix before the async removal and POSTs it twice.
        guard !isFlushing else {
            Log.debug("Flush already in progress — skipping overlapping flush")
            return
        }
        isFlushing = true

        // SPEC-428 CL-9/D4: also claim the cross-path upload owner so the background uploader cannot
        // POST the same batch concurrently. If the background path holds it, back off this cycle.
        guard EventUploadCoordinator.tryAcquire() else {
            isFlushing = false
            Log.debug("Flush deferred — background uploader is active")
            return
        }

        // Events another upload owner already resolved — the background uploader, or the last upload of a
        // queue `shutdown()` ended while this one loaded the same events from disk — are not sent again:
        // that owner removed them from disk, but this queue still holds its in-memory copies.
        let before = pendingEvents.count
        pendingEvents.removeAll { EventUploadCoordinator.wasResolved($0.event_id) }
        if pendingEvents.count != before {
            Log.debug("Skipped \(before - pendingEvents.count) event(s) another upload already delivered")
        }
        guard !pendingEvents.isEmpty else {
            isFlushing = false
            EventUploadCoordinator.release()
            return
        }

        let batch = Array(pendingEvents.prefix(currentBatchSize > 0 ? currentBatchSize : pendingEvents.count))
        let eventIds = Set(batch.map(\.event_id))

        Log.debug("Flushing \(batch.count) events")

        let payload: [String: Any] = ["batch": batch.map { event -> [String: Any] in
            guard let data = try? JSONEncoder().encode(event),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return dict
        }]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            Log.error("Failed to serialize event batch")
            isFlushing = false // CL-5: release the guard on this early-return path
            EventUploadCoordinator.release() // CL-9: release the cross-path claim
            return
        }

        // Strong: the upload always finishes and releases the flush guard and the process-wide upload
        // claim below, even when the queue's owner let go meanwhile (`flushForShutdown`). With a weak
        // capture a released queue returned here and the claim stayed held for the rest of the process.
        Self.uploadActivity.begin()
        Task { [self] in
            let success = await self.apiClient.sendEvents(bodyData)

            self.queue.async {
                if success {
                    // Remove sent events from memory and disk
                    self.pendingEvents.removeAll { eventIds.contains($0.event_id) }
                    self.eventStore.removeSent(eventIds: eventIds)
                    EventUploadCoordinator.markResolved(eventIds)
                    self.retryCount = 0
                    self.consecutiveFailures = 0
                    Log.debug("Flush successful: \(batch.count) events delivered")
                } else if self.apiClient.eventUploadPermanentlyFailed {
                    // 🔴 DROP THE POISON BATCH — don't just pause. A permanent 4xx (400 malformed /
                    // 401 bad key, NOT 408/429) fails identically forever, and `flush()` always takes
                    // the OLDEST `batchSize` events (`prefix`, above). Pausing WITHOUT removing this
                    // batch leaves it at the head of `pendingEvents`; the pause latch resets each new
                    // session, so it re-POSTs, 4xxs, and re-pauses forever — head-of-line-blocking
                    // EVERY later event until the 7-day disk horizon evicts it. Android drops it (see
                    // EventQueue.kt ClientError branch); iOS must too. The whole batch is a real loss
                    // (a 401 drops valid events, a 400 malformed ones), so count it into the
                    // server-visible dropped counter — each normal event +1, plus any carried
                    // `_sdk_events_dropped` meta count — so nothing vanishes silently.
                    var loss = 0
                    for event in batch {
                        if event.event_name == "_sdk_events_dropped" {
                            loss += (event.properties?["count"]?.value as? Int) ?? 0
                        } else {
                            loss += 1
                        }
                    }
                    if loss > 0 { DroppedEventsCounter.increment(loss) }
                    self.pendingEvents.removeAll { eventIds.contains($0.event_id) }
                    self.eventStore.removeSent(eventIds: eventIds)
                    EventUploadCoordinator.markResolved(eventIds)
                    // Round-31 — INCREMENT the failure latch (was: jump straight to
                    // maxConsecutiveFailures). The poison batch is already dropped above, so a
                    // single 400 (one malformed event) must NOT pause the whole queue for the
                    // session — that stalled every subsequent HEALTHY event until foreground.
                    // Android increments here (bumpFailureCounter → pause only at 5); iOS now
                    // matches, so it pauses only on SUSTAINED failure (e.g. a persistent 401),
                    // and a lone bad batch self-heals on the next successful flush.
                    self.consecutiveFailures += 1
                    self.retryCount = 0
                    if self.consecutiveFailures >= self.maxConsecutiveFailures {
                        UploadPauseGate.set(true)
                        Log.error("Dropped batch of \(batch.count) after permanent 4xx; \(self.consecutiveFailures) consecutive failures — uploads paused until next foreground.")
                    } else {
                        Log.error("Dropping batch of \(batch.count) events after permanent 4xx (retry won't help); continuing with next batch.")
                    }
                } else {
                    if self.retryCount < self.maxRetries {
                        // A server-supplied Retry-After wins over our backoff schedule.
                        // Otherwise: exponential base + jitter, so a fleet that was
                        // throttled together does not retry in lockstep. Matches Android.
                        let base = self.retryDelays[min(self.retryCount, self.retryDelays.count - 1)]
                        let delay = self.apiClient.consumeRetryAfter() ?? Self.jittered(base)
                        self.retryCount += 1
                        Log.debug("Flush failed, retrying in \(String(format: "%.2f", delay))s (attempt \(self.retryCount)/\(self.maxRetries))")
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.flush(.scheduled)
                        }
                    } else {
                        self.consecutiveFailures += 1
                        self.retryCount = 0
                        if self.consecutiveFailures >= self.maxConsecutiveFailures {
                            UploadPauseGate.set(true)
                            Log.warning("Too many consecutive flush failures (\(self.consecutiveFailures)). Event uploads paused until next session.")
                        } else {
                            Log.warning("Max retries reached (\(self.maxRetries)). Will try again on next flush cycle.")
                        }
                    }
                }
                // SPEC-428 CL-5: release the single-flush guard once this batch's upload is resolved
                // (success removal, permanent-fail pause, or retry scheduled).
                self.isFlushing = false
                EventUploadCoordinator.release() // SPEC-428 CL-9: release the cross-path upload claim
                Self.uploadActivity.end()
            }
        }
    }
}
