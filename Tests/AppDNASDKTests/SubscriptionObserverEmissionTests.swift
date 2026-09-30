// SubscriptionObserverEmissionTests.swift
//
// SPEC-497 §3.10 (round-12 SDK minor 1) — the EMISSION half of the ownership tests, always hostless: the
// observer's injectable `loadCurrent` feeds scripted snapshots, and per `emitsLifecycleEvents` the three
// lifecycle events are emitted or not — while the snapshot is persisted in both cases (a later switch to
// `storeKit2` must diff against a current baseline, not emit a burst of stale events).
// Plus §13e.5 rule 2: the ids and `cancel_semantics`, and old snapshots without ids still decoding.

import XCTest
@testable import AppDNASDK

final class SubscriptionObserverEmissionTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!
    private var events: [SDKEvent] = []
    private var tracker: EventTracker!

    override func setUp() {
        super.setUp()
        suite = "ai.appdna.sdk.test.observer.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        events = []
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "t.\(UUID())")))
        tracker.eventSink = { [weak self] in self?.events.append($0) }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func observer(emits: Bool, current: [String: SubSnapshot]) -> SubscriptionStatusObserver {
        SubscriptionStatusObserver(
            eventTracker: tracker, defaults: defaults, mode: .providerOwned,
            emitsLifecycleEvents: emits, loadCurrent: { current }
        )
    }

    private let renewedPrev = ["m": SubSnapshot(productId: "m", purchaseTime: 1, isAutoRenewing: true, transactionId: "t1", originalTransactionId: "t0")]
    private let renewedNow = ["m": SubSnapshot(productId: "m", purchaseTime: 2, isAutoRenewing: true, transactionId: "t2", originalTransactionId: "t0")]

    func testRevenueCatPolicySuppressesLifecycleEventsButPersistsTheSnapshot() async {
        let o = observer(emits: false, current: renewedNow)
        o.saveSnapshot(renewedPrev)
        await o.reconcile()
        XCTAssertTrue(events.isEmpty, "owner Q2: RevenueCat's webhook is the single source")
        XCTAssertEqual(o.loadSnapshot(), renewedNow, "the snapshot keeps being persisted")

        // Vanished products too.
        let gone = observer(emits: false, current: [:])
        await gone.reconcile()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(gone.loadSnapshot(), [:])
    }

    func testAdaptyAndStoreKit2PoliciesEmitWithIds() async {
        let o = observer(emits: true, current: renewedNow)
        o.saveSnapshot(renewedPrev)
        await o.reconcile()
        XCTAssertEqual(events.map(\.event_name), ["subscription_renewed"])
        let p = events[0].properties
        XCTAssertEqual(p?["transaction_id"]?.value as? String, "t2", "the CURRENT ids on a renewal")
        XCTAssertEqual(p?["original_transaction_id"]?.value as? String, "t0")
        XCTAssertEqual(p?["emitted_by"]?.value as? String, "sdk")
    }

    func testCancelCarriesLastSeenIdsAndSemantics() async {
        let prev = ["m": SubSnapshot(productId: "m", purchaseTime: 1, isAutoRenewing: false, transactionId: "t9", originalTransactionId: "t0")]
        let o = observer(emits: true, current: [:])
        o.saveSnapshot(prev)
        await o.reconcile()
        XCTAssertEqual(events.map(\.event_name), ["subscription_canceled"])
        let p = events[0].properties
        XCTAssertEqual(p?["transaction_id"]?.value as? String, "t9")
        XCTAssertEqual(p?["cancel_semantics"]?.value as? String, "vanished_not_renewing")
    }

    /// A snapshot persisted by an older SDK (no id keys) must still decode — a required field would reset
    /// the baseline silently — and its events omit the id keys.
    func testOldSnapshotWithoutIdsStillDecodesAndOmitsKeys() async throws {
        let legacy = #"{"m":{"productId":"m","purchaseTime":1,"isAutoRenewing":true}}"#
        defaults.set(Data(legacy.utf8), forKey: SubscriptionStatusObserver.snapshotKey)
        let o = observer(emits: true, current: [:])
        XCTAssertEqual(o.loadSnapshot()["m"]?.purchaseTime, 1)
        await o.reconcile()
        XCTAssertEqual(events.map(\.event_name), ["subscription_renewal_failed"])
        XCTAssertEqual(Set(events[0].properties?.keys.map { $0 } ?? []), ["product_id", "emitted_by"])
    }
}
