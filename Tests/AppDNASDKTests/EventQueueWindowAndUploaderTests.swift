// EventQueueWindowAndUploaderTests.swift
//
// Two upload paths that stopped short of the backlog:
//   - the in-process queue's window (the newest 1,000 events) was never reloaded once it drained, so the older
//     events of a larger backlog waited for the background uploader or the next launch — and a reload that found
//     only events another owner had already resolved (but that were still stored) stopped there for good;
//   - the background uploader ignored a permanent rejection: the batch — always the oldest — stayed on disk and
//     was sent again by every later run, blocking every event behind it until the 7-day horizon pruned it.
// And the per-request rejection flag both owners read (`APIClient.lastEventUploadRejectedPermanently`): a transient
// failure after a refusal (the latch stays set) drops nothing — in the background uploader and in the in-process queue.
// And a 401 from a tunnel in front of the API (an HTML page) keeps every event on both paths, counts nothing, and the
// events are all sent once the server is back.
// Android `EventWindowAndWorkerTest`, same rules.
//
// NEGATIVE CONTROLS (build Mac, patched sources): without the reload, 200 of the 1,200 events are never sent by the
// queue; without removing the resolved events it skips, the 1,000 resolved events stay stored and the 200 behind
// them are never sent; without the uploader's rejection branch, the run answers `.failed` and the 100 rejected events
// are still pending; with either owner reading the latch instead of the per-request flag, the 503 after a 401 drops
// its batch.
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

    /// The ingest route's refusal of a batch's content (a 400 schema error). An upload is dropped only on 400 / 413 /
    /// 422 with this shape; a bare `{}` is kept and retried.
    static let refusal = #"{"error":{"code":"VALIDATION_ERROR","message":"Invalid request body","errors":{"batch.0.event_id":["Required"]}}}"#

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

    /// A permanently rejected background batch is dropped and counted (as the in-process queue does),
    /// and the next run sends the events behind it.
    func testTheBackgroundUploaderDropsAPermanentlyRejectedBatch() throws {
        let ingests = Box()
        let server = try serve { label in
            if label.contains("/ingest/events") && ingests.next() == 0 { return .init(status: 400, headers: [:], body: Self.refusal) }
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

    /// The background uploader: a 503 after a refusal drops nothing. The client's latch stays set after the refusal, but
    /// the background run reads the per-request flag (`lastEventUploadRejectedPermanently`), so the batch the server
    /// never judged is kept. (The in-process queue: `testTheQueueDropsNothingOnATransientFailureAfterARejection`.)
    func testATransientFailureAfterARejectionDropsNothing() throws {
        let ingests = Box()
        let server = try serve { label in
            guard label.contains("/ingest/events") else { return .init(status: 200, headers: [:], body: "{}") }
            return ingests.next() == 0 ? .init(status: 400, headers: [:], body: Self.refusal) : .init(status: 503, headers: [:], body: "{}")
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
        XCTAssertEqual(store.pendingCount, 50, "a 503 after a refusal dropped a batch")
        XCTAssertEqual(DroppedEventsCounter.peek(), 100)
        withExtendedLifetime(client) {}
    }

    /// The in-process queue, on one client: a refused batch is dropped; on the next flush a 503 drops nothing — the
    /// queue reads the per-request flag, not the client's latch, which the refusal left set.
    func testTheQueueDropsNothingOnATransientFailureAfterARejection() throws {
        let ingests = Box()
        let server = try serve { label in
            guard label.contains("/ingest/events") else { return .init(status: 200, headers: [:], body: "{}") }
            return ingests.next() == 0 ? .init(status: 400, headers: [:], body: Self.refusal) : .init(status: 503, headers: ["Retry-After": "60"], body: "{}")
        }
        defer { server.stop() }
        let store = EventStore(fileName: "queue-transient-\(UUID().uuidString).json")
        defer { store.clearAll() }
        store.save(events: EventStoreBacklogTests.backlog(150))
        let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
        let queue = EventQueue(apiClient: client, eventStore: store,
                               eventTracker: EventTracker(identityManager: IdentityManager(
                                   keychainStore: KeychainStore(service: "ai.appdna.sdk.test.qtransient.\(UUID().uuidString)"))),
                               batchSizeCap: nil, flushInterval: 3600)
        func ingestCount() -> Int { server.requests.filter { $0.contains("/ingest/events") }.count }

        queue.flushClearingPause()
        waitUntil(10) { queue.consecutiveFailuresForTesting > 0 }
        XCTAssertEqual(store.pendingCount, 50, "the refused batch is dropped")
        XCTAssertEqual(DroppedEventsCounter.peek(), 100)
        XCTAssertTrue(client.eventUploadPermanentlyFailed, "the refusal set the client's latch")
        XCTAssertFalse(UploadPauseGate.isPaused, "one refused batch does not pause uploads")

        queue.flushClearingPause()   // AppDNA.flush()
        waitUntil(10) { ingestCount() >= 2 }
        waitUntil(2) { false }        // let the queue apply the 503
        XCTAssertEqual(ingestCount(), 2)
        XCTAssertTrue(client.eventUploadPermanentlyFailed, "a transient failure leaves the latch set")
        XCTAssertEqual(store.pendingCount, 50, "a 503 after a refusal dropped a batch")
        XCTAssertEqual(queue.inMemoryCountForTesting, 50)
        XCTAssertEqual(DroppedEventsCounter.peek(), 100, "a 503 after a refusal counted a loss")
        withExtendedLifetime((queue, client)) {}
    }

    /// 1,000 events another owner already resolved — but that are still stored (its removal did not reach the disk) —
    /// at the front of the store, 1,200 unresolved events behind them. The window reload removes the resolved ones
    /// from the store and goes on to the rest: every unresolved event is sent once, no resolved one is sent, the store
    /// ends empty. Before, the reload skipped them and left them stored, so it found nothing to load every time and
    /// the 200 oldest unresolved events were never sent by the queue.
    func testTheWindowReloadRemovesResolvedEventsItSkipsAndReachesTheRest() throws {
        let server = try serve { _ in .init(status: 200, headers: [:], body: "{}") }
        defer { server.stop() }
        let store = EventStore(fileName: "window-resolved-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let resolved = EventStoreBacklogTests.backlog(1_000)
        let unresolved = EventStoreBacklogTests.backlog(1_200)
        store.save(events: resolved + unresolved)
        EventUploadCoordinator.markResolved(Set(resolved.map(\.event_id)))
        let queue = makeQueue(store)
        for _ in 0..<40 where store.pendingCount > 0 {
            let before = store.pendingCount
            queue.flushClearingPause()
            waitUntil(10) { store.pendingCount < before }
        }
        XCTAssertEqual(store.pendingCount, 0, "resolved events stayed stored, or the events behind them were never sent")
        let sent = try sentIds(server)
        XCTAssertEqual(sent.count, 1_200, "an event was missed or sent twice")
        XCTAssertEqual(Set(sent), Set(unresolved.map(\.event_id)))
        withExtendedLifetime(queue) {}
    }

    /// The outage the SDK used to lose events in: a tunnel in front of the API answers 401 with its own HTML page
    /// while the server is down. Both paths keep every event and count nothing; once the server is back, the host's
    /// `AppDNA.flush()` (it clears the pause) sends all of them, each once. Android
    /// `aTunnel401KeepsEveryEventAndTheyAreSentWhenTheServerIsBack`, same scenario.
    func testATunnel401KeepsEveryEventAndTheyAreSentWhenTheServerIsBack() throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock(); private var v = false
            var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
        }
        let serverUp = Flag()
        let tunnelPage = "<!DOCTYPE html><html><head><title>401 Unauthorized</title></head><body><h1>Unauthorized</h1></body></html>"
        let server = try serve { label in
            guard label.contains("/ingest/events") else { return .init(status: 200, headers: [:], body: "{}") }
            return serverUp.value ? .init(status: 202, headers: [:], body: #"{"accepted":1,"rejected":0}"#)
                                  : .init(status: 401, headers: ["Content-Type": "text/html"], body: tunnelPage)
        }
        defer { server.stop() }
        let store = EventStore(fileName: "tunnel-401-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let events = EventStoreBacklogTests.backlog(150)
        store.save(events: events)
        let client = APIClient(apiKey: "adn_test_placeholder", environment: .sandbox)
        let queue = EventQueue(apiClient: client, eventStore: store,
                               eventTracker: EventTracker(identityManager: IdentityManager(
                                   keychainStore: KeychainStore(service: "ai.appdna.sdk.test.tunnel.\(UUID().uuidString)"))),
                               batchSizeCap: nil, flushInterval: 3600)
        func ingestCount() -> Int { server.requests.filter { $0.contains("/ingest/events") }.count }

        // The outage: the queue's flush, then a background run, both answered by the tunnel.
        queue.flushClearingPause()
        waitUntil(10) { queue.consecutiveFailuresForTesting > 0 }
        XCTAssertEqual(store.pendingCount, 150, "the in-process queue deleted events on a tunnel 401")
        XCTAssertTrue(UploadPauseGate.isPaused, "a 401 pauses uploads")
        XCTAssertFalse(client.eventUploadPermanentlyFailed, "a tunnel 401 latched the client")
        UploadPauseGate.setForTesting(false)
        let uploader = BackgroundUploader(apiClient: client, eventStore: store)
        XCTAssertEqual(ResilienceFixtureTests.runBlocking { await uploader.runUpload(paused: false, reschedule: {}) }, .failed)
        XCTAssertEqual(store.pendingCount, 150, "the background run deleted events on a tunnel 401")
        XCTAssertEqual(DroppedEventsCounter.peek(), 0, "a tunnel 401 was counted as a loss")
        let outageUploads = ingestCount()
        XCTAssertEqual(outageUploads, 2)

        // The server is back: the host's flush clears the pause and sends everything.
        serverUp.value = true
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && store.pendingCount > 0 {
            queue.flushClearingPause()
            waitUntil(0.3) { false }
        }
        XCTAssertEqual(store.pendingCount, 0, "events left after the server came back")
        let delivered = try sentIds(server).dropFirst(outageUploads * 100)
        XCTAssertEqual(delivered.sorted(), events.map(\.event_id).sorted(), "an event was missed or sent twice")
        XCTAssertEqual(DroppedEventsCounter.peek(), 0)
        withExtendedLifetime((queue, client)) {}
    }
}
