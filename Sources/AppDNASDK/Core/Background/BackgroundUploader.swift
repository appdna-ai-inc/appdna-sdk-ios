import Foundation
import BackgroundTasks
import UIKit

/// Background event upload using BGTaskScheduler.
/// Ensures queued events are delivered even when the app is backgrounded.
final class BackgroundUploader {
    /// Task identifier — must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let taskIdentifier = "ai.appdna.sdk.eventUpload"

    /// Shared instance, set during SDK init (after registration).
    static var shared: BackgroundUploader?

    /// Tracks whether BGTaskScheduler.register has been called successfully.
    /// Apple requires this to happen BEFORE application(_:didFinishLaunchingWithOptions:)
    /// returns — calling it later crashes with "All launch handlers must be registered
    /// before application finishes launching".
    private static var didRegister = false

    /// Returns true once `registerBackgroundTaskIdentifier()` has completed.
    static var isRegistered: Bool { didRegister }

    private weak var apiClient: APIClient?
    private let eventStore: EventStore
    private var retryCount = 0
    private let maxRetries = 3

    init(apiClient: APIClient, eventStore: EventStore) {
        self.apiClient = apiClient
        self.eventStore = eventStore
    }

    /// Register the BGTaskScheduler identifier with a static handler that forwards
    /// to `BackgroundUploader.shared` (may be nil if SDK isn't configured yet).
    ///
    /// **MUST be called from `application(_:didFinishLaunchingWithOptions:)` BEFORE
    /// the method returns.** The host app should call `AppDNA.registerBackgroundTasks()`
    /// which delegates here.
    ///
    /// Safe to call multiple times — subsequent calls are no-ops.
    static func registerBackgroundTaskIdentifier() {
        guard !didRegister else { return }
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: taskIdentifier,
                using: nil
            ) { task in
                guard let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                // Forward to the live BackgroundUploader instance if configured.
                // If configure() hasn't run yet, there's nothing to upload — complete cleanly.
                if let shared = BackgroundUploader.shared {
                    shared.handleBackgroundTask(processingTask)
                } else {
                    Log.warning("Background task fired but AppDNA SDK not configured — skipping upload")
                    processingTask.setTaskCompleted(success: false)
                }
            }
            didRegister = true
            Log.debug("Registered background upload task: \(taskIdentifier)")
        }
    }

    /// Whether a background run may upload now: not while the queue's failure pause holds.
    static var uploadAllowed: Bool { !UploadPauseGate.isPaused }

    /// The most events one background upload sends: the network-sized batch, capped by the queue's
    /// persisted `batchSize` cap (`BatchSizeCapGate`) — the same size the in-process queue uses.
    static func uploadBatchSize(adaptive: Int) -> Int {
        RuntimeSettings.effectiveBatchSize(adaptive: adaptive, cap: BatchSizeCapGate.cap)
    }

    /// Schedule a background upload if there are pending events.
    func scheduleUploadIfNeeded() {
        guard #available(iOS 13.0, *) else { return }

        let pendingCount = eventStore.pendingCount
        guard pendingCount > 0 else {
            Log.debug("No pending events — skipping background upload schedule")
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("Scheduled background upload for \(pendingCount) pending events")
        } catch {
            Log.warning("Failed to schedule background upload: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    @available(iOS 13.0, *)
    private func handleBackgroundTask(_ task: BGProcessingTask) {
        Log.info("Background upload task started")

        task.expirationHandler = {
            Log.warning("Background upload task expired")
            task.setTaskCompleted(success: false)
        }

        Task { [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let outcome = await self.runUpload(paused: UploadPauseGate.isPaused)
            task.setTaskCompleted(success: outcome.taskSucceeded)
        }
    }

    /// What one background run came to.
    enum RunOutcome: Equatable {
        /// The SDK's API client is gone (the SDK was shut down).
        case unavailable
        /// The queue's failure pause holds: nothing uploaded, nothing rescheduled.
        case skippedPaused
        /// Another owner holds the upload claim: rescheduled.
        case deferred
        /// Nothing pending.
        case nothingToUpload
        /// No network: rescheduled.
        case noNetwork
        /// A batch was sent and accepted.
        case uploaded
        /// The server rejected the batch permanently (a genuine 4xx): it was dropped and counted.
        case droppedRejected
        /// A batch could not be built or sent.
        case failed

        /// What the BGProcessingTask reports.
        var taskSucceeded: Bool {
            switch self {
            case .skippedPaused, .deferred, .nothingToUpload, .uploaded, .droppedRejected: return true
            case .unavailable, .noNetwork, .failed: return false
            }
        }

        /// Whether the run tried to upload (sent a request).
        var attemptedUpload: Bool { self == .uploaded || self == .failed || self == .droppedRejected }
    }

    /// One run of the background upload — the body of the BGProcessingTask. `paused` is the queue's failure
    /// pause (`UploadPauseGate.isPaused` in production); `reschedule` replaces `scheduleUploadIfNeeded` (tests).
    func runUpload(paused: Bool, reschedule: (() -> Void)? = nil) async -> RunOutcome {
        let reschedule = reschedule ?? { [weak self] in self?.scheduleUploadIfNeeded() }
        guard let apiClient = self.apiClient else { return .unavailable }

        // The queue's failure pause holds for this uploader too (`UploadPauseGate`): nothing is uploaded
        // until a foreground or `AppDNA.flush()`, and nothing is rescheduled — the next backgrounding of an
        // unpaused queue schedules a fresh run.
        guard !paused else {
            Log.info("Background upload skipped — uploads are paused after repeated failures")
            return .skippedPaused
        }

        // Single upload owner — if the in-process flush holds the claim, skip
        // this background run so the same rows are never POSTed twice. `defer` releases on every
        // subsequent exit path.
        guard EventUploadCoordinator.tryAcquire() else {
            // Another owner is uploading (e.g. the last upload `shutdown()` makes). Schedule the next run
            // rather than leaving what that owner does not send for the next launch — the same rule as
            // Android's `EventUploadWorker`, which answers retry here.
            Log.info("Background upload deferred — another upload is active; rescheduled")
            reschedule()
            return .deferred
        }
        defer { EventUploadCoordinator.release() }

        // This BGTask can fire hours/days after the events were queued — prune past
        // the redelivery horizon BEFORE upload so a stale event isn't re-sent past the server dedup
        // window (double-count). The in-process EventQueue prunes too; the store method covers both.
        eventStore.pruneStale()
        let pendingCount = eventStore.pendingCount
        guard pendingCount > 0 else { return .nothingToUpload }

        // Send events in batches using the adaptive batch size, capped like the queue's.
        if let cap = BatchSizeCapGate.cap, cap <= 0 {
            // A cap of 0 (the queue's internal test seam) holds events on the device: nothing to send.
            return .nothingToUpload
        }
        let batchSize = Self.uploadBatchSize(adaptive: NetworkMonitor.shared.adaptiveBatchSize)
        guard batchSize > 0 else {
            // No network — reschedule
            reschedule()
            return .noNetwork
        }

        // Batch after batch — up to `maxBatchesPerRun` — until none is left, a batch fails or one is rejected:
        // Android `EventUploadWorker`, same rule (it sent up to 50 batches per run where this sent one, so a large
        // backlog took one scheduled run per 100 events here). Only each batch is read and decoded, never the whole
        // backlog.
        var sentAny = false
        for _ in 0..<Self.maxBatchesPerRun {
            let batch = eventStore.loadOldest(batchSize)
            guard !batch.isEmpty else { return sentAny ? .uploaded : .nothingToUpload }
            let payload: [String: Any] = ["batch": batch.compactMap { event -> [String: Any]? in
                guard let data = try? JSONEncoder().encode(event),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return dict
            }]

            guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return .failed }

            let success = await apiClient.sendEvents(bodyData)

            if success {
                let eventIds = Set(batch.map(\.event_id))
                eventStore.removeSent(eventIds: eventIds)
                EventUploadCoordinator.markResolved(eventIds)
                retryCount = 0
                sentAny = true
                Log.info("Background upload successful: \(batch.count) events")
                continue
            }
            if apiClient.lastEventUploadRejectedPermanently {
                // A permanent 4xx (400 malformed / 401 bad key) fails the same way every time. Kept, this batch —
                // always the oldest — was sent again by every later run and blocked every event behind it until
                // the 7-day horizon pruned it. Drop it and count the loss, exactly as the in-process queue does
                // (`EventQueue`'s permanent-failure branch): each normal event +1, a carried
                // `_sdk_events_dropped` meta its count. Android `EventUploadWorker`, same rule.
                var loss = 0
                for event in batch {
                    if event.event_name == "_sdk_events_dropped" {
                        loss += (event.properties?["count"]?.value as? Int) ?? 0
                    } else {
                        loss += 1
                    }
                }
                if loss > 0 { DroppedEventsCounter.increment(loss) }
                let eventIds = Set(batch.map(\.event_id))
                eventStore.removeSent(eventIds: eventIds)
                EventUploadCoordinator.markResolved(eventIds)
                retryCount = 0
                Log.error("Background upload rejected permanently — dropped a batch of \(batch.count) events (loss metric +\(loss))")
                // The run ends here. A 401 / 403 rejects every batch the same way: uploads pause — the in-process
                // queue's rule — until the next foreground or `AppDNA.flush()`, and no run is scheduled. Any other
                // rejection was about this batch: the next run sends the events behind it.
                if apiClient.lastEventUploadRejectionPausesUploads {
                    UploadPauseGate.pauseFromBackgroundUpload()
                    Log.error("Background upload: the API key was rejected — uploads paused until the next foreground / AppDNA.flush()")
                } else if eventStore.pendingCount > 0 {
                    reschedule()
                }
                return .droppedRejected
            }
            retryCount += 1
            if retryCount < maxRetries {
                reschedule()
            } else {
                retryCount = 0
                Log.warning("Background upload max retries reached")
            }
            return .failed
        }
        // More than one run's worth: the next run takes the rest.
        if eventStore.pendingCount > 0 { reschedule() }
        return .uploaded
    }

    /// Batches one background run uploads at most before it schedules another run for the rest (Android
    /// `EventUploadWorker.MAX_BATCHES_PER_RUN`).
    static let maxBatchesPerRun = 50
}
