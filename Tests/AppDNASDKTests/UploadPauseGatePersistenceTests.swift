// UploadPauseGatePersistenceTests.swift
//
// The persisted upload pause, written by the production path — not by a test seam. Five real failed upload
// cycles against a failing local server pause the queue, and the pause reaches `UploadPauseGate` (which the
// background uploader reads): both writes, the transient path (429 retried until the cycle gives up) and the
// permanent-4xx path. And a queue that `shutdown()` ended cannot set the gate after the next `configure()`'s
// queue cleared it: the gate belongs to the newest queue. Android `UploadPauseGatePersistenceTest`, same contract.
//
// NEGATIVE CONTROLS (build Mac, patched sources — status file round 31):
//   - the `UploadPauseGate.set(true, …)` after the retries are exhausted removed → the transient test fails;
//   - the one after the permanent-4xx drop removed → the permanent test fails;
//   - the owner check in `UploadPauseGate.set` removed → the replaced-queue test fails (the ended queue's
//     fifth failure sets the new session's gate).
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class UploadPauseGatePersistenceTests: XCTestCase {

    private var server: LoopbackHTTPServer?
    private var savedDropped = 0
    private var stores: [EventStore] = []

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
        UploadPauseGate.setForTesting(false)
        EventUploadCoordinator.clearResolvedForTesting()
    }

    override func tearDown() {
        ShutdownUploadIsolation.restore(savedDropped)
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        for s in stores { s.clearAll() }
        stores = []
        UploadPauseGate.setForTesting(false)
        super.tearDown()
    }

    private func serve(status: Int, headers: [String: String]) throws -> LoopbackHTTPServer {
        let srv = try XCTUnwrap(LoopbackHTTPServer { _ in .init(status: status, headers: headers, body: "{}") },
                                "could not open a local socket")
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? srv.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
        server = srv
        return srv
    }

    private func makeQueue() -> EventQueue {
        let store = EventStore(fileName: "pause-persist-\(UUID().uuidString).json")
        stores.append(store)
        let tracker = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.test.pausepersist.\(UUID().uuidString)")))
        return EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                          eventStore: store, eventTracker: tracker, batchSizeCap: nil, flushInterval: 3600)
    }

    private func event() -> SDKEvent {
        EventEnvelopeBuilder.build(event: "pause_persist", properties: nil,
                                   identity: DeviceIdentity(anonId: "pause-anon", userId: nil, traits: nil),
                                   sessionId: "pause-session", analyticsConsent: true)
    }

    /// One failed upload cycle, driven by a scheduled flush (which keeps the pause, as the timer does).
    private func failOneCycle(_ queue: EventQueue, enqueue: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let before = queue.consecutiveFailuresForTesting
        if enqueue { queue.enqueue(event()) }
        queue.flush(.scheduled)
        let deadline = Date().addingTimeInterval(20)
        while queue.consecutiveFailuresForTesting == before && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(queue.consecutiveFailuresForTesting, before + 1, "the upload cycle did not fail", file: file, line: line)
    }

    func testFiveFailedTransientCyclesPersistThePause() throws {
        // 429 with a short Retry-After: retried (3 retries) until the cycle gives up — quickly.
        _ = try serve(status: 429, headers: ["Retry-After": "0.02"])
        let queue = makeQueue()
        queue.enqueue(event())
        for i in 1...4 {
            failOneCycle(queue, enqueue: false)
            XCTAssertFalse(UploadPauseGate.isPaused, "paused after \(i) failed cycle(s)")
        }
        failOneCycle(queue, enqueue: false)
        XCTAssertTrue(UploadPauseGate.isPaused, "five failed cycles did not persist the pause")
        XCTAssertFalse(BackgroundUploader.uploadAllowed)
    }

    func testFiveFailedPermanentCyclesPersistThePause() throws {
        // A permanent 4xx drops its batch and counts toward the pause: each cycle needs a new event.
        _ = try serve(status: 400, headers: [:])
        let queue = makeQueue()
        for _ in 1...4 { failOneCycle(queue, enqueue: true) }
        XCTAssertFalse(UploadPauseGate.isPaused)
        failOneCycle(queue, enqueue: true)
        XCTAssertTrue(UploadPauseGate.isPaused, "five permanent-4xx cycles did not persist the pause")
    }

    func testAQueueThatWasReplacedCannotSetTheNewSessionsPause() throws {
        _ = try serve(status: 429, headers: ["Retry-After": "0.02"])
        let ended = makeQueue()
        ended.enqueue(event())
        for _ in 1...4 { failOneCycle(ended, enqueue: false) }

        // The next configure()'s queue: it clears the gate and owns it.
        let current = makeQueue()
        XCTAssertFalse(UploadPauseGate.isPaused)

        // The ended queue's last upload fails a fifth time: its own pause, not the new session's.
        failOneCycle(ended, enqueue: false)
        XCTAssertFalse(UploadPauseGate.isPaused, "a replaced queue set the new session's upload pause")

        // The current queue still can.
        current.pauseForTesting()
        XCTAssertTrue(UploadPauseGate.isPaused)
        withExtendedLifetime(ended) {}
    }
}
