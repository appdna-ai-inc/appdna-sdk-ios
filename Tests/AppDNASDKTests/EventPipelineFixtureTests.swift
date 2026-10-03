import XCTest
@testable import AppDNASDK

/// SPEC-428 — event-pipeline behavioral fixtures (`packages/sdk-shared-fixtures/events/*.fixture.json`).
///
/// The event pipeline (EventStore eviction, ClientSeqCounter monotonicity, DroppedEventsCounter,
/// event_id-stable redelivery) is NATIVE-owned per ADR-001, so iOS + Android assert these fixtures in
/// full; the Flutter/RN thin wrappers forward `track()` to native and defer these guarantees to the
/// native runners.
///
/// The driver replays each fixture's `pipeline.steps` against the REAL `EventStore` +
/// `EventEnvelopeBuilder` (assigns `client_seq`) + `DroppedEventsCounter`, with a mock server "sink"
/// that dedups by `event_id` (modelling the server dedup window), then asserts the observable output.
final class EventPipelineFixtureTests: XCTestCase {

    // MARK: - Fixture decoding

    struct Fixture: Decodable {
        let id: String
        let category: String
        let platforms: [String]
        let pipeline: Pipeline
    }
    struct Pipeline: Decodable {
        let config: Config?
        let steps: [Step]
        let expect: Expect
    }
    struct Config: Decodable {
        let max_events: Int?
        let max_bytes: Int?
        let redelivery_horizon_ms: Int?
    }
    struct Step: Decodable {
        let op: String
        let name: String?
        let count: Int?
        let ms: Int?
    }
    struct Expect: Decodable {
        let ingested_count: Int?
        let dropped_events_min: Int?
        let no_duplicate_event_id: Bool?
        let monotonic_client_seq: Bool?
        let ingested_order_key: String?
        let live_bytes_within_quota: Bool?
        let min_live_bytes_fraction: Double?
        let survivors_are_newest: Bool?
        let dropped_exact: Bool?
    }

    private static let seqKey = "ai.appdna.sdk.client_seq"
    private static let dropKey = "ai.appdna.sdk.dropped_events"

    // MARK: - Umbrella test

    func testEventPipelineFixtures() throws {
        let fixtures = try loadEventFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No iOS event-pipeline fixtures found (packages/sdk-shared-fixtures/events)")
        for f in fixtures { runPipeline(f) }
        print("[EventPipeline] asserted \(fixtures.count) fixtures")
    }

    // MARK: - Driver

    private func resetCounters() {
        ClientSeqCounter.resetForTesting() // reset the reserve-block in-memory state + persisted ceiling
        UserDefaults.standard.removeObject(forKey: Self.dropKey)
    }

    private func makeEvent(_ name: String) -> SDKEvent {
        // Faithful path: the SAME builder production uses — assigns event_id (UUID) + client_seq (next()).
        EventEnvelopeBuilder.build(
            event: name,
            properties: nil,
            identity: DeviceIdentity(anonId: "spec428-anon", userId: nil, traits: nil),
            sessionId: "spec428-session",
            analyticsConsent: true
        )
    }

