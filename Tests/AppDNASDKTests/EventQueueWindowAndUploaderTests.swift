// EventQueueWindowAndUploaderTests.swift
//
// Two upload paths that stopped short of the backlog:
//   - the in-process queue's window (the newest 1,000 events) was never reloaded once it drained, so the older
//     events of a larger backlog waited for the background uploader or the next launch;
//   - the background uploader ignored a permanent rejection: the batch — always the oldest — stayed on disk and
//     was sent again by every later run, blocking every event behind it until the 7-day horizon pruned it.
// And the per-request rejection flag both owners now read: a transient failure after a 401 (the latch stays
// set) no longer drops the batch the server never judged.
// Android `EventWindowAndWorkerTest`, same rules.
//
// NEGATIVE CONTROLS (build Mac, patched sources — status file round 34): without the reload, 200 of the 1,200
// events are never sent by the queue; without the uploader's rejection branch, the run answers `.failed` and the
// 100 rejected events are still pending; with the queue reading the latch, the 503 after a 401 drops its batch.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class EventQueueWindowAndUploaderTests: XCTestCase {

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
    }

    private var savedDropped = 0

    override func setUp() {
        super.setUp()
        savedDropped = DroppedEventsCounter.getAndReset()
        EventUploadCoordinator.clearResolvedForTesting()
        NetworkMonitor.adaptiveBatchSizeOverrideForTesting = 100
        BatchSizeCapGate.set(nil)
        UploadPauseGate.setForTesting(false)
    }

    override func tearDown() {
        NetworkMonitor.adaptiveBatchSizeOverrideForTesting = nil
        EventUploadCoordinator.clearResolvedForTesting()
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        _ = DroppedEventsCounter.getAndReset()
        if savedDropped > 0 { DroppedEventsCounter.increment(savedDropped) }
        super.tearDown()
    }

    private func serve(_ respond: @escaping @Sendable (String) -> LoopbackHTTPServer.Answer) throws -> LoopbackHTTPServer {
        let server = try XCTUnwrap(LoopbackHTTPServer(respond: respond), "could not open a local socket")
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
        return server
    }

    private func sentIds(_ server: LoopbackHTTPServer) throws -> [String] {
        var sent: [String] = []
        for (label, body) in server.bodies where label.contains("/ingest/events") {
            let raw = (try? (body as NSData).decompressed(using: .zlib) as Data) ?? body
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            for e in (json["batch"] as? [[String: Any]]) ?? [] { if let i = e["event_id"] as? String { sent.append(i) } }
        }
        return sent
    }

    private func makeQueue(_ store: EventStore) -> EventQueue {
        EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                   eventStore: store,
                   eventTracker: EventTracker(identityManager: IdentityManager(
                       keychainStore: KeychainStore(service: "ai.appdna.sdk.test.window.\(UUID().uuidString)"))),
                   batchSizeCap: nil, flushInterval: 3600)
    }

    private func waitUntil(_ seconds: TimeInterval = 30, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !cond() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// A 1,200-event backlog: the queue loads its newest 1,000 and keeps sending until every event is sent.
    func testTheQueueReloadsItsDrainedWindowAndSendsTheWholeBacklog() throws {
        let server = try serve { _ in .init(status: 200, headers: [:], body: "{}") }
        defer { server.stop() }
        let store = EventStore(fileName: "window-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let events = EventStoreBacklogTests.backlog(1_200)
        store.save(events: events)
        let queue = makeQueue(store)
        XCTAssertEqual(queue.inMemoryCountForTesting, EventQueue.maxInMemoryEvents)
        for _ in 0..<20 where store.pendingCount > 0 {
            let before = store.pendingCount
            queue.flushClearingPause()
            waitUntil(10) { store.pendingCount < before }
        }
        XCTAssertEqual(store.pendingCount, 0, "events of the backlog were never sent by the in-process queue")
        let sent = try sentIds(server)
        XCTAssertEqual(sent.count, 1_200)
        XCTAssertEqual(Set(sent), Set(events.map(\.event_id)), "an event was missed or sent twice")
        withExtendedLifetime(queue) {}
    }

    /// The persisted events are in the window before the queue's first flush (the load `init` queues).
    func testThePersistedEventsAreLoadedBeforeTheFirstFlush() {
        let store = EventStore(fileName: "window-load-\(UUID().uuidString).json")
        defer { store.clearAll() }
        store.save(events: EventStoreBacklogTests.backlog(10))
        let queue = makeQueue(store)
        XCTAssertEqual(queue.inMemoryCountForTesting, 10)
        withExtendedLifetime(queue) {}
    }

    /// Minor 5. A permanently rejected background batch is dropped and counted (as the in-process queue does),
    /// and the next run sends the events behind it.
    func testTheBackgroundUploaderDropsAPermanentlyRejectedBatch() throws {
        let ingests = Box()
        let server = try serve { label in
            if label.contains("/ingest/events") && ingests.next() == 0 { return .init(status: 400, headers: [:], body: "{}") }
            return .init(status: 200, headers: [:], body: "{}")
        }
        defer { server.stop() }
        let store = EventStore(fileName: "bg-reject-\(UUID().uuidString).json")
        defer { store.clearAll() }
        store.save(events: EventStoreBacklogTests.backlog(150))
        let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
        let uploader = BackgroundUploader(apiClient: client, eventStore: store)
        let first = ResilienceFixtureTests.runBlocking { await uploader.runUpload(paused: false, reschedule: {}) }
        XCTAssertEqual(first, .droppedRejected)
        XCTAssertEqual(first?.taskSucceeded, true)
        XCTAssertEqual(store.pendingCount, 50, "the rejected batch is still pending (it blocks every later run)")
        XCTAssertEqual(DroppedEventsCounter.peek(), 100, "the rejected batch is a counted loss")
        let second = ResilienceFixtureTests.runBlocking { await uploader.runUpload(paused: false, reschedule: {}) }
        XCTAssertEqual(second, .uploaded)
        XCTAssertEqual(store.pendingCount, 0)
        withExtendedLifetime(client) {}
    }

    /// A transient failure (no answer, a 503) after a 401 drops nothing: the latch stays set, but the batch the
    /// server never judged is kept (`lastEventUploadRejectedPermanently` is per request).
    func testATransientFailureAfterARejectionDropsNothing() throws {
        let ingests = Box()
        let server = try serve { label in
            guard label.contains("/ingest/events") else { return .init(status: 200, headers: [:], body: "{}") }
            return ingests.next() == 0 ? .init(status: 401, headers: [:], body: "{}") : .init(status: 503, headers: [:], body: "{}")
        }
        defer { server.stop() }
        let store = EventStore(fileName: "bg-transient-\(UUID().uuidString).json")
        defer { store.clearAll() }
        store.save(events: EventStoreBacklogTests.backlog(150))
        let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
        let uploader = BackgroundUploader(apiClient: client, eventStore: store)
        XCTAssertEqual(ResilienceFixtureTests.runBlocking { await uploader.runUpload(paused: false, reschedule: {}) }, .droppedRejected)
        XCTAssertTrue(client.eventUploadPermanentlyFailed)
        let second = ResilienceFixtureTests.runBlocking { await uploader.runUpload(paused: false, reschedule: {}) }
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(store.pendingCount, 50, "a 503 after a 401 dropped a batch")
        XCTAssertEqual(DroppedEventsCounter.peek(), 100)
        withExtendedLifetime(client) {}
    }
}
