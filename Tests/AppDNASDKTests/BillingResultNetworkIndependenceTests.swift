// BillingResultNetworkIndependenceTests.swift
//
// A purchase or restore result never waits on `/billing/entitlements`.
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
// NEGATIVE CONTROLS (run on the Mac against patched sources):
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
        let purchased = await finishes(within: 10) { try await module.purchase("p") }
        XCTAssertTrue(purchased, "purchase() waited on /billing/entitlements")
        let restored = await finishes(within: 10) { try await module.restorePurchases() }
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

        let purchased = await finishes(within: 10) { try await module.purchase("p") }
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

        // Generous windows: the gate never opens before them, so with no deadline they still fail; a loaded
        // runner only needs time to run the 0.2 s pass.
        let bounded = await finishes(within: 10) { await module.refreshEntitlementCache() }
        XCTAssertTrue(bounded, "the pass waited past serverReadDeadline")
        let local = await waitUntil(10) { spy.changes.count == 1 }
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
        let first = await waitUntil(10) { spy.changes.count == 1 }
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
        let first = await waitUntil(10) { spy.changes.count == 1 }
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
    ///
    /// Two passes of one user no longer produce two requests while the first is in flight — the
    /// second shares it (`joinOrStartServerRead`) — so the older answer is queued directly, as the timed-out
    /// pass would queue it (`deliverLateServerAnswer`), after a newer read has been applied.
    func testALateAnswerOlderThanTheAppliedOneIsNotApplied() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        bridge.ids = ["p"]
        // The deadline is not under test (the older answer is queued by hand below): an immediate read must
        // never miss it on a loaded runner, or request 1 itself turns into a late answer.
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 60)
        let old = ServerEntitlement(productId: "old", store: "google_play", status: "active", expiresAt: nil, isTrial: false, offerType: nil)
        let new = ServerEntitlement(productId: "new", store: "google_play", status: "active", expiresAt: nil, isTrial: false, offerType: nil)
        module.entitlementSources.server = { _ in [new] }

        await module.refreshEntitlementCache()        // request 1 answers at once: ["p", "new"]
        await module.refreshEntitlementCache()        // request 2: the same answer, no change
        let first = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(first, "\(spy.changes.map { $0.map(\.productId) })")
        // Request 1's answer, had it been slow: older than the applied request 2.
        await module.deliverLateServerAnswer(.init(userId: "user-1", rows: [old], generation: 0, sequence: 1))?.value
        await settle()
        XCTAssertFalse(spy.changes.flatMap { $0 }.contains { $0.productId == "old" }, "an older answer was reported over a newer one")
        XCTAssertEqual(Set(spy.changes.last?.map(\.productId) ?? []), ["p", "new"])
        XCTAssertEqual(ServerOnlyEntitlementCache.load(defaults)?.items.map(\.productId), ["new"])
        // Control: the same answer as the NEXT request is applied — the drop above is the sequence, not the path.
        await module.deliverLateServerAnswer(.init(userId: "user-1", rows: [old], generation: 0, sequence: 3))?.value
        await settle()
        XCTAssertEqual(Set(spy.changes.last?.map(\.productId) ?? []), ["p", "old"])
    }

    // MARK: -

    /// `identify(A)` → `identify(B)` with A's read still in flight. A switch between two identified users does
    /// NOT bump the sign-out count (`resetGeneration`), so the user check on the late answer is the only thing
    /// that stops A's rows being saved and reported as B's. NEGATIVE CONTROL: with that check reduced to the
    /// generation check (`late.generation != generation` alone), the late pass saves `cross` under user-2 and
    /// reports it — both assertions fail.
    func testALateAnswerAfterASwitchToAnotherUserIsDropped() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)
        let cross = crossRow
        module.entitlementSources.server = { uid in
            world.serverCalls += 1
            if uid == "user-1" { await gate.wait(); return [cross] }   // user-1's slow read
            return []                                                  // user-2 has no server-only rows
        }

        await module.refreshEntitlementCache()       // user-1's pass times out: ["p"]
        let first = await waitUntil(10) { spy.changes.count == 1 }
        XCTAssertTrue(first)
        world.userId = "user-2"                      // `identify("user-2")`: no `clearServerOnlyEntitlementCache`
        gate.open()                                  // user-1's answer arrives late
        await settle()
        let saved = ServerOnlyEntitlementCache.load(defaults)
        XCTAssertFalse(saved?.userId == "user-2" && saved?.items.contains { $0.productId == "cross" } == true,
                       "user-1's late answer was saved as user-2's server-only rows")
        await module.refreshEntitlementCache()       // drains the chain: user-2's own pass
        await settle()
        XCTAssertFalse(spy.changes.flatMap { $0 }.contains { $0.productId == "cross" },
                       "user-1's server row was reported for user-2: \(spy.changes.map { $0.map(\.productId) })")
        XCTAssertNotEqual(ServerOnlyEntitlementCache.load(defaults)?.items.map(\.productId), ["cross"])
    }

    /// The user check on a SHARED read (`joinOrStartServerRead`: `flight.userId == userId`). `identify(A)` →
    /// `identify(B)` does not bump the sign-out count, so while A's request is still in flight the generation
    /// alone would let B's pass join it — B would read nothing of its own, and A's rows would come back as B's
    /// answer. B's pass must start its own request, and no change may carry A's rows.
    /// NEGATIVE CONTROL: with `flight.userId == userId` deleted from the lookup, B's pass joins A's held read —
    /// no `user-2` request is made and the first assertion fails.
    func testAnotherUsersPassDoesNotShareAReadStillInFlightForThePreviousUser() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)
        let cross = crossRow
        final class CallLog: @unchecked Sendable {
            private let lock = NSLock(); private var _users: [String] = []
            func add(_ u: String) { lock.lock(); _users.append(u); lock.unlock() }
            var users: [String] { lock.lock(); defer { lock.unlock() }; return _users }
        }
        let calls = CallLog()
        module.entitlementSources.server = { uid in
            calls.add(uid)
            if uid == "user-1" { await gate.wait(); return [cross] }   // user-1's read: held
            return []                                                  // user-2: no server-only rows
        }

        await module.refreshEntitlementCache()        // user-1's pass times out; its read stays in flight
        let held = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(held, "user-1's read never reached the server")
        world.userId = "user-2"                       // `identify("user-2")`: same sign-out count
        module.serverReadDeadline = 60                 // user-2's pass waits for the read it uses
        let user2Pass = Task { await module.refreshEntitlementCache() }

        let ownRead = await waitUntil(10) { calls.users.contains("user-2") }
        XCTAssertTrue(ownRead, "user-2's pass shared user-1's read still in flight — no user-2 request: \(calls.users)")
        gate.open()                                   // user-1's answer arrives (late)
        await user2Pass.value
        await settle()
        await module.refreshEntitlementCache()        // drains the chain
        await settle()
        XCTAssertFalse(spy.changes.flatMap { $0 }.contains { $0.productId == "cross" },
                       "user-1's server row was reported while user-2 is signed in: \(spy.changes.map { $0.map(\.productId) })")
        let saved = ServerOnlyEntitlementCache.load(defaults)
        XCTAssertFalse(saved?.userId == "user-2" && saved?.items.contains { $0.productId == "cross" } == true,
                       "user-1's rows were saved as user-2's")
    }

    /// Minor 6: N passes of one user while its `/billing/entitlements` read is held issue ONE request — each
    /// waits on it for at most the deadline — and its late answer is applied once: one more change, not N.
    /// NEGATIVE CONTROL: with every pass starting its own request (no `joinOrStartServerRead` lookup), five
    /// requests are in flight and the first assertion fails.
    func testPassesDuringOneHeldRequestShareIt() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        world.server = [crossRow]
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)

        for _ in 0..<5 { await module.refreshEntitlementCache() }   // each times out on the same held read
        let reached = await waitUntil { gate.entered >= 1 }
        XCTAssertTrue(reached, "the shared request never reached the server")
        XCTAssertEqual(gate.entered, 1, "\(gate.entered) /billing/entitlements requests in flight, not one")
        XCTAssertEqual(world.serverCalls, 1)
        XCTAssertEqual(spy.changes.count, 1, "the device's state, once")

        gate.open()
        let late = await waitUntil { spy.changes.count == 2 }
        XCTAssertTrue(late, "the shared request's late answer was never applied")
        await settle()
        XCTAssertEqual(spy.changes.count, 2, "the late answer is one more change, not one per waiting pass")
        XCTAssertEqual(Set(spy.changes.last?.map(\.productId) ?? []), ["p", "cross"])

        // The request has finished: the next pass reads the server again.
        await module.refreshEntitlementCache()
        XCTAssertEqual(world.serverCalls, 2, "a pass after the shared request finished did not read again")
        await settle()
        XCTAssertEqual(spy.changes.count, 2)
    }

    /// A sign-out between two passes of the SAME user: the second pass does not share the first one's read
    /// (it started before the sign-out) — it reads again, and the first one's late answer is dropped.
    func testAPassAfterASignOutDoesNotShareTheEarlierRead() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate(); let spy = Spy()
        world.userId = "user-1"
        world.server = [crossRow]
        bridge.ids = ["p"]
        let module = makeModule(bridge, world, spy: spy, gate: gate, deadline: 0.2)

        await module.refreshEntitlementCache()            // held: request 1
        module.clearServerOnlyEntitlementCache()          // `reset()`, then `identify("user-1")` again
        await module.refreshEntitlementCache()            // a new request, also held
        // Wait for the second request to reach the server: the pass returned on its deadline, which says
        // nothing about when its request's task got to run.
        let both = await waitUntil { gate.entered == 2 }
        XCTAssertTrue(both, "the pass after the sign-out shared a read started before it (\(gate.entered) requests)")
        gate.open()
        module.serverReadDeadline = 60                    // from here the gate is open: no read may time out
        await settle()
        await module.refreshEntitlementCache()
        let reported = await waitUntil { Set(spy.changes.last?.map(\.productId) ?? []) == ["p", "cross"] }
        XCTAssertTrue(reported, "\(spy.changes.map { $0.map(\.productId) })")
    }

    /// Minor 1: the answer arrives while the deadline timer is asleep. The answer must win — it used to cancel
    /// the timer BEFORE claiming, the cancelled sleep's `CancellationError` was swallowed (`try?`), and the
    /// timer could claim in between: `.timedOut` with the answer in hand, and the same answer reported again as
    /// a late one. Deterministic: the `afterTimerCancel` seam holds the answer's side for 300 ms right after
    /// `timer.cancel()` — in the old order that is BEFORE its claim, and the woken timer always claims first.
    /// NEGATIVE CONTROL: with `timer.cancel()` before `once.claim()` AND the sleep under `try?` with no
    /// cancellation check, every attempt returns `.timedOut`. (Either fix alone passes: the claim order, or the
    /// timer returning on cancellation.)
    func testAnAnswerThatCancelsTheTimerIsNeverATimeout() async {
        for attempt in 0..<5 {
            let request = Task<[ServerEntitlement]?, Never> {
                try? await Task.sleep(nanoseconds: 50_000_000)   // the timer is asleep by now
                return []
            }
            let outcome = await AppDNA.BillingModule.firstOf(request, deadline: 60,
                                                              afterTimerCancel: { Thread.sleep(forTimeInterval: 0.3) })
            guard case .answered = outcome else {
                return XCTFail("attempt \(attempt): the answer was in, and firstOf reported a timeout")
            }
        }
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
        let completed = await waitUntil(10) { !paywallSpy.completed.isEmpty }
        XCTAssertTrue(completed, "onPaywallPurchaseCompleted waited on /billing/entitlements")

        await MainActor.run {
            manager.handleRestore(paywallId: "pw_r28", delegate: paywallSpy, viewController: UIViewController(),
                                  dismissGuard: PaywallDismissGuard())
        }
        let restored = await waitUntil(10) { !paywallSpy.restored.isEmpty }
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
