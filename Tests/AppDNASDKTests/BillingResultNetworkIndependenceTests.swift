// BillingResultNetworkIndependenceTests.swift
//
// SPEC-497 round 28 — a purchase or restore result never waits on `/billing/entitlements`.
//
// `purchase()`, `restorePurchases()` and the paywall's purchase / restore success all AWAITED
// `refreshEntitlementCache()`, which for an identified user awaits `GET /billing/entitlements` (30 s timeout,
// 3 retries) behind every earlier refresh on the serial chain. On a degraded network the purchase result, the
// paywall's `onPaywallPurchaseCompleted` and its auto-dismiss stalled for up to ~2 minutes after StoreKit had
// answered. Now:
//   - the four call sites queue the refresh and return (`refreshInBackground`);
//   - a pass waits at most `serverReadDeadline` for the server, goes on with the cached rows, and applies a
//     late answer as one more pass — one more change when it differs, none when it matches, none when a sign-out
//     or a newer answer overtook it.
//
// NEGATIVE CONTROLS (run on the Mac against patched sources, see the round-28 report):
//   - the four call sites awaiting `refreshEntitlementCache()` again → the four "completes promptly" tests fail;
//   - `readServer` awaiting the request with no deadline → the "slow server" tests fail.

import XCTest
import UIKit
@testable import AppDNASDK

final class BillingResultNetworkIndependenceTests: XCTestCase {

    typealias FakeBridge = BillingEntitlementAndVerificationTests.FakeBridge
    typealias World = BillingEntitlementAndVerificationTests.World
    typealias Spy = BillingEntitlementAndVerificationTests.Spy
    typealias AwaitGate = BillingEntitlementAndVerificationTests.AwaitGate

    private var tracker: EventTracker!
    private var suite = ""
    private var defaults: UserDefaults!
    /// Every gate a test holds — opened in `tearDown`, so no suspended read outlives the test.
    private var gates: [AwaitGate] = []

    private let crossRow = ServerEntitlement(productId: "cross", store: "google_play", status: "active",
                                             expiresAt: nil, isTrial: false, offerType: nil)