    private func runPipeline(_ f: Fixture) {
        resetCounters()
        let cfg = f.pipeline.config
        let cap = cfg?.max_events ?? 10_000
        let maxBytes = cfg?.max_bytes ?? EventStore.maxDiskBytes
        let fileName = "spec428_\(f.id).json"
        // compactionInterval:1 → caps enforced on every save (so a small cap evicts deterministically).
        var store = EventStore(maxEvents: cap, compactionInterval: 1, fileName: fileName, maxDiskBytes: maxBytes)
        store.clearAll()
        resetCounters() // clearAll may have run compaction paths; start from a clean ledger

        var online = true
        var ingestedIds = Set<String>()
        var ingested: [SDKEvent] = []
        var rawSent = 0
        var hadRedeliver = false
        var tracked: [String] = []

        func flush() {
            guard online else { return }
            let pending = store.loadPending()
            rawSent += pending.count // EVERY send, including redeliveries of still-unacked events
            for e in pending where !ingestedIds.contains(e.event_id) {
                ingestedIds.insert(e.event_id) // server dedups by STABLE event_id → each ingested once
                ingested.append(e)
            }
            // Deliberately do NOT removeSent — the queue stays "unacked" so a `redeliver` step re-sends
            // the SAME stored events (same event_id). If event_id were regenerated on resend, the sink
            // would fail to dedup → ingested_count would exceed the expected → the test fails. That is
            // what makes offline_redelivery_idempotent a real test of CL-2 event_id stability.
        }

        for step in f.pipeline.steps {
            switch step.op {
            case "track", "track_before_configure":
                let n = step.count ?? 1
                let base = step.name ?? "evt"
                for i in 0..<n {
                    let name = n > 1 ? "\(base)_\(i)" : base
                    let event = makeEvent(name)
                    tracked.append(event.event_id)
                    store.save(events: [event])
                }
            case "flush":
                flush()
            case "go_offline":
                online = false
            case "go_online":
                online = true
            case "restart":
                // persistence survives: same on-disk file + UserDefaults-backed ClientSeqCounter.
                store = EventStore(maxEvents: cap, compactionInterval: 1, fileName: fileName, maxDiskBytes: maxBytes)
            case "redeliver":
                hadRedeliver = true
                flush() // re-sends the still-unacked events (same event_id) → sink must dedup them
            case "advance_time_ms":
                break
            default:
                XCTFail("[\(f.id)] unknown pipeline op: \(step.op)")
            }
        }

        let e = f.pipeline.expect
        // The disk quota: what is left, and what it cost (read before `dropped_events_min` resets the counter).
        let left = store.loadPending().map(\.event_id)
        if e.live_bytes_within_quota == true {
            XCTAssertLessThanOrEqual(store.liveBytesForTesting, maxBytes, "[\(f.id)] live bytes within the quota")
        }
        if let fraction = e.min_live_bytes_fraction {
            XCTAssertGreaterThan(Double(store.liveBytesForTesting), fraction * Double(maxBytes),
                                 "[\(f.id)] the quota is spent on events (live \(store.liveBytesForTesting) of \(maxBytes))")
        }
        if e.survivors_are_newest == true {
            XCTAssertFalse(left.isEmpty, "[\(f.id)] nothing survived")
            XCTAssertEqual(left, Array(tracked.suffix(left.count)), "[\(f.id)] the survivors are the newest, in order")
        }
        if e.dropped_exact == true {
            XCTAssertEqual(DroppedEventsCounter.peek(), tracked.count - left.count, "[\(f.id)] each evicted event counted once")
        }
        if let want = e.ingested_count {
            XCTAssertEqual(ingested.count, want, "[\(f.id)] ingested_count")
        }
        if let minDrop = e.dropped_events_min {
            let dropped = DroppedEventsCounter.getAndReset()
            XCTAssertGreaterThanOrEqual(dropped, minDrop, "[\(f.id)] dropped_events_min (got \(dropped))")
        }
        if e.no_duplicate_event_id == true {
            XCTAssertEqual(Set(ingested.map { $0.event_id }).count, ingested.count, "[\(f.id)] no_duplicate_event_id")
        }
        if e.monotonic_client_seq == true {
            let seqs = ingested.compactMap { $0.context.client_seq }
            XCTAssertEqual(seqs.count, ingested.count, "[\(f.id)] every ingested event carries a client_seq")
            // Assert the INGESTED (returned) order is ALREADY ascending by client_seq — do NOT sort
            // first. This is what `ingested_order_key: client_seq` promises: the store returns events
            // in client_seq order, never wall-clock. A CL-6 intra-second reorder regression fails here.
            for i in 1..<max(seqs.count, 1) where i < seqs.count {
                XCTAssertGreaterThan(seqs[i], seqs[i - 1], "[\(f.id)] ingested client_seq strictly increasing IN RETURNED ORDER (index \(i))")
            }
        }
        // A `redeliver` step MUST actually re-send unacked events (else the idempotency guarantee is
        // never exercised): the raw send count exceeds the deduped ingested count only if the same
        // event_ids were re-sent and the sink collapsed them.
        if hadRedeliver {
            XCTAssertGreaterThan(rawSent, ingested.count, "[\(f.id)] redeliver must re-send unacked events (raw \(rawSent) vs ingested \(ingested.count))")
        }

        store.clearAll()
        resetCounters()
    }

