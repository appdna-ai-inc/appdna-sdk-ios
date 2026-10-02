// EventStoreBacklogTests.swift
//
// A flush must cost what its batch costs, not what the backlog costs.
//
// Every flush used to decode the whole `pending_events.json` twice — `pruneStale` read every event to find
// the stale ones, `removeSent` read every event, filtered them and rewrote the file — and every store on one
// file shares one serial queue, so the next `configure()`'s load waited behind the previous queue's last
// flush: 15–30 s on a 10,000-event file. The store now keeps one in-memory index per file (built once per
// process from a light per-line decode), records removals as one appended line, and compacts only when it
// has something to reclaim.
//
// NEGATIVE CONTROL: the previous `EventStore` (decode-all `pruneStale` / read-filter-rewrite `removeSent`)
// fails `testAFlushDecodesOnlyItsBatchOnATenThousandEventBacklog` on both the decode count (two full decodes
// per cycle, 20,000+ lines per cycle) and the time bound, and `testASecondStoreOnTheFileReusesTheIndex` on
// the decode count.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class EventStoreBacklogTests: XCTestCase {

    private var files: [String] = []
    private var savedDropped = 0

    override func setUp() {
        super.setUp()
        savedDropped = DroppedEventsCounter.getAndReset()
    }

    override func tearDown() {
        for f in files { EventStore(fileName: f).clearAll() }
        files = []
        _ = DroppedEventsCounter.getAndReset()
        if savedDropped > 0 { DroppedEventsCounter.increment(savedDropped) }
        super.tearDown()
    }

    private func newFile(_ tag: String) -> String {
        let f = "backlog-\(tag)-\(UUID().uuidString).json"
        files.append(f)
        return f
    }

    private func fileURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ai.appdna.sdk", isDirectory: true).appendingPathComponent(name)
    }

    static func event(_ name: String, tsMs: Int64? = nil, properties: [String: Any]? = ["k": "v", "n": 1]) -> SDKEvent {
        let e = EventEnvelopeBuilder.build(
            event: name, properties: properties,
            identity: DeviceIdentity(anonId: "backlog-anon", userId: nil, traits: nil),
            sessionId: "backlog-session", analyticsConsent: true)
        guard let tsMs else { return e }
        return SDKEvent(schema_version: e.schema_version, event_id: e.event_id, event_name: e.event_name,
                        ts_ms: tsMs, user: e.user, device: e.device, context: e.context,
                        properties: e.properties, privacy: e.privacy)
    }

    static func backlog(_ n: Int) -> [SDKEvent] { (0..<n).map { event("backlog_\($0)") } }

    /// 10,000 queued events; 20 flush cycles of 50 (prune, take the oldest 50, remove them) — the background
    /// uploader's cycle, and the event queue's (prune + remove). Each cycle decodes its 50 lines and nothing
    /// else, and the 20 cycles take well under a second where the old store needed seconds per cycle.
    func testAFlushDecodesOnlyItsBatchOnATenThousandEventBacklog() {
        let store = EventStore(fileName: newFile("flush"))
        store.save(events: Self.backlog(10_000))
        XCTAssertEqual(store.pendingCount, 10_000)

        let decodedBefore = store.decodedLinesForTesting
        let buildsBefore = store.indexBuildsForTesting
        let start = Date()
        var sent = 0
        for _ in 0..<20 {
            store.pruneStale()
            let batch = store.loadOldest(50)
            XCTAssertEqual(batch.count, 50)
            store.removeSent(eventIds: Set(batch.map(\.event_id)))
            sent += batch.count
        }
        let elapsed = Date().timeIntervalSince(start)
        let decoded = store.decodedLinesForTesting - decodedBefore

        XCTAssertEqual(decoded, sent, "a flush decoded \(decoded - sent) lines beyond its batches — per-flush cost follows the backlog again")
        XCTAssertEqual(store.indexBuildsForTesting, buildsBefore, "the index was rebuilt during the flushes")
        XCTAssertEqual(store.pendingCount, 10_000 - sent)
        // Generous: measured in milliseconds on the simulator; the old store took seconds per cycle.
        XCTAssertLessThan(elapsed, 5, "20 flush cycles on a 10,000-event backlog took \(elapsed) s")
        print("[backlog] 20 flush cycles of 50 on 10,000 events: \(String(format: "%.3f", elapsed)) s, \(decoded) lines decoded")
    }

    /// `shutdown(); configure()` builds a new store on the same file: it uses the index the process already
    /// has instead of decoding the file again, and the event queue's load decodes only its window.
    func testASecondStoreOnTheFileReusesTheIndex() {
        let file = newFile("second")
        let first = EventStore(fileName: file)
        first.save(events: Self.backlog(10_000))
        _ = first.pendingCount
        let decodedBefore = first.decodedLinesForTesting
        let buildsBefore = first.indexBuildsForTesting

        let second = EventStore(fileName: file)
        XCTAssertEqual(second.pendingCount, 10_000)
        let window = second.loadNewest(EventQueue.maxInMemoryEvents)
        XCTAssertEqual(window.count, EventQueue.maxInMemoryEvents)
        XCTAssertEqual(window.last?.event_name, "backlog_9999", "the window is the newest events, oldest first")
        XCTAssertEqual(window.first?.event_name, "backlog_9000")
        XCTAssertEqual(second.indexBuildsForTesting, buildsBefore, "the second store re-read the file")
        XCTAssertEqual(second.decodedLinesForTesting - decodedBefore, EventQueue.maxInMemoryEvents)
    }

    /// The removals and prunes are on disk, not only in the index: a new process (the index dropped) sees
    /// exactly the events that are still pending, in order.
    func testRemovalsAndPrunesSurviveARestart() {
        let store = EventStore(fileName: newFile("restart"))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let stale = (0..<5).map { Self.event("stale_\($0)", tsMs: now - EventStore.redeliveryHorizonMs - 60_000) }
        let fresh = Self.backlog(300)
        store.save(events: stale + fresh)
        store.removeSent(eventIds: Set(fresh[0..<100].map(\.event_id)))
        store.removeSent(eventIds: Set(fresh[200..<210].map(\.event_id)))
        XCTAssertEqual(store.pruneStale(), 5)
        XCTAssertEqual(DroppedEventsCounter.peek(), 5, "a prune is counted")

        let expected = Array(fresh[100..<200]) + Array(fresh[210..<300])
        store.dropIndexForTesting()
        let reloaded = store.loadPending()
        XCTAssertEqual(reloaded.map(\.event_id), expected.map(\.event_id))
        XCTAssertEqual(store.pendingCount, expected.count)
        XCTAssertEqual(store.pruneStale(), 0, "pruned events came back")
    }

    /// A prune counts a stale `_sdk_events_dropped` meta's carried N, read from the index.
    func testAPruneCountsAStaleMetaEventsCarriedCount() {
        let store = EventStore(fileName: newFile("meta"))
        let old = Int64(Date().timeIntervalSince1970 * 1000) - EventStore.redeliveryHorizonMs - 60_000
        store.save(events: [Self.event("_sdk_events_dropped", tsMs: old, properties: ["count": 7]),
                            Self.event("x", tsMs: old), Self.event("y")])
        store.dropIndexForTesting()   // read the meta's count from the file, not from the save
        XCTAssertEqual(store.pruneStale(), 2)
        XCTAssertEqual(DroppedEventsCounter.peek(), 8)
        XCTAssertEqual(store.loadPending().map(\.event_name), ["y"])
    }

    /// Clock-jumped events (older than the implausible-age bound) are kept, as before.
    func testAClockJumpedEventIsNotPruned() {
        let store = EventStore(fileName: newFile("jump"))
        let ancient = Int64(Date().timeIntervalSince1970 * 1000) - EventStore.implausibleAgeMs - 86_400_000
        store.save(events: [Self.event("jumped", tsMs: ancient)])
        XCTAssertEqual(store.pruneStale(), 0)
        XCTAssertEqual(store.pendingCount, 1)
    }

    /// Dead bytes are reclaimed: draining a backlog batch by batch keeps the file within the live events plus
    /// the slack, and an emptied store leaves an empty file.
    func testDeadBytesAreReclaimed() {
        let store = EventStore(fileName: newFile("reclaim"))
        let events = Self.backlog(4_000)
        store.save(events: events)
        let full = store.diskSizeBytes
        var maxSeen = full
        for i in stride(from: 0, to: 4_000, by: 50) {
            store.removeSent(eventIds: Set(events[i..<(i + 50)].map(\.event_id)))
            maxSeen = max(maxSeen, store.diskSizeBytes)
        }
        XCTAssertLessThanOrEqual(maxSeen, full + EventStore.deadBytesSlack + 64 * 1024)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.diskSizeBytes, 0, "an empty store leaves an empty file")
    }

    /// The caps still hold: the count cap and the disk quota evict the oldest and count them.
    func testTheCountCapEvictsTheOldestAndCountsThem() {
        let store = EventStore(maxEvents: 100, compactionInterval: 1, fileName: newFile("cap"))
        let events = Self.backlog(150)
        store.save(events: events)
        XCTAssertEqual(store.loadPending().map(\.event_id), events.suffix(100).map(\.event_id))
        XCTAssertEqual(DroppedEventsCounter.peek(), 50)
    }

    /// Something else changed the file (a test deleted it; a crash between a write and the bookkeeping): the
    /// store re-reads it instead of answering from an index of a file that no longer exists.
    func testAFileChangedBehindTheStoresBackIsReRead() throws {
        let file = newFile("external")
        let store = EventStore(fileName: file)
        store.save(events: Self.backlog(50))
        XCTAssertEqual(store.pendingCount, 50)

        try FileManager.default.removeItem(at: fileURL(file))
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.loadPending().count, 0)

        let replaced = Self.backlog(3)
        let enc = JSONEncoder()
        var blob = Data()
        for e in replaced { blob.append(try enc.encode(e)); blob.append(0x0A) }
        try blob.write(to: fileURL(file))
        XCTAssertEqual(store.loadPending().map(\.event_id), replaced.map(\.event_id))
    }

    /// A crash mid-append leaves a partial last line. It is skipped, and the next append does not glue its
    /// event onto it.
    func testAPartialLastLineDoesNotSwallowTheNextEvent() throws {
        let file = newFile("partial")
        let first = Self.backlog(2)
        let enc = JSONEncoder()
        var blob = Data()
        for e in first { blob.append(try enc.encode(e)); blob.append(0x0A) }
        blob.append(Data(#"{"schema_version":1,"event_id":"cut-sh"#.utf8))
        try blob.write(to: fileURL(file))

        let store = EventStore(fileName: file)
        XCTAssertEqual(store.pendingCount, 2)
        let next = Self.event("after_crash")
        store.save(events: [next])
        store.dropIndexForTesting()
        XCTAssertEqual(store.loadPending().map(\.event_id), first.map(\.event_id) + [next.event_id])
    }

    /// A file an older SDK wrote as one JSON array is read once and rewritten as lines.
    func testALegacyJSONArrayFileIsMigrated() throws {
        let file = newFile("legacy")
        let events = Self.backlog(4)
        try JSONEncoder().encode(events).write(to: fileURL(file))
        let store = EventStore(fileName: file)
        XCTAssertEqual(store.loadPending().map(\.event_id), events.map(\.event_id))
        store.removeSent(eventIds: [events[0].event_id])
        store.dropIndexForTesting()
        XCTAssertEqual(store.loadPending().map(\.event_id), events.dropFirst().map(\.event_id))
    }

    /// `loadOldest` / `loadNewest` skip removed events wherever they are (the queue sends from the newest
    /// window, the background uploader from the oldest).
    func testOldestAndNewestSkipRemovedEvents() {
        let store = EventStore(fileName: newFile("window"))
        let events = Self.backlog(20)
        store.save(events: events)
        store.removeSent(eventIds: Set([0, 1, 18, 10].map { events[$0].event_id }))
        XCTAssertEqual(store.loadOldest(3).map(\.event_id), [2, 3, 4].map { events[$0].event_id })
        XCTAssertEqual(store.loadNewest(3).map(\.event_id), [16, 17, 19].map { events[$0].event_id })
        XCTAssertEqual(store.pendingCount, 16)
    }

    /// The event queue's load no longer runs inside `init` (= inside `configure()`): a queue built while the
    /// store's file queue is busy returns at once and still loads the persisted events before its first flush.
    func testAnEventQueueIsBuiltWithoutWaitingForTheStore() {
        let file = newFile("queue")
        let store = EventStore(fileName: file)
        store.save(events: Self.backlog(10))
        let fileQueue = EventStore.sharedQueue(for: fileURL(file))
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        fileQueue.async { held.signal(); release.wait() }     // the previous queue's flush, still running
        held.wait()
        // Ends the hold on its own after 3 s, so a queue that does wait (the negative control) fails, not hangs.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { release.signal() }

        let start = Date()
        let queue = EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                               eventStore: EventStore(fileName: file),
                               eventTracker: EventTracker(identityManager: IdentityManager(
                                   keychainStore: KeychainStore(service: "ai.appdna.sdk.test.backlog.\(UUID().uuidString)"))),
                               batchSize: 0, flushInterval: 3600)
        let built = Date().timeIntervalSince(start)
        release.signal()
        XCTAssertLessThan(built, 1, "EventQueue.init waited for the store's file queue (\(built) s)")
        XCTAssertEqual(queue.consecutiveFailuresForTesting, 0)   // drains the queue: the load ran
        withExtendedLifetime(queue) {}
    }
}
