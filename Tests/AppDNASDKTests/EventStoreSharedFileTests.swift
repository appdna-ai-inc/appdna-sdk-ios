// EventStoreSharedFileTests.swift
//
// `shutdown(); configure()` builds a new `EventQueue` and `EventStore` on the same file while the old
// queue's last upload is still in flight (`flushForShutdown`). Two defects:
//
//   Lost event    each `EventStore` had its own serial queue. The old store's `removeSent` reads the
//                 file, filters it and rewrites it; the new store's `save` appended in between, and the
//                 rewrite dropped that event from disk. NEGATIVE CONTROL: with a per-instance queue
//                 (`DispatchQueue(label:)` in `init` instead of `sharedQueue(for:)`) the first test loses
//                 appended events.
//   Re-sent batch the new queue loaded the old queue's in-flight batch from disk and sent it again once the
//                 old upload had removed it. NEGATIVE CONTROL: without the `wasResolved` filter in
//                 `performFlush` the second test sees every event id twice.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class EventStoreSharedFileTests: XCTestCase {

    private var server: LoopbackHTTPServer?

    override func setUp() {
        super.setUp()
        EventUploadCoordinator.clearResolvedForTesting()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        EventUploadCoordinator.clearResolvedForTesting()
        super.tearDown()
    }

    private func event(_ name: String) -> SDKEvent {
        let tracker = Self.tracker
        var captured: SDKEvent?
        tracker.eventSink = { captured = $0 }
        tracker.track(event: name, properties: nil)
        return captured!
    }

    private static let tracker: EventTracker = {
        let t = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.test.sharedfile.\(UUID().uuidString)")))
        return t
    }()

    private func poll(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Two stores on one file: one keeps removing sent events (read, filter, rewrite) while the other
    /// appends. Every appended event must still be on disk.
    func testTwoStoresOnOneFileNeverDropAnAppendedEvent() {
        let file = "shared-file-\(UUID().uuidString).json"
        let old = EventStore(fileName: file)
        let new = EventStore(fileName: file)
        defer { old.clearAll() }
        // A large file makes each rewrite slow, so the appends land inside it.
        let seeded = (0..<600).map { event("seed_\($0)") }
        old.save(events: seeded)

        let appended = (0..<200).map { event("new_\($0)") }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for i in stride(from: 0, to: 400, by: 2) {
                old.removeSent(eventIds: [seeded[i].event_id, seeded[i + 1].event_id])
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for e in appended { new.save(events: [e]) }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)

        let onDisk = Set(new.loadPending().map(\.event_id))
        let lost = appended.filter { !onDisk.contains($0.event_id) }
        XCTAssertEqual(lost.count, 0, "\(lost.count) appended events were dropped by the other store's rewrite")
        XCTAssertEqual(onDisk.count, 200 + 200, "seeded 600, removed 400, appended 200")
    }

    /// The old queue's last upload is held at the server; the next configure's queue loads the same events;
    /// the old upload finishes. The new queue must not send them again.
    func testANewQueueDoesNotResendTheBatchTheEndedQueueDelivered() async throws {
        let release = DispatchSemaphore(value: 0)
        final class Once: @unchecked Sendable { let lock = NSLock(); var held = false }
        let once = Once()
        let server = try XCTUnwrap(LoopbackHTTPServer { label in
            if label.hasPrefix("POST /api/v1/ingest/events") {
                once.lock.lock(); let first = !once.held; once.held = true; once.lock.unlock()
                if first { _ = release.wait(timeout: .now() + 30) }   // the old queue's last upload
            }
            return .init(status: 200, headers: [:], body: "{}")
        }, "could not open a local socket")
        self.server = server
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? server.baseURL : nil }
        APIBaseURL.gateForTesting = { true }
        let networkUp = await poll { NetworkMonitor.shared.adaptiveBatchSize > 0 }
        XCTAssertTrue(networkUp, "the simulator reports no network")

        let file = "resend-\(UUID().uuidString).json"
        let queued = (0..<12).map { event("queued_\($0)") }
        let seedStore = EventStore(fileName: file)
        seedStore.save(events: queued)
        defer { seedStore.clearAll() }

        func makeQueue() -> EventQueue {
            EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                       eventStore: EventStore(fileName: file), eventTracker: Self.tracker,
                       batchSize: 50, flushInterval: 3600)
        }
        var oldQueue: EventQueue? = makeQueue()
        oldQueue?.flushForShutdown()          // `AppDNA.shutdown()`
        oldQueue = nil
        let held = await poll { server.count("POST /api/v1/ingest/events") == 1 }
        XCTAssertTrue(held, "the old queue's last upload never reached the server")

        let newQueue = makeQueue()            // the next `configure()`: loads the in-flight events
        release.signal()
        let resolved = await poll { EventQueue.uploadsInFlightForTesting == 0 && seedStore.loadPending().isEmpty }
        XCTAssertTrue(resolved, "the old upload did not finish")

        newQueue.flushClearingPause()         // the next flush of the new session
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await poll { EventQueue.uploadsInFlightForTesting == 0 }

        var sent: [String] = []
        for (label, body) in server.bodies where label.hasPrefix("POST /api/v1/ingest/events") {
            let json = (try? (body as NSData).decompressed(using: .zlib) as Data) ?? body
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            sent += (obj["batch"] as? [[String: Any]] ?? []).compactMap { $0["event_id"] as? String }
        }
        let ids = Set(queued.map(\.event_id))
        let ours = sent.filter { ids.contains($0) }
        XCTAssertEqual(Set(ours), ids, "not every queued event was sent")
        XCTAssertEqual(ours.count, ids.count, "the new queue re-sent the batch the ended queue delivered (\(ours.count) sends of \(ids.count) events)")
        withExtendedLifetime(newQueue) {}
    }
}
