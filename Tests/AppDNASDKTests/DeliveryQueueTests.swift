// DeliveryQueueTests.swift
//
// SPEC-497 §13a.2, D-R40-1 — the iOS durable delivery queue (`PurchaseDeliveryQueue`, an actor):
// Q1 one write, Q2 drain-only delivery, Q3 in-flight marking and one pass per snapshot, queue rule 4
// (identity), Q5 revocation removal, the deferred emit, the `assignBillingDelegate` trigger and its
// `deliversPurchases: false` opt-out, "no drain before configure", the cap and the 30-day purge.

import XCTest
@testable import AppDNASDK

final class DeliveryQueueTests: XCTestCase {

    private final class Recorder: AppDNABillingDelegate {
        var delivered: [String] = []
        func onPurchaseCompleted(productId: String, transaction: TransactionInfo) {
            delivered.append(transaction.transactionId)
        }
    }

    private final class World {
        var currentUser: String?
        var firstUser: String?
        var delegate: Recorder? = Recorder()
        var now = Date()
        let suite = "ai.appdna.sdk.test.queue.\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suite)!
        var events: [SDKEvent] = []
        lazy var tracker: EventTracker = {
            let t = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "t.\(UUID())")))
            t.eventSink = { [unowned self] in self.events.append($0) }
            return t
        }()

        func env() -> PurchaseDeliveryQueue.Environment {
            PurchaseDeliveryQueue.Environment(
                defaults: defaults,
                now: { [unowned self] in self.now },
                currentToken: { [unowned self] in self.currentUser.flatMap { AppAccountTokenResolver.token(forUserId: $0) } },
                firstIdentifiedToken: { [unowned self] in self.firstUser.flatMap { AppAccountTokenResolver.token(forUserId: $0) } },
                deliveringDelegate: { [unowned self] in self.delegate },
                tracker: { [unowned self] in self.tracker }
            )
        }
    }

    private func entry(_ id: String, owner: String? = nil, emitPending: Bool = false,
                       properties: [String: AnyCodable]? = nil, isSubscription: Bool = false) -> PendingDelivery {
        PendingDelivery(
            transactionId: id, productId: "p_\(id)", purchaseTime: 1_000,
            ownerToken: owner.flatMap { AppAccountTokenResolver.token(forUserId: $0)?.uuidString.lowercased() },
            emitPending: emitPending, properties: properties, isSubscription: isSubscription
        )
    }

    // MARK: - Q1 / Q2

    func testReportIsOneWriteOfReportedSetAndEntryAndNoInlineDelivery() async throws {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.recordReport(entry("1"))
        let data = try XCTUnwrap(w.defaults.data(forKey: PurchaseDeliveryQueue.storageKey))
        let store = try JSONDecoder().decode(DeliveryStore.self, from: data)
        XCTAssertEqual(store.reported, ["1"])
        XCTAssertEqual(store.entries.map(\.transactionId), ["1"])
        XCTAssertEqual(w.delegate?.delivered, [], "a queued report is delivered only by the drain")
    }

    func testNoDrainBeforeActivation() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.recordReport(entry("1"))
        let delivered = await q.drain()
        XCTAssertEqual(delivered, [])
        XCTAssertEqual(w.delegate?.delivered, [])
        await q.activate()
        _ = await q.drain()
        XCTAssertEqual(w.delegate?.delivered, ["1"], "trigger (iv): delivered once configure activated the queue")
        let left = await q.queuedIds()
        XCTAssertEqual(left, [])
    }

    /// An in-process restart (`shutdown()` → `configure()`) reads the PERSISTED store, never the previous
    /// run's memory. The store was cleared in between (a host wiping its defaults on sign-out): a late
    /// purchase whose id the previous run had reported must be reported and queued again — it used to be
    /// `alreadyReported` from the stale in-memory copy (finished silently, no event, no delivery), and
    /// the next write resurrected the wiped entries.
    func testRestartReadsThePersistedStoreNotThePreviousRunsMemory() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate(session: 1)
        await q.recordReport(entry("7"))
        var reported = await q.isReported("7")
        XCTAssertTrue(reported)

        await q.deactivate(session: 1)                                     // shutdown()
        w.defaults.removeObject(forKey: PurchaseDeliveryQueue.storageKey)  // the host clears its defaults
        await q.activate(session: 2)                                       // configure()

        reported = await q.isReported("7")
        XCTAssertFalse(reported, "a cleared store must not come back from memory after a restart")
        var ids = await q.queuedIds()
        XCTAssertEqual(ids, [], "the wiped queue entry must not come back either")

        await q.recordReport(entry("8"))
        ids = await q.queuedIds()
        XCTAssertEqual(ids, ["8"], "the next write persists only this run's state")
    }

    /// The restart does not LOSE anything either: what was persisted before `shutdown()` is still there
    /// after `configure()`.
    func testRestartKeepsWhatWasPersisted() async {
        let w = World()
        w.delegate = nil
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate(session: 1)
        await q.recordReport(entry("7"))
        await q.deactivate(session: 1)
        await q.activate(session: 2)
        let reported = await q.isReported("7")
        let ids = await q.queuedIds()
        XCTAssertTrue(reported)
        XCTAssertEqual(ids, ["7"])
    }

    /// SPEC-497 I4 minor 3 — `shutdown(); configure()` on one tick, with the two Tasks running out of
    /// order: the new session's `activate(2)` lands BEFORE the old session's `deactivate(1)`, and the host
    /// wiped its defaults in between. The late `deactivate(1)` must neither deactivate session 2 nor bring
    /// session 1's in-memory store back: the queue stays active and reads only what is persisted.
    func testOutOfOrderActivateThenStaleDeactivateWithAWipedStore() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        w.delegate = nil                                                   // keep "7" queued in session 1
        await q.activate(session: 1)
        await q.recordReport(entry("7"))

        w.defaults.removeObject(forKey: PurchaseDeliveryQueue.storageKey)  // the host clears its defaults
        await q.activate(session: 2)                                       // configure() #2 runs first …
        await q.deactivate(session: 1)                                     // … then shutdown() #1's Task

        let active = await q.isActive
        XCTAssertTrue(active, "a stale deactivate must not end the newer session")
        let reported = await q.isReported("7")
        XCTAssertFalse(reported, "session 1's memory must not come back")
        var ids = await q.queuedIds()
        XCTAssertEqual(ids, [], "the wiped entry must not come back")

        // A late activate of the ended session is ignored too (it cannot re-read / reorder anything).
        await q.activate(session: 1)
        w.delegate = Recorder()
        await q.recordReport(entry("8"))
        let delivered = await q.drain()
        XCTAssertEqual(delivered, ["8"])
        XCTAssertEqual(w.delegate?.delivered, ["8"])
        ids = await q.queuedIds()
        XCTAssertEqual(ids, [])
        let persisted = w.defaults.data(forKey: PurchaseDeliveryQueue.storageKey)
            .flatMap { try? JSONDecoder().decode(DeliveryStore.self, from: $0) }
        XCTAssertEqual(persisted?.reported, ["8"], "only this session's report is persisted")
    }

    /// SPEC-497 I4 minor 3 — a drain SUSPENDED at step (b) (inside `MainActor.run`, held there by a
    /// gate-awaiting delegate provider) across `deactivate` → wipe → `activate`, which then resumes. The
    /// actor is free while the drain is suspended, so the restart and a new report run meanwhile. On
    /// resume the call completes once, step (c) removes the entry from the store the NEW session reads —
    /// without resurrecting the wiped state or clobbering the report made meanwhile — and nothing is
    /// delivered twice.
    func testDrainSuspendedAtStepBAcrossRestartResumesCleanly() async {
        let w = World()
        let recorder = Recorder()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let gateOnce = NSLock()
        var gated = false
        let env = PurchaseDeliveryQueue.Environment(
            defaults: w.defaults,
            now: { Date() },
            currentToken: { nil },
            firstIdentifiedToken: { nil },
            deliveringDelegate: {
                gateOnce.lock()
                let first = !gated
                gated = true
                gateOnce.unlock()
                if first {
                    entered.signal()
                    gate.wait()           // holds the main actor: the drain is suspended in step (b)
                }
                return recorder
            },
            tracker: { nil }
        )
        let q = PurchaseDeliveryQueue(environment: env)
        await q.activate(session: 1)
        await q.recordReport(entry("s1"))

        let drain = Task.detached { await q.drain() }
        let reachedStepB = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { c.resume(returning: entered.wait(timeout: .now() + 10) == .success) }
        }
        XCTAssertTrue(reachedStepB, "the drain reached step (b)")

        // While it is suspended: shutdown() → the host wipes its defaults → configure() → a new report.
        await q.deactivate(session: 1)
        w.defaults.removeObject(forKey: PurchaseDeliveryQueue.storageKey)
        await q.activate(session: 2)
        await q.recordReport(entry("s2"))
        var ids = await q.queuedIds()
        XCTAssertEqual(ids, ["s2"], "the wipe dropped s1 from the new session's store")

        gate.signal()
        let delivered = await drain.value
        XCTAssertEqual(delivered, ["s1"], "the suspended call completed once")
        XCTAssertEqual(recorder.delivered, ["s1"])

        ids = await q.queuedIds()
        XCTAssertEqual(ids, ["s2"], "step (c) kept the new report and did not resurrect s1")
        let reported = await q.isReported("s1")
        XCTAssertFalse(reported, "the wiped reported set was not written back")

        _ = await q.drain()
        XCTAssertEqual(recorder.delivered, ["s1", "s2"], "s1 never delivered twice; s2 delivered by the next drain")
        ids = await q.queuedIds()
        XCTAssertEqual(ids, [])
    }

    func testNoDelegateKeepsItQueued() async {
        let w = World()
        w.delegate = nil
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        await q.recordReport(entry("1"))
        _ = await q.drain()
        let left = await q.queuedIds()
        XCTAssertEqual(left, ["1"])
    }

    // MARK: - Identity (queue rule 4)

    func testUntaggedEntryGoesToAnonymousOrTheFirstIdentifiedUserOnly() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        await q.recordReport(entry("u1"))
        w.currentUser = "user_b"; w.firstUser = "user_a"
        _ = await q.drain()
        XCTAssertEqual(w.delegate?.delivered, [], "untagged history is not inherited by a non-first user")
        w.currentUser = "user_a"
        _ = await q.drain()
        XCTAssertEqual(w.delegate?.delivered, ["u1"])

        await q.recordReport(entry("u2"))
        w.currentUser = nil
        _ = await q.drain()
        XCTAssertEqual(w.delegate?.delivered, ["u1", "u2"], "an anonymous user gets untagged entries")
    }

    func testTaggedEntryGoesOnlyToItsOwner() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        await q.recordReport(entry("t1", owner: "user_a"))
        _ = await q.drain()                          // anonymous
        w.currentUser = "user_b"; w.firstUser = "user_b"
        _ = await q.drain()                          // another user
        XCTAssertEqual(w.delegate?.delivered, [])
        w.currentUser = "user_a"
        _ = await q.drain()
        XCTAssertEqual(w.delegate?.delivered, ["t1"])
    }

    // MARK: - Q3

    func testTwoConcurrentDrainsDeliverOnce() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        for i in 0..<5 { await q.recordReport(entry("c\(i)")) }
        async let a = q.drain()
        async let b = q.drain()
        let (da, db) = await (a, b)
        XCTAssertEqual(Set(da).intersection(Set(db)), [], "no entry delivered by both drains")
        XCTAssertEqual(w.delegate?.delivered.sorted(), ["c0", "c1", "c2", "c3", "c4"])
    }

    // MARK: - Q5

    func testRevocationRemovesTheEntry() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.recordReport(entry("r1"))
        await q.recordDeferred(entry("r2", owner: "user_a", emitPending: true))
        await q.removeEntry(transactionId: "r1")
        await q.removeEntry(transactionId: "r2")
        let left = await q.queuedIds()
        XCTAssertEqual(left, [])
    }

    // MARK: - deferToOwner

    func testDeferredEntryIsEmittedOnceWhenItsOwnerIdentifiesEvenWithoutADelegate() async {
        let w = World()
        w.delegate = nil
        let q = PurchaseDeliveryQueue(environment: w.env())
        await q.activate()
        let props: [String: AnyCodable] = ["product_id": AnyCodable("p_d1"), "paywall_id": AnyCodable(""),
                                           "purchased_at_ms": AnyCodable(1_788_256_800_000)]
        await q.recordDeferred(entry("d1", owner: "user_a", emitPending: true, properties: props, isSubscription: true))
        _ = await q.drain()
        XCTAssertTrue(w.events.isEmpty, "not emitted before the owner identifies")

        w.currentUser = "user_a"; w.firstUser = "user_a"
        _ = await q.drain()
        XCTAssertEqual(w.events.map(\.event_name), ["purchase_completed", "subscription_started"])
        XCTAssertEqual(w.events.first?.properties?["emitted_by"]?.value as? String, "sdk")
        let isReported = await q.isReported("d1")
        XCTAssertTrue(isReported)

        _ = await q.drain()
        XCTAssertEqual(w.events.count, 2, "emitted once; still queued for the delegate")
        w.delegate = Recorder()
        _ = await q.drain()
        XCTAssertEqual(w.delegate?.delivered, ["d1"])
    }

    // MARK: - Cap and purge

    func testCapDropsTheOldestAndThirtyDayPurge() async {
        let w = World()
        let q = PurchaseDeliveryQueue(environment: w.env())
        for i in 0..<(PurchaseDeliveryQueue.queueCap + 3) { await q.recordReport(entry("e\(i)")) }
        var ids = await q.queuedIds()
        XCTAssertEqual(ids.count, PurchaseDeliveryQueue.queueCap)
        XCTAssertEqual(ids.first, "e3")

        w.now = w.now.addingTimeInterval(31 * 24 * 3600)
        await q.activate()                            // activation purges
        ids = await q.queuedIds()
        XCTAssertEqual(ids, [])
    }

    // MARK: - The billing module's trigger (ii) and the deliversPurchases opt-out

    func testSetDelegateDrainsOnlyForADeliveringDelegate() async throws {
        let w = World()
        let shared = PurchaseDeliveryQueue.shared
        var env = w.env()
        env.deliveringDelegate = { AppDNA.billing.deliveringDelegate() }
        await shared.activate(environment: env)
        defer {
            AppDNA.billing.setDelegate(nil)
        }
        await shared.recordReport(entry("s1"))

        let quiet = Recorder()
        AppDNA.billing.setDelegate(quiet, deliversPurchases: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = await shared.drain()
        XCTAssertEqual(quiet.delivered, [], "a deliversPurchases:false delegate is never called by the drain")
        XCTAssertTrue(AppDNA.billingDelegate === quiet, "it is still the billing delegate")

        let host = Recorder()
        AppDNA.billingDelegate = host                 // = setDelegate(host, deliversPurchases: true)
        for _ in 0..<50 where host.delivered.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(host.delivered, ["s1"], "setting a delivering delegate drains the queue")

        await shared.deactivate()
        await shared.activate(environment: .production)
        await shared.deactivate()
    }
}