    // MARK: - Pre-init client_seq carry (SPEC-428 STEP-9/§4.E) + persistence (D6)

    /// A pre-init event STAMPS its client_seq at facade track() time and carries it through the drain,
    /// used VERBATIM. This proves the configure-window inversion is fixed: even though the pre-init event
    /// is BUILT after a later post-configure event, its reserved (earlier-stamped) seq stays lower.
    func testPreInitClientSeqCarry() {
        resetCounters()
        let id = DeviceIdentity(anonId: "spec428-anon", userId: nil, traits: nil)
        // 1. Pre-init: stamp the seq NOW (before configure), in tracking order.
        let preInitSeq = ClientSeqCounter.next()
        // 2. A post-configure event mints during the drain window (BUILT before the pre-init drains).
        let post = EventEnvelopeBuilder.build(event: "post", properties: nil, identity: id, sessionId: "s", analyticsConsent: true)
        // 3. The pre-init event drains AFTER, carrying its reserved seq verbatim.
        let pre = EventEnvelopeBuilder.build(event: "pre", properties: nil, identity: id, sessionId: "s", analyticsConsent: true, clientSeq: preInitSeq)
        XCTAssertEqual(pre.context.client_seq, preInitSeq, "carried seq must be used verbatim, never re-minted")
        XCTAssertNotNil(post.context.client_seq)
        XCTAssertLessThan(pre.context.client_seq!, post.context.client_seq!,
            "the pre-init event keeps its reserved LOWER seq even though it was built after the post event (no inversion)")
        resetCounters()
    }

    /// D6 — client_seq is persistence-backed: it advances monotonically across independent reads.
    func testClientSeqPersistsAcrossReads() {
        resetCounters()
        let a = ClientSeqCounter.next(), b = ClientSeqCounter.next()
        XCTAssertEqual(b, a + 1)
        let c = ClientSeqCounter.next()
        XCTAssertEqual(c, b + 1)
        resetCounters()
    }

    /// D6 / STEP-6 — across a COLD restart the reserve-block resumes from the persisted CEILING: strictly
    /// greater than the last handed-out value (a gap is expected), NEVER a reuse or a reset. Exercises the
    /// restore-from-UserDefaults branch (parity with Android's clientSeqPersistsAcrossRestart).
    func testClientSeqPersistsAcrossRestart() {
        resetCounters()
        let a = ClientSeqCounter.next(), b = ClientSeqCounter.next()
        XCTAssertEqual(b, a + 1)
        ClientSeqCounter.simulateRestartForTesting() // cold restart → re-read the persisted ceiling
        let c = ClientSeqCounter.next()
        XCTAssertGreaterThan(c, b, "client_seq resumes monotonically across restart (gap OK, never reuse/reset)")
        resetCounters()
    }

    /// R14 / §6 — concurrent next() from many threads must NEVER hand out a duplicate client_seq.
    func testClientSeqConcurrentEmitUnique() {
        resetCounters()
        let count = 800
        var seqs = [Int64](repeating: 0, count: count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let s = ClientSeqCounter.next()
            lock.lock(); seqs[i] = s; lock.unlock()
        }
        XCTAssertEqual(Set(seqs).count, count, "R14: concurrent next() must never hand out a duplicate client_seq")
        resetCounters()
    }

    // MARK: - Loading

    private func loadEventFixtures() throws -> [Fixture] {
        guard let root = SharedFixtureTests.fixturesRootURL()?.appendingPathComponent("events") else {
            XCTFail("Could not locate packages/sdk-shared-fixtures/events")
            return []
        }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Cannot enumerate \(root.path)")
            return []
        }
        let decoder = JSONDecoder()
        var out: [Fixture] = []
        for url in items where url.lastPathComponent.hasSuffix(".fixture.json") {
            let data = try Data(contentsOf: url)
            do {
                let f = try decoder.decode(Fixture.self, from: data)
                if f.category == "events" && f.platforms.contains("ios") { out.append(f) }
            } catch {
                XCTFail("Failed to decode \(url.lastPathComponent): \(error)")
            }
        }
        return out.sorted { $0.id < $1.id }
    }
}
