// UploadPauseBackgroundTests.swift
//
// The event queue's failure pause holds for the OS background uploader. Backgrounding a paused queue used to
// schedule the BGProcessingTask anyway, and the task never looked at the pause, so it uploaded exactly what the
// pause stops. Now backgrounding schedules nothing while paused, and a run that starts while paused (the pause
// is persisted in `UploadPauseGate`, so a run in a fresh process sees it) uploads nothing; a foreground or
// `AppDNA.flush()` clears it. Android `EventShutdownHandoffTest`, same contract; fixture
// `resilience/flush_pause_gate` (`os_upload`).
//
// The pause here is set with the `pauseForTesting()` seam, which writes the gate itself — so this file does
// NOT prove that the production pause writes the gate. `UploadPauseGatePersistenceTests` does: it drives five
// real failed upload cycles.
//
// NEGATIVE CONTROLS (build Mac): without the pause check in `enterBackground` the schedule runs (round 30);
// without the `guard !paused` in `BackgroundUploader.runUpload` the paused background run sends its batch
// (round 31).
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class UploadPauseBackgroundTests: XCTestCase {

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    override func tearDown() {
        EventQueue.scheduleBackgroundUploadForTesting = nil
        UploadPauseGate.setForTesting(false)
        super.tearDown()
    }

    private func makeQueue(_ store: EventStore) -> EventQueue {
        let tracker = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.test.pausebg.\(UUID().uuidString)")))
        return EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                          eventStore: store, eventTracker: tracker, batchSize: 20, flushInterval: 3600)
    }

    private func waitBriefly(_ seconds: TimeInterval = 1, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testAPausedQueueSchedulesNoBackgroundUploadAndTheBackgroundRunMayNotUpload() {
        let store = EventStore(fileName: "pause-bg-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let scheduled = Counter()
        EventQueue.scheduleBackgroundUploadForTesting = { scheduled.bump() }
        let queue = makeQueue(store)
        XCTAssertTrue(BackgroundUploader.uploadAllowed, "a new queue starts unpaused")

        queue.pauseForTesting()
        XCTAssertFalse(BackgroundUploader.uploadAllowed, "a background run may upload while the queue is paused")
        queue.enterBackground(holdBackgroundTask: false)
        waitBriefly { scheduled.value > 0 }
        XCTAssertEqual(scheduled.value, 0, "backgrounding a paused queue scheduled the background upload")

        // A foreground (or `AppDNA.flush()`) clears the pause, and backgrounding schedules again.
        queue.flushClearingPause()
        waitBriefly { BackgroundUploader.uploadAllowed }
        XCTAssertTrue(BackgroundUploader.uploadAllowed, "the host's flush did not clear the persisted pause")
        queue.enterBackground(holdBackgroundTask: false)
        waitBriefly { scheduled.value > 0 }
        XCTAssertEqual(scheduled.value, 1)
    }

    /// The BGProcessingTask's body (`runUpload`) with the gate production hands it: paused, it sends nothing
    /// and reschedules nothing; not paused, it sends the batch.
    func testTheBackgroundRunHonoursTheGateItIsGiven() throws {
        let server = try XCTUnwrap(LoopbackHTTPServer { _ in .init(status: 200, headers: [:], body: "{}") },
                                   "could not open a local socket")
        defer {
            server.stop()
            APIBaseURL.infoPlistReaderForTesting = nil
            APIBaseURL.gateForTesting = nil
        }
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
        let store = EventStore(fileName: "pause-bg-run-\(UUID().uuidString).json")
        defer { store.clearAll() }
        store.save(events: [EventEnvelopeBuilder.build(
            event: "pause_bg_run", properties: nil,
            identity: DeviceIdentity(anonId: "pause-bg-anon", userId: nil, traits: nil),
            sessionId: "pause-bg-session", analyticsConsent: true)])
        let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
        let uploader = BackgroundUploader(apiClient: client, eventStore: store)
        let rescheduled = Counter()

        let paused = ResilienceFixtureTests.runBlocking {
            await uploader.runUpload(paused: true, reschedule: { rescheduled.bump() })
        }
        XCTAssertEqual(paused, .skippedPaused)
        XCTAssertEqual(paused?.taskSucceeded, true)
        XCTAssertTrue(server.requests.filter { $0.contains("/ingest/events") }.isEmpty, "a paused background run uploaded")
        XCTAssertEqual(rescheduled.value, 0, "a paused background run rescheduled itself")
        XCTAssertEqual(store.loadPending().count, 1)

        let unpaused = ResilienceFixtureTests.runBlocking {
            await uploader.runUpload(paused: false, reschedule: { rescheduled.bump() })
        }
        XCTAssertEqual(unpaused, .uploaded)
        XCTAssertEqual(server.requests.filter { $0.contains("/ingest/events") }.count, 1)
        XCTAssertEqual(store.loadPending().count, 0, "the accepted batch is still pending")
        withExtendedLifetime(client) {}
    }
}