    override func setUp() {
        super.setUp()
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)")))
        tracker.eventSink = { _ in }
        suite = "ai.appdna.sdk.test.r28.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        gates = []
    }

    override func tearDown() {
        gates.forEach { $0.open() }
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A module for an identified user whose server read suspends on `gate` (then answers `world.server`).
    private func makeModule(_ bridge: FakeBridge, _ world: World, spy: Spy, gate: AwaitGate,
                            deadline: TimeInterval) -> AppDNA.BillingModule {
        gates.append(gate)
        let module = AppDNA.BillingModule()
        module.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        module.entitlementSources = EntitlementSources(
            server: { _ in world.serverCalls += 1; await gate.wait(); return world.server },
            localExpirations: { _, _ in [:] },
            currentUserId: { world.userId },
            defaults: defaults,
            now: { world.now }
        )
        module.serverReadDeadline = deadline
        module.setDelegate(spy, deliversPurchases: false)
        return module
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run {}
    }

    final class DoneFlag: @unchecked Sendable { let lock = NSLock(); var done = false }

    /// Runs `work` and reports whether it finished within `seconds` (the work keeps running if not).
    private func finishes<T>(within seconds: TimeInterval, _ work: @escaping () async throws -> T) async -> Bool {
        let flag = DoneFlag()
        Task { _ = try? await work(); flag.lock.lock(); flag.done = true; flag.lock.unlock() }
        return await waitUntil(seconds) { flag.lock.lock(); defer { flag.lock.unlock() }; return flag.done }
    }

    // MARK: - Direct API

    /// An identified user, `/billing/entitlements` held indefinitely, and an earlier refresh already holding
    /// the serial chain: `purchase()` and `restorePurchases()` return at once. The deadline is set far away so
    /// only "not awaited" can make this pass. NEGATIVE CONTROL: with `await refreshEntitlementCache()` back
    /// in `purchase` / `restorePurchases`, neither returns while the gate is shut.
    func testPurchaseAndRestoreCompletePromptlyWhileTheServerAndAPredecessorAreHeld() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        world.server = [crossRow]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 60)
        let predecessor = Task { await module.refreshEntitlementCache() }
        let held = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(held, "the predecessor never reached the server read")

        bridge.ids = ["p"]
        let purchased = await finishes(within: 1) { try await module.purchase("p") }
        XCTAssertTrue(purchased, "purchase() waited on /billing/entitlements")
        let restored = await finishes(within: 1) { try await module.restorePurchases() }
        XCTAssertTrue(restored, "restorePurchases() waited on /billing/entitlements")
        XCTAssertEqual(spy.changes.count, 0, "nothing can be reported while the chain is held")

        gate.open()
        await predecessor.value
        await module.refreshEntitlementCache()     // drains the queued passes
        let reported = await waitUntil { spy.changes.last.map { Set($0.map(\.productId)) } == ["p", "cross"] }
        XCTAssertTrue(reported, "the purchase was never reported: \(spy.changes.map { $0.map(\.productId) })")
    }

    /// The entitlement change still fires once the server answers — exactly once, with the purchase and the
    /// server's row. NEGATIVE CONTROL: with the awaited refresh, `purchase()` does not return before the gate
    /// opens (the first assertion fails).
    func testThePurchaseChangeFiresOnceWhenTheServerAnswers() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        world.server = [crossRow]
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 60)

        let purchased = await finishes(within: 1) { try await module.purchase("p") }
        XCTAssertTrue(purchased, "purchase() waited on /billing/entitlements")
        let reading = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(reading, "the queued refresh never read the server")
        XCTAssertEqual(spy.changes.count, 0)

        gate.open()
        let reported = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(reported)
        await settle()
        XCTAssertEqual(spy.changes.count, 1, "exactly one change")
        XCTAssertEqual(Set(spy.changes.first?.map(\.productId) ?? []), ["p", "cross"])
    }

    // MARK: - The server-read deadline

    /// A server slower than `serverReadDeadline`: the pass reports the device's state on the cached rows, and
    /// the answer — when it arrives — is exactly one more change. NEGATIVE CONTROL: with no deadline the pass
    /// waits for the gate, so no change is reported before it opens (the first wait fails).
    func testASlowServerFallsBackToTheCacheAndTheLateAnswerIsOneMoreChange() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        world.server = [crossRow]
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)

        let bounded = await finishes(within: 1.5) { await module.refreshEntitlementCache() }
        XCTAssertTrue(bounded, "the pass waited past serverReadDeadline")
        let local = await waitUntil(1) { spy.changes.count == 1 }
        XCTAssertTrue(local, "the device's state was not reported before the server answered")
        XCTAssertEqual(spy.changes.first?.map(\.productId), ["p"])

        gate.open()
        let late = await waitUntil { spy.changes.count == 2 }
        XCTAssertTrue(late, "the late server answer was never applied")
        await settle()
        XCTAssertEqual(spy.changes.count, 2, "the late answer is exactly one more change")
        XCTAssertEqual(Set(spy.changes.last?.map(\.productId) ?? []), ["p", "cross"])
        XCTAssertEqual(ServerOnlyEntitlementCache.load(defaults)?.items.map(\.productId), ["cross"], "the late answer is the new cache")
    }

    /// A late answer equal to the cached rows changes nothing.
    func testALateAnswerEqualToTheCacheIsNoChange() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        world.server = [crossRow]
        bridge.ids = ["p"]
        ServerOnlyEntitlementCache.save(userId: "user-1", items: [crossRow], defaults)
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)

        await module.refreshEntitlementCache()
        let first = await waitUntil(1) { spy.changes.count == 1 }
        XCTAssertTrue(first)
        XCTAssertEqual(Set(spy.changes.first?.map(\.productId) ?? []), ["p", "cross"], "the cached row stands in")
        gate.open()
        let applied = await waitUntil { world.serverCalls == 1 && gate.entered == 1 }
        XCTAssertTrue(applied)
        await settle()
        await module.refreshEntitlementCache()   // drains the late pass (this one reads the open gate)
        await settle()
        XCTAssertEqual(spy.changes.count, 1, "an answer matching the cache is not a change")
    }

    /// A late answer overtaken by a sign-out is dropped: the signed-out user's rows are neither saved nor reported.
    func testALateAnswerAfterASignOutIsDropped() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        world.server = [crossRow]
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)

        await module.refreshEntitlementCache()
        let first = await waitUntil(1) { spy.changes.count == 1 }
        XCTAssertTrue(first)
        world.userId = nil                           // `AppDNA.reset()`
        module.clearServerOnlyEntitlementCache()
        gate.open()
        await settle()
        await module.refreshEntitlementCache()
        await settle()
        XCTAssertNil(ServerOnlyEntitlementCache.load(defaults), "the late answer re-saved the signed-out user's rows")
        XCTAssertFalse(spy.changes.flatMap { $0 }.contains { $0.productId == "cross" },
                       "the signed-out user's server row was reported")
    }

    /// A late answer older than one already applied is not applied: it would report an older state back.
    func testALateAnswerOlderThanTheAppliedOneIsNotApplied() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)
        final class Calls: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        let calls = Calls()
        let old = ServerEntitlement(productId: "old", store: "google_play", status: "active", expiresAt: nil, isTrial: false, offerType: nil)
        let new = ServerEntitlement(productId: "new", store: "google_play", status: "active", expiresAt: nil, isTrial: false, offerType: nil)
        module.entitlementSources.server = { _ in
            calls.lock.lock(); calls.n += 1; let n = calls.n; calls.lock.unlock()
            if n == 1 { await gate.wait(); return [old] }   // the slow, older read
            return [new]
        }

        await module.refreshEntitlementCache()        // times out: reports ["p"]
        await module.refreshEntitlementCache()        // answers at once: ["p", "new"]
        let both = await waitUntil(1) { spy.changes.count == 2 }
        XCTAssertTrue(both, "\(spy.changes.map { $0.map(\.productId) })")
        gate.open()                                   // the older answer arrives last
        await settle()
        await module.refreshEntitlementCache()
        await settle()
        XCTAssertFalse(spy.changes.flatMap { $0 }.contains { $0.productId == "old" }, "an older answer was reported over a newer one")
        XCTAssertEqual(Set(spy.changes.last?.map(\.productId) ?? []), ["p", "new"])
        XCTAssertEqual(ServerOnlyEntitlementCache.load(defaults)?.items.map(\.productId), ["new"])
    }

    // MARK: - Paywall

    final class PaywallSpy: AppDNAPaywallDelegate {
        private let lock = NSLock()
        private var _completed: [String] = []
        private var _restored: [[String]] = []
        var completed: [String] { lock.lock(); defer { lock.unlock() }; return _completed }
        var restored: [[String]] { lock.lock(); defer { lock.unlock() }; return _restored }
        func onPaywallPresented(paywallId: String) {}
        func onPaywallAction(paywallId: String, action: PaywallAction) {}
        func onPaywallPurchaseStarted(paywallId: String, productId: String) {}
        func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {
            lock.lock(); _completed.append(productId); lock.unlock()
        }
        func onPaywallPurchaseFailed(paywallId: String, error: Error) {}
        func onPaywallDismissed(paywallId: String) {}
        func onPaywallRestoreCompleted(paywallId: String, productIds: [String]) {
            lock.lock(); _restored.append(productIds); lock.unlock()
        }
    }

    /// The paywall's purchase success (`onPaywallPurchaseCompleted`, the post-purchase action) and restore success
    /// (`onPaywallRestoreCompleted`, the auto-dismiss) fire at once while `/billing/entitlements` and an earlier
    /// refresh are held. NEGATIVE CONTROL: with `await AppDNA.billing.refreshEntitlementCache()` back in
    /// `PaywallManager`, neither callback fires while the gate is shut.
    func testPaywallPurchaseAndRestoreSucceedPromptlyWhileTheServerAndAPredecessorAreHeld() async {
        let billing = AppDNA.billing
        let prior = (configured: billing.configured, bridge: billing.bridge, policy: billing.ownershipPolicy,
                     tracker: billing.eventTracker, sources: billing.entitlementSources, delegate: billing.currentDelegate,
                     delivers: billing.currentDelegateDelivers, fingerprint: billing.lastKnownFingerprintForTesting,
                     deadline: billing.serverReadDeadline)
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        gates.append(gate)
        bridge.ids = ["pro_monthly"]
        world.userId = "user-1"
        world.server = [crossRow]
        billing.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        billing.entitlementSources = EntitlementSources(
            server: { _ in await gate.wait(); return world.server }, localExpirations: { _, _ in [:] },
            currentUserId: { world.userId }, defaults: defaults, now: { world.now })
        billing.serverReadDeadline = 60
        billing.setDelegate(spy, deliversPurchases: false)
        let predecessor = Task { await billing.refreshEntitlementCache() }
        let held = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(held, "the predecessor never reached the server read")

        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.r28.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let payload: [String: Any] = ["id": "pw_r28", "type": "paywall",
                                      "plans": [["product_id": "pro_monthly", "price": 9.99, "currency": "USD"]]]
        guard let paywall = rcm.decodePaywallPayload(payload),
              let plan = paywall.plans?.first(where: { $0.productId == "pro_monthly" }) else {
            return XCTFail("the paywall payload did not decode")
        }
        let manager = PaywallManager(remoteConfigManager: rcm, billingBridge: bridge,
                                     billingPolicy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true),
                                     eventTracker: tracker)
        let paywallSpy = PaywallSpy()
        await MainActor.run {
            manager.handlePurchase(paywallId: "pw_r28", plan: plan, config: paywall, delegate: paywallSpy,
                                   viewController: UIViewController())
        }
        let completed = await waitUntil(1) { !paywallSpy.completed.isEmpty }
        XCTAssertTrue(completed, "onPaywallPurchaseCompleted waited on /billing/entitlements")

        await MainActor.run {
            manager.handleRestore(paywallId: "pw_r28", delegate: paywallSpy, viewController: UIViewController(),
                                  dismissGuard: PaywallDismissGuard())
        }
        let restored = await waitUntil(1) { !paywallSpy.restored.isEmpty }
        XCTAssertTrue(restored, "onPaywallRestoreCompleted waited on /billing/entitlements")

        gate.open()
        await predecessor.value
        await billing.refreshEntitlementCache()      // drain the chain before restoring
        await settle()
        billing.assignBillingDelegate(prior.delegate, delivers: prior.delivers)
        billing.entitlementSources = prior.sources
        billing.lastKnownFingerprintForTesting = prior.fingerprint
        billing.serverReadDeadline = prior.deadline
        if prior.configured {
            billing.wire(bridge: prior.bridge, policy: prior.policy, tracker: prior.tracker)
        } else {
            billing.teardown()
            billing.bridge = prior.bridge
            billing.eventTracker = prior.tracker
        }
    }
}
