// BillingEntitlementAndVerificationTests.swift
//
// The iOS billing fixes of this release, each with the negative control it was proven against:
//
//   Entitlements  `AppDNABillingDelegate.onEntitlementsChanged` fires (it had no caller); a refresh fires
//                 only on a REAL change — the product set, `isActive` or `expiresAt` (a renewal moves the
//                 expiry); the first refresh after a launch compares against the persisted state, not
//                 against "nothing"; an expiry re-checks itself; `/billing/entitlements` rows the device
//                 does not hold are added, and an unreachable server is not a change; the payload carries
//                 the real `expiresAt` / `isActive`.
//   Observer      every reconcile pass runs `afterPass` (the entitlement refresh), and under
//                 `.providerOwned` a `Transaction.updates` item triggers a pass; `subscription_renewed`
//                 carries `price` / `currency`.
//   Verification  `ReceiptVerifier` bodies and replies; `PurchaseVerificationQueue` persists before it
//                 sends, keeps a retryable failure, drops a terminal one, never needs the purchase to wait.
//   Purchase      a Swift `CancellationError` is rethrown untracked; `TransactionInfo.environment` is the
//                 bridge's; a thrown product lookup fires `onPurchaseFailed`; the Adapty bridge emits no
//                 `purchase_started`.
//   Persistence   an undecodable delivery-queue store is logged and kept under `<key>.corrupt`.

import XCTest
@testable import AppDNASDK
@_spi(AppDNAInternal) @testable import AppDNANotificationExtension

final class BillingEntitlementAndVerificationTests: XCTestCase {

    // MARK: - Fixtures

    final class Spy: AppDNABillingDelegate {
        private let lock = NSLock()
        private var _changes: [[Entitlement]] = []
        private var _onMain: [Bool] = []
        private var _failed: [String] = []
        var changes: [[Entitlement]] { lock.lock(); defer { lock.unlock() }; return _changes }
        var onMain: [Bool] { lock.lock(); defer { lock.unlock() }; return _onMain }
        var failed: [String] { lock.lock(); defer { lock.unlock() }; return _failed }
        func onEntitlementsChanged(entitlements: [Entitlement]) {
            lock.lock(); _changes.append(entitlements); _onMain.append(Thread.isMainThread); lock.unlock()
        }
        func onPurchaseFailed(productId: String, error: Error) {
            lock.lock(); _failed.append(productId); lock.unlock()
        }
    }

    final class FakeBridge: BillingBridgeProtocol {
        var ids: [String] = []
        /// When set, `getEntitlements` answers this instead of `ids` — evaluated at the read, so a test can
        /// make the device's set depend on who the current user is (as StoreKit's does, through the
        /// `appAccountToken` filter).
        var idsAtRead: (() -> [String])?
        var purchaseError: Error?
        var result = PurchaseResult(productId: "p", transactionId: "1", price: 1, currency: "USD",
                                    provider: "storekit2", isSubscription: false, isConsumable: false)
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
            if let purchaseError { throw purchaseError }
            return result
        }
        func restore(appAccountToken: UUID?) async throws -> [String] { ids }
        private let readsLock = NSLock()
        private var _reads = 0
        /// How many times a refresh read the device's entitlements.
        var reads: Int { readsLock.lock(); defer { readsLock.unlock() }; return _reads }
        func getEntitlements(appAccountToken: UUID?) async -> [String] {
            readsLock.lock(); _reads += 1; readsLock.unlock()
            return idsAtRead?() ?? ids
        }
    }

    /// Mutable inputs the injected entitlement sources read.
    final class World {
        var expirations: [String: Date] = [:]
        var server: [ServerEntitlement]? = nil
        var userId: String? = nil
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var serverCalls = 0
        /// The `ownerFiltered` flag of every `localExpirations` read.
        var ownerFiltered: [Bool] = []
    }

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        events = []
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)")))
        tracker.eventSink = { [weak self] in self?.events.append($0) }
        suite = "ai.appdna.sdk.test.billing.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeModule(_ bridge: FakeBridge, _ world: World, spy: Spy,
                            provider: BillingProvider = .storeKit2,
                            bridgeLinked: Bool = true) -> AppDNA.BillingModule {
        let module = AppDNA.BillingModule()
        module.wire(bridge: bridge, policy: BillingOwnership.policy(for: provider, bridgeLinked: bridgeLinked), tracker: tracker)
        module.entitlementSources = EntitlementSources(
            server: { _ in world.serverCalls += 1; return world.server },
            localExpirations: { ids, ownerFiltered in world.ownerFiltered.append(ownerFiltered); return world.expirations.filter { ids.contains($0.key) } },
            currentUserId: { world.userId },
            defaults: defaults,
            now: { world.now }
        )
        module.setDelegate(spy, deliversPurchases: false)
        // No test here is about the server-read deadline (`BillingResultNetworkIndependenceTests` is). At
        // the 2.5 s default a loaded CI runner let an immediate read miss it: the pass reported without the
        // server rows and the late answer came as one more pass — an extra read and an extra change.
        module.serverReadDeadline = 60
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

    /// Wait for every block already on the SDK's serial queue (`AppDNA.reset()` is one such block) — off the
    /// cooperative pool, since the wait blocks its thread.
    static func drainSDKQueue() async {
        await Task.detached { AppDNA.drainSDKQueueForTesting() }.value
    }

    /// Let queued main-queue deliveries run, then return.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {}
    }

    // MARK: - 1. The delegate hears entitlement changes

    /// NEGATIVE CONTROL: before the fix `AppDNABillingDelegate.onEntitlementsChanged` had no caller in the
    /// SDK — only closures listened to `.entitlementsChanged` — so `spy.changes` stayed empty.
    func testBillingDelegateReceivesEntitlementsChangedOnMainThreadOnce() async {
        let spy = Spy()
        let module = AppDNA.BillingModule()
        module.setDelegate(spy, deliversPurchases: false)
        let payload = [
            ServerEntitlement(productId: "pro", store: "app_store", status: "active",
                              expiresAt: "2099-01-01T00:00:00.000Z", isTrial: false, offerType: nil),
            ServerEntitlement(productId: "old", store: "google_play", status: "expired",
                              expiresAt: nil, isTrial: false, offerType: nil),
        ]
        NotificationCenter.default.post(name: .entitlementsChanged, object: nil, userInfo: ["entitlements": payload])
        let ok1 = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok1, "the delegate must hear the change")
        await settle()
        XCTAssertEqual(spy.changes.count, 1, "once per change")
        XCTAssertEqual(spy.onMain, [true], "on the main thread")
        let got = spy.changes.first ?? []
        XCTAssertEqual(got.map(\.productId), ["pro", "old"])
        XCTAssertEqual(got.map(\.isActive), [true, false], "isActive follows the status")
        XCTAssertEqual(got.first?.expiresAt, ISO8601.date(from: "2099-01-01T00:00:00.000Z"), "the real expiry")
        withExtendedLifetime(module) {}
    }

    /// The closure and the delegate see the SAME list (one conversion).
    func testClosureAndDelegateGetTheSamePayload() async {
        let spy = Spy()
        let module = AppDNA.BillingModule()
        module.setDelegate(spy, deliversPurchases: false)
        var closureGot: [Entitlement] = []
        let token = module.onEntitlementsChanged { closureGot = $0 }
        defer { module.removeEntitlementsChangedHandler(token) }
        NotificationCenter.default.post(name: .entitlementsChanged, object: nil, userInfo: ["entitlements": [
            ServerEntitlement(productId: "a", store: "app_store", status: "trialing", expiresAt: "2099-02-01T00:00:00Z", isTrial: true, offerType: nil),
        ]])
        let ok2 = await waitUntil { spy.changes.count == 1 && !closureGot.isEmpty }
        XCTAssertTrue(ok2)
        XCTAssertEqual(closureGot.map(\.productId), spy.changes[0].map(\.productId))
        XCTAssertEqual(closureGot.map(\.expiresAt), spy.changes[0].map(\.expiresAt))
        XCTAssertEqual(closureGot.map(\.isActive), spy.changes[0].map(\.isActive))
    }

    /// Parity with the server and Android — NEGATIVE CONTROL: `billing_retry` was not in the active set, so a
    /// paying user in billing retry read `isActive == false` / `hasActiveSubscription == false`.
    func testBillingRetryCountsAsActive() {
        let row = ServerEntitlement(productId: "m", store: "app_store", status: "billing_retry",
                                    expiresAt: nil, isTrial: false, offerType: nil)
        XCTAssertEqual(AppDNA.BillingModule.publicEntitlements([row]).first?.isActive, true)
        let cache = EntitlementCache()
        defer { UserDefaults.standard.removeObject(forKey: "com.appdna.entitlements") }   // update() persists there
        cache.update(row)
        XCTAssertTrue(cache.hasActiveSubscription)
        XCTAssertNotNil(cache.entitlement(for: "m"))
    }

    // MARK: - 1b. Grace period / billing retry stay active

    /// StoreKit keeps a subscription in `Transaction.currentEntitlements` during its billing grace period
    /// although its `expirationDate` has passed. NEGATIVE CONTROL: `getEntitlements` and the refresh applied
    /// `expiresAt > now` to it, so a paying user in grace read `isActive == false`.
    func testLocalProductWithAPastExpiryStaysActive() async {
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)
        bridge.ids = ["monthly"]
        world.expirations = ["monthly": world.now.addingTimeInterval(-3_600)]
        let direct = await module.getEntitlements()
        XCTAssertEqual(direct.map(\.isActive), [true], "getEntitlements: held by the store → active")
        await module.refreshEntitlementCache()
        let ok = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(spy.changes.first?.map(\.isActive), [true], "onEntitlementsChanged: held by the store → active")
        XCTAssertEqual(spy.changes.first?.first?.expiresAt, world.expirations["monthly"], "the real (past) expiry is still carried")
    }

    /// The scheduled expiry re-check must not flip a product the store still holds after its expiry.
    /// NEGATIVE CONTROL: the re-check found the product still in `currentEntitlements` past its expiry,
    /// computed `isActive == false` and fired a second callback reporting the subscriber as inactive.
    func testScheduledRecheckDoesNotFlipAGracePeriodProduct() async {
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)
        module.expiryRecheckLeeway = 0.05
        module.entitlementSources.now = { Date() }
        bridge.ids = ["weekly"]
        world.expirations = ["weekly": Date().addingTimeInterval(0.3)]
        await module.refreshEntitlementCache()
        let ok = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok)
        // The expiry passes; StoreKit still holds the transaction (billing grace period).
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await settle()
        XCTAssertEqual(spy.changes.count, 1, "no change reported: the product is still entitled")
        XCTAssertEqual(spy.changes.last?.map(\.isActive), [true])
        let direct = await module.getEntitlements()
        XCTAssertEqual(direct.map(\.isActive), [true])
        module.teardown()
    }

    /// Server rows: `grace_period` / `billing_retry` have a past `current_period_end` by definition.
    /// NEGATIVE CONTROL: `publicEntitlements` applied the expiry check to every status, so both read
    /// inactive. An `active` row past its expiry (a canceled-but-paid row cached offline) still ends.
    func testServerRetryRowsWithAPastExpiryStayActive() async {
        let past = "2020-01-01T00:00:00.000Z"
        let rows = ["billing_retry", "grace_period", "active", "trialing", "expired"].map {
            ServerEntitlement(productId: $0, store: "app_store", status: $0, expiresAt: past, isTrial: false, offerType: nil)
        }
        XCTAssertEqual(AppDNA.BillingModule.publicEntitlements(rows).map(\.isActive), [true, true, false, false, false])

        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)
        world.userId = "user-1"
        world.server = [ServerEntitlement(productId: "cross", store: "google_play", status: "billing_retry",
                                          expiresAt: past, isTrial: false, offerType: nil)]
        await module.refreshEntitlementCache()
        let ok = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(spy.changes.first?.map(\.productId), ["cross"])
        XCTAssertEqual(spy.changes.first?.map(\.isActive), [true], "a billing_retry row from the server stays active")
    }

    // MARK: - 2. Real changes only — renewal, expiry, refund

    /// NEGATIVE CONTROL: with the old product-id-set diff, the renewal step (same product, later expiry)
    /// fired nothing — `spy.changes.count` stayed 1 there.
    func testRefreshFiresOnPurchaseRenewalAndExpiryButNotOnNoChange() async {
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)

        bridge.ids = ["monthly"]
        world.expirations = ["monthly": world.now.addingTimeInterval(30 * 86_400)]
        await module.refreshEntitlementCache()
        let ok3 = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok3, "a purchase is a change")
        XCTAssertEqual(spy.changes[0].first?.expiresAt, world.expirations["monthly"], "the StoreKit expiry is carried")

        await module.refreshEntitlementCache()
        await settle()
        XCTAssertEqual(spy.changes.count, 1, "no change → no callback")

        world.expirations = ["monthly": world.now.addingTimeInterval(60 * 86_400)]   // renewal
        await module.refreshEntitlementCache()
        let ok4 = await waitUntil { spy.changes.count == 2 }
        XCTAssertTrue(ok4, "a renewal moves the expiry → a change")

        bridge.ids = []                                                              // expiry / refund
        await module.refreshEntitlementCache()
        let ok5 = await waitUntil { spy.changes.count == 3 }
        XCTAssertTrue(ok5, "an expired or refunded product vanishing is a change")
        XCTAssertEqual(spy.changes[2].count, 0)
    }

    /// NEGATIVE CONTROL: `lastKnownEntitlementIds` started as an empty set, so the first refresh of every
    /// launch fired for any non-empty entitlement set — here that was one spurious callback.
    func testFirstRefreshAfterLaunchComparesAgainstThePersistedState() async {
        let bridge = FakeBridge(); let world = World()
        bridge.ids = ["monthly"]
        world.expirations = ["monthly": world.now.addingTimeInterval(86_400)]

        let firstLaunch = Spy()
        let module1 = makeModule(bridge, world, spy: firstLaunch)
        await module1.refreshEntitlementCache()
        let ok6 = await waitUntil { firstLaunch.changes.count == 1 }
        XCTAssertTrue(ok6)
        module1.setDelegate(nil)

        let secondLaunch = Spy()                       // a fresh module = a relaunch, same persisted defaults
        let module2 = makeModule(bridge, world, spy: secondLaunch)
        await module2.refreshEntitlementCache()
        await settle()
        XCTAssertEqual(secondLaunch.changes.count, 0, "unchanged since the last launch → nothing fires")

        bridge.ids = []
        await module2.refreshEntitlementCache()
        let ok7 = await waitUntil { secondLaunch.changes.count == 1 }
        XCTAssertTrue(ok7, "a real change still fires")
    }

    /// An expiry fires with no purchase, no foreground and no transaction: the module re-checks itself at
    /// the earliest `expiresAt`. NEGATIVE CONTROL: without `scheduleExpiryCheck` nothing refreshes and the
    /// second callback never comes.
    func testExpiryIsReportedByTheScheduledRecheck() async {
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        world.now = Date()
        let module = makeModule(bridge, world, spy: spy)
        module.expiryRecheckLeeway = 0.05
        module.entitlementSources.now = { Date() }
        // StoreKit drops the expired transaction: the re-check (the second read) finds nothing. Decided at
        // the read, not by the test thread after the first change — the re-check fires ~0.45 s in, and a
        // loaded runner could reach that before the test thread changed the set.
        bridge.idsAtRead = { bridge.reads >= 2 ? [] : ["weekly"] }
        world.expirations = ["weekly": Date().addingTimeInterval(0.4)]
        await module.refreshEntitlementCache()
        let ok8 = await waitUntil { spy.changes.count >= 1 }
        XCTAssertTrue(ok8)
        XCTAssertEqual(spy.changes.first?.map(\.productId), ["weekly"])
        let ok9 = await waitUntil(3) { spy.changes.count == 2 }
        XCTAssertTrue(ok9, "the expiry re-check reports it")
        XCTAssertEqual(spy.changes.last?.count, 0)
        module.teardown()
    }

    // MARK: - 3. /billing/entitlements

    /// Server rows the device does not hold are added; an unreachable server is not a change.
    /// NEGATIVE CONTROL: the SDK never called `/billing/entitlements` (serverCalls == 0, no "cross" row).
    func testServerOnlyEntitlementsAreAddedAndOfflineIsNotAChange() async {
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = [
            ServerEntitlement(productId: "monthly", store: "app_store", status: "active", expiresAt: nil, isTrial: false, offerType: nil),
            ServerEntitlement(productId: "cross", store: "google_play", status: "active",
                              expiresAt: "2099-01-01T00:00:00.000Z", isTrial: false, offerType: nil),
        ]
        await module.refreshEntitlementCache()
        let ok10 = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok10)
        XCTAssertEqual(world.serverCalls, 1)
        XCTAssertEqual(Set(spy.changes[0].map(\.productId)), ["monthly", "cross"], "device rows + server-only rows, no duplicate")

        world.server = nil                              // offline
        await module.refreshEntitlementCache()
        await settle()
        XCTAssertEqual(spy.changes.count, 1, "going offline is not an entitlement change")
    }

    func testAnonymousUserMakesNoServerCall() async {
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)
        bridge.ids = ["x"]
        await module.refreshEntitlementCache()
        XCTAssertEqual(world.serverCalls, 0)
    }

    func testEntitlementsEndpointPathEncodesTheUserId() {
        XCTAssertEqual(Endpoint.getEntitlements(appUserId: "a&b=c d").path,
                       "/api/v1/billing/entitlements?app_user_id=a%26b%3Dc%20d")
        XCTAssertEqual(Endpoint.getEntitlements(appUserId: "u").method, "GET")
    }

    func testFetchEntitlementsParsesTheReplyAndDropsNotEntitledRows() async {
        let reply = """
        {"data":{"has_active_subscription":true,"subscriptions":[
          {"product_id":"a","store":"app_store","status":"active","expires_at":"2099-01-01T00:00:00.000Z","is_trial":false,"entitled":true,"product_type":"subs","offer_type":null},
          {"product_id":"b","store":"app_store","status":"expired","expires_at":null,"is_trial":false,"entitled":false}
        ]}}
        """
        var sent: Endpoint?
        let verifier = ReceiptVerifier(send: { endpoint in sent = endpoint; return Data(reply.utf8) })
        let got = await verifier.fetchEntitlements(appUserId: "u1")
        XCTAssertEqual(got?.map(\.productId), ["a"])
        XCTAssertEqual(got?.first?.expiresAt, "2099-01-01T00:00:00.000Z")
        XCTAssertEqual(sent?.path, "/api/v1/billing/entitlements?app_user_id=u1")
        let failing = ReceiptVerifier(send: { _ in throw APIError.httpError(statusCode: 503, data: nil) })
        let none = await failing.fetchEntitlements(appUserId: "u1")
        XCTAssertNil(none, "a failed call is nil (fall back), never []")
    }

    // MARK: - 4. Observer triggers

    /// NEGATIVE CONTROL: without `afterPass` a pass (launch, foreground, `Transaction.updates`) never
    /// refreshed entitlements — `passes` stays 0.
    func testEveryObserverPassRunsAfterPass() async {
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock()
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n } }
        let passes = Counter()
        let observer = SubscriptionStatusObserver(
            eventTracker: tracker, defaults: defaults, mode: .providerOwned,
            loadCurrent: { [:] }, afterPass: { passes.bump() }
        )
        await observer.reconcile()
        await observer.reconcile()
        let ok11 = await waitUntil { passes.value == 2 }
        XCTAssertTrue(ok11, "one afterPass per pass")
    }

    /// Under `.providerOwned` a `Transaction.updates` item (a renewal, a refund) now triggers a pass.
    /// NEGATIVE CONTROL: before, `.providerOwned` reconciled only at start — `loads` stayed 1.
    func testProviderOwnedObserverReconcilesOnTransactionUpdateSignal() async {
        final class Loads: @unchecked Sendable { var n = 0; let lock = NSLock()
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n } }
        let loads = Loads()
        var continuation: AsyncStream<Void>.Continuation?
        let stream = AsyncStream<Void> { continuation = $0 }
        let observer = SubscriptionStatusObserver(
            eventTracker: tracker, defaults: defaults, mode: .providerOwned,
            loadCurrent: { loads.bump(); return [:] },
            updateSignals: { stream }
        )
        observer.start()
        defer { observer.stop() }
        let ok12 = await waitUntil { loads.value == 1 }
        XCTAssertTrue(ok12, "the launch pass")
        continuation?.yield(())
        let ok13 = await waitUntil { loads.value == 2 }
        XCTAssertTrue(ok13, "a Transaction.updates item triggers a pass")
    }

    /// §17-5 — NEGATIVE CONTROL: `subscription_renewed` had no `price` / `currency`.
    func testRenewalCarriesPriceAndCurrency() {
        let observer = SubscriptionStatusObserver(eventTracker: tracker, defaults: defaults, mode: .providerOwned, loadCurrent: { [:] })
        observer.diffAndEmit(
            previous: ["m": SubSnapshot(productId: "m", purchaseTime: 1, isAutoRenewing: true, price: 4.99, currency: "EUR")],
            current: ["m": SubSnapshot(productId: "m", purchaseTime: 2, isAutoRenewing: true, price: 5.99, currency: "EUR")]
        )
        let renewed = events.filter { $0.event_name == "subscription_renewed" }
        XCTAssertEqual(renewed.count, 1)
        XCTAssertEqual(renewed.first?.properties?["price"]?.value as? Double, 5.99, "the new period's price")
        XCTAssertEqual(renewed.first?.properties?["currency"]?.value as? String, "EUR")
    }

    func testRenewalWithoutAKnownPriceOmitsBothKeys() {
        let observer = SubscriptionStatusObserver(eventTracker: tracker, defaults: defaults, mode: .providerOwned, loadCurrent: { [:] })
        observer.diffAndEmit(
            previous: ["m": SubSnapshot(productId: "m", purchaseTime: 1, isAutoRenewing: true)],
            current: ["m": SubSnapshot(productId: "m", purchaseTime: 2, isAutoRenewing: true, price: 5.99, currency: nil)]
        )
        let props = events.first { $0.event_name == "subscription_renewed" }?.properties
        XCTAssertNil(props?["price"]); XCTAssertNil(props?["currency"])
    }

    func testOldSnapshotWithoutPriceStillDecodes() throws {
        let old = #"{"m":{"productId":"m","purchaseTime":1,"isAutoRenewing":true}}"#
        let decoded = try JSONDecoder().decode([String: SubSnapshot].self, from: Data(old.utf8))
        XCTAssertNil(decoded["m"]?.price)
    }

    // MARK: - 5. Server verification

    func testVerifyBodyMatchesTheAndroidShapeForIOS() {
        let body = ReceiptVerifier.verifyBody(signedTransaction: "jws.a.b", productType: "subs", billingOwner: "sdk", appUserId: "u1")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["transaction"] as? String, "jws.a.b")
        XCTAssertEqual(body["billing_owner"] as? String, "sdk")
        XCTAssertEqual(body["product_type"] as? String, "subs")
        XCTAssertEqual(body["app_user_id"] as? String, "u1")
        let anonymous = ReceiptVerifier.verifyBody(signedTransaction: "j", productType: nil, billingOwner: "sdk", appUserId: nil)
        XCTAssertNil(anonymous["app_user_id"]); XCTAssertNil(anonymous["product_type"])
    }

    func testVerifyReplyParsesTheDTOAndTheLegacyShape() throws {
        let dto = #"{"data":{"entitled":true,"product_id":"m","product_type":"subs","store":"app_store","status":"trialing","expires_at":"2099-01-01T00:00:00Z","is_trial":true,"original_transaction_id":"100","consume":false}}"#
        let v = VerifiedPurchase.parse(try JSONDecoder().decode(VerifyReply.self, from: Data(dto.utf8)).data)
        XCTAssertEqual(v.productId, "m"); XCTAssertEqual(v.productType, "subs"); XCTAssertTrue(v.isTrial)
        XCTAssertEqual(v.expiresAt, "2099-01-01T00:00:00Z"); XCTAssertEqual(v.originalTransactionId, "100")
        XCTAssertNil(v.environment, "absent on an older server")
        let sandbox = #"{"data":{"entitled":true,"product_id":"m","store":"app_store","status":"active","environment":"sandbox"}}"#
        XCTAssertEqual(VerifiedPurchase.parse(try JSONDecoder().decode(VerifyReply.self, from: Data(sandbox.utf8)).data).environment, "sandbox")
        let odd = #"{"data":{"entitled":true,"product_id":"m","store":"app_store","status":"active","environment":"Xcode"}}"#
        XCTAssertNil(VerifiedPurchase.parse(try JSONDecoder().decode(VerifyReply.self, from: Data(odd.utf8)).data).environment)
        let legacy = #"{"data":{"entitled":true,"subscription":{"product_id":"m","store":"app_store","status":"active","current_period_end":"2099-01-01T00:00:00Z"}}}"#
        let l = VerifiedPurchase.parse(try JSONDecoder().decode(VerifyReply.self, from: Data(legacy.utf8)).data)
        XCTAssertEqual(l.productId, "m"); XCTAssertEqual(l.expiresAt, "2099-01-01T00:00:00Z"); XCTAssertFalse(l.isTrial)
    }

    func testVerifyFailureClasses() {
        XCTAssertEqual(VerifyFailureClass.classify(APIError.httpError(statusCode: 422, data: nil)), .terminal)
        XCTAssertEqual(VerifyFailureClass.classify(APIError.httpError(statusCode: 409, data: nil)), .terminal)
        XCTAssertEqual(VerifyFailureClass.classify(APIError.httpError(statusCode: 401, data: nil)), .retryable)
        XCTAssertEqual(VerifyFailureClass.classify(APIError.httpError(statusCode: 429, data: nil)), .retryable)
        XCTAssertEqual(VerifyFailureClass.classify(APIError.httpError(statusCode: 503, data: nil)), .retryable)
        XCTAssertEqual(VerifyFailureClass.classify(APIError.networkError(URLError(.notConnectedToInternet))), .retryable)
    }

    private func verificationQueue(_ send: @escaping ReceiptVerifier.Send, hasClient: @escaping () -> Bool = { true }) -> PurchaseVerificationQueue {
        PurchaseVerificationQueue(environment: .init(
            defaults: defaults, now: Date.init,
            verifier: { hasClient() ? ReceiptVerifier(send: send) : nil }
        ))
    }

    private func entry(_ id: String) -> PendingVerification {
        PendingVerification(transactionId: id, productId: "m", signedTransaction: "jws-\(id)", productType: "subs",
                            appUserId: "u1", queuedAt: Int64(Date().timeIntervalSince1970 * 1000))
    }

    private static let okReply = Data(#"{"data":{"entitled":true,"product_id":"m","store":"app_store","status":"active"}}"#.utf8)

    /// NEGATIVE CONTROL: `ReceiptVerifier` was never constructed — no `/billing/verify` call at all.
    func testVerificationSendsTheSignedTransactionAndClearsOnSuccess() async {
        var bodies: [[String: Any]] = []
        let queue = verificationQueue { endpoint in
            if case .verifyReceipt(let body) = endpoint { bodies.append(body) }
            return Self.okReply
        }
        await queue.submit(entry("10"))
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?["transaction"] as? String, "jws-10")
        XCTAssertEqual(bodies.first?["platform"] as? String, "ios")
        XCTAssertEqual(bodies.first?["app_user_id"] as? String, "u1", "the purchaser captured at queue time")
        let pending = await queue.pendingIds()
        XCTAssertEqual(pending, [])
    }

    func testRetryableFailureIsKeptAndRetriedTerminalIsDropped() async {
        var status = 503
        let queue = verificationQueue { _ in
            if status == 200 { return Self.okReply }
            throw APIError.httpError(statusCode: status, data: nil)
        }
        await queue.submit(entry("20"))
        var pending = await queue.pendingIds()
        XCTAssertEqual(pending, ["20"], "a 503 is retried later, never lost")
        status = 200
        await queue.retryPending()
        pending = await queue.pendingIds()
        XCTAssertEqual(pending, [], "the retry verified it")

        status = 422
        await queue.submit(entry("21"))
        pending = await queue.pendingIds()
        XCTAssertEqual(pending, [], "a terminal refusal (e.g. store_credentials_missing) is dropped")
    }

    func testVerificationWaitsForTheClientAndSurvivesARestart() async {
        var client = false
        var sent = 0
        let queue = verificationQueue({ _ in sent += 1; return Self.okReply }, hasClient: { client })
        await queue.submit(entry("30"))
        XCTAssertEqual(sent, 0, "no client yet — nothing sent")
        // A new queue over the same defaults = the next launch.
        client = true
        let relaunched = verificationQueue({ _ in sent += 1; return Self.okReply }, hasClient: { client })
        await relaunched.retryPending()
        XCTAssertEqual(sent, 1, "persisted before the first attempt, sent after the restart")
    }

    // MARK: - 6. Purchase path

    /// Round-14 follow-up — NEGATIVE CONTROL: the direct `purchase()` tracked
    /// `purchase_started` + `purchase_failed{error_type: unknown}` for a cancelled Task.
    func testDirectPurchaseCancellationIsRethrownUntracked() async {
        let bridge = FakeBridge(); bridge.purchaseError = CancellationError()
        let module = AppDNA.BillingModule()
        module.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        do {
            _ = try await module.purchase("p")
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "rethrown as-is, got \(error)")
        }
        XCTAssertEqual(events.map(\.event_name), ["purchase_started"], "no terminal event for a cancelled Task")
    }

    /// NEGATIVE CONTROL: `TransactionInfo.environment` was hard-coded "production".
    func testDirectPurchaseReportsTheBridgeEnvironment() async throws {
        let bridge = FakeBridge()
        bridge.result = PurchaseResult(productId: "p", transactionId: "9", price: 1, currency: "USD", provider: "storekit2",
                                       isSubscription: false, isConsumable: false, environment: "sandbox")
        let module = AppDNA.BillingModule()
        module.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        module.entitlementSources.defaults = defaults
        let info = try await module.purchase("p")
        XCTAssertEqual(info.environment, "sandbox")
    }

    func testEnvironmentNames() {
        XCTAssertEqual(StoreKitEnvironment.name(rawValue: "Production"), "production")
        XCTAssertEqual(StoreKitEnvironment.name(rawValue: "Sandbox"), "sandbox")
        XCTAssertEqual(StoreKitEnvironment.name(rawValue: "Xcode"), "xcode")
        XCTAssertEqual(StoreKitEnvironment.name(rawValue: ""), "production")
    }

    /// 11c — NEGATIVE CONTROL: a THROWN `Product.products(for:)` left the purchase without `onPurchaseFailed`.
    func testThrownProductLookupFiresOnPurchaseFailed() async {
        let spy = Spy()
        let previous = AppDNA.billing.currentDelegate
        AppDNA.billing.setDelegate(spy, deliversPurchases: false)
        defer { AppDNA.billing.setDelegate(previous, deliversPurchases: false) }
        let bridge = StoreKit2Bridge(loadProducts: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await bridge.purchase(productId: "p1", appAccountToken: nil)
            XCTFail("must throw")
        } catch {}
        XCTAssertEqual(spy.failed, ["p1"])
    }

    /// §17-2 — NEGATIVE CONTROL: `AdaptyBridge.purchase` tracked its own `purchase_started` (and the caller
    /// another), so an Adapty purchase reported it twice.
    func testAdaptyBridgeEmitsNothingItself() async {
        let bridge = AdaptyBridge(apiKey: "k", eventTracker: tracker)
        do {
            _ = try await bridge.purchase(productId: "p", appAccountToken: nil)
            XCTFail("the SDK does not buy through Adapty")
        } catch {
            XCTAssertEqual(billingErrorType(error), "providerNotAvailable")
        }
        XCTAssertTrue(events.isEmpty, "a bridge emits nothing — got \(events.map(\.event_name))")
    }

    // MARK: - 7. The delivery-queue ledger

    /// NEGATIVE CONTROL: the unreadable payload was decoded with `try?` as an empty store and the next
    /// write replaced it — no log, no copy (`.corrupt` stayed nil).
    func testUndecodableDeliveryStoreIsKeptAsACorruptCopy() async {
        let garbage = Data("{not json".utf8)
        defaults.set(garbage, forKey: PurchaseDeliveryQueue.storageKey)
        let queue = PurchaseDeliveryQueue(environment: .init(
            defaults: defaults, now: Date.init, currentToken: { nil }, firstIdentifiedToken: { nil },
            deliveringDelegate: { nil }, tracker: { nil }
        ))
        await queue.markReported("1")
        let copies = CorruptStore.copyKeys(for: PurchaseDeliveryQueue.storageKey, defaults: defaults)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first.flatMap { defaults.data(forKey: $0) }, garbage, "the unreadable payload is preserved")
        let reported = await queue.isReported("1")
        XCTAssertTrue(reported, "the queue carries on with a fresh store")
    }

    /// A queued purchase carries its environment to the delegate.
    func testQueuedPurchaseDeliversItsEnvironment() async {
        final class PurchaseSpy: AppDNABillingDelegate {
            var infos: [TransactionInfo] = []
            func onPurchaseCompleted(productId: String, transaction: TransactionInfo) { infos.append(transaction) }
        }
        let spy = PurchaseSpy()
        let queue = PurchaseDeliveryQueue(environment: .init(
            defaults: defaults, now: Date.init, currentToken: { nil }, firstIdentifiedToken: { nil },
            deliveringDelegate: { spy }, tracker: { nil }
        ))
        await queue.activate()
        await queue.recordReport(PendingDelivery(transactionId: "7", productId: "p", purchaseTime: 0, ownerToken: nil,
                                                 emitPending: false, properties: nil, isSubscription: false, environment: "sandbox"))
        await queue.drain()
        let env = await MainActor.run { spy.infos.first?.environment }
        XCTAssertEqual(env, "sandbox")
    }

    // MARK: - Round 18

    /// NEGATIVE CONTROL: one `<key>.corrupt` slot, so a second unreadable payload overwrote the first.
    func testCorruptCopiesAreTimestampedAndCappedAtThree() {
        let key = "ai.appdna.test.store"
        struct Bad: Error {}
        for i in 0..<5 {
            CorruptStore.preserve(Data("bad-\(i)".utf8), key: key, defaults: defaults, error: Bad(),
                                  now: Date(timeIntervalSince1970: 1_000 + Double(i)))
        }
        // The same payload again is not a new copy.
        CorruptStore.preserve(Data("bad-4".utf8), key: key, defaults: defaults, error: Bad(), now: Date(timeIntervalSince1970: 2_000))
        let copies = CorruptStore.copyKeys(for: key, defaults: defaults)
        XCTAssertEqual(copies, ["\(key).corrupt.1002000", "\(key).corrupt.1003000", "\(key).corrupt.1004000"])
        XCTAssertEqual(copies.map { String(decoding: defaults.data(forKey: $0) ?? Data(), as: UTF8.self) }, ["bad-2", "bad-3", "bad-4"])
        XCTAssertNil(defaults.data(forKey: "\(key).corrupt.1000000"), "the oldest copies are pruned")
    }

    /// RevenueCat's async purchase THROWS `ErrorCode.purchaseCancelledError` (NSError, domain
    /// "RevenueCat.ErrorCode", code 1) on a cancel. NEGATIVE CONTROL: it was rethrown raw, typed `unknown`,
    /// and the direct purchase tracked `purchase_failed` instead of `purchase_canceled`.
    func testRevenueCatCancelIsAUserCancel() async {
        let rcCancel = NSError(domain: "RevenueCat.ErrorCode", code: 1)
        XCTAssertEqual(billingErrorType(rcCancel), "userCancelled")
        XCTAssertEqual(billingErrorType(NSError(domain: "RevenueCat.ErrorCode", code: 2)), "unknown", "another RevenueCat error is not a cancel")
        let mapped = RevenueCatErrors.purchaseFailure(rcCancel)
        guard case BillingError.userCancelled? = mapped as? BillingError else { return XCTFail("mapped to \(mapped)") }

        let bridge = FakeBridge(); bridge.purchaseError = mapped
        let module = AppDNA.BillingModule()
        module.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        do { _ = try await module.purchase("p"); XCTFail("must throw") } catch {}
        XCTAssertEqual(events.map(\.event_name), ["purchase_started", "purchase_canceled"])
    }

    /// NEGATIVE CONTROL: a Task cancellation during the product lookup fired `onPurchaseFailed`.
    func testTaskCancellationDuringLookupIsNotAFailedPurchase() async {
        let spy = Spy()
        let previous = AppDNA.billing.currentDelegate
        AppDNA.billing.setDelegate(spy, deliversPurchases: false)
        defer { AppDNA.billing.setDelegate(previous, deliversPurchases: false) }
        let bridge = StoreKit2Bridge(loadProducts: { _ in throw CancellationError() })
        do {
            _ = try await bridge.purchase(productId: "p1", appAccountToken: nil)
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await settle()
        XCTAssertEqual(spy.failed, [])
    }

    /// NEGATIVE CONTROL: `expirations(for:)` read every user's transactions, so another user's later expiry
    /// of the same product became this user's `expiresAt`.
    func testExpirationsApplyTheOwnerFilter() {
        let me = UUID(), other = UUID()
        let d1 = Date(timeIntervalSince1970: 1_000), d2 = Date(timeIntervalSince1970: 2_000)
        let facts = [
            StoreKitEntitlementReader.ExpiryFact(productId: "m", appAccountToken: me, revoked: false, expirationDate: d1),
            StoreKitEntitlementReader.ExpiryFact(productId: "m", appAccountToken: other, revoked: false, expirationDate: d2),
            StoreKitEntitlementReader.ExpiryFact(productId: "u", appAccountToken: nil, revoked: false, expirationDate: d2),
        ]
        XCTAssertEqual(StoreKitEntitlementReader.expirations(of: facts, for: ["m", "u"], appAccountToken: me, firstIdentifiedToken: other),
                       ["m": d1], "another user's transaction and an untagged one (not the first identifier) are skipped")
        XCTAssertEqual(StoreKitEntitlementReader.expirations(of: facts, for: ["m", "u"], appAccountToken: me, firstIdentifiedToken: me),
                       ["m": d1, "u": d2], "the first identifier inherits untagged history")
        XCTAssertEqual(StoreKitEntitlementReader.expirations(of: facts, for: ["m"], appAccountToken: nil, firstIdentifiedToken: nil),
                       ["m": d2], "anonymous: every transaction (the anonymous policy)")
    }

    /// The fingerprint is persisted, so the server-only rows must be too. NEGATIVE CONTROL: the server-only
    /// cache lived in memory only, so an OFFLINE relaunch dropped the cross-platform purchase and fired
    /// `onEntitlementsChanged` without it.
    func testOfflineRelaunchKeepsServerOnlyEntitlements() async {
        let bridge = FakeBridge(); let world = World()
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = [ServerEntitlement(productId: "cross", store: "google_play", status: "active",
                                          expiresAt: nil, isTrial: false, offerType: nil)]
        let firstLaunch = Spy()
        let module1 = makeModule(bridge, world, spy: firstLaunch)
        await module1.refreshEntitlementCache()
        let ok = await waitUntil { firstLaunch.changes.count == 1 }
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(firstLaunch.changes[0].map(\.productId)), ["monthly", "cross"])
        module1.setDelegate(nil)

        world.server = nil                              // offline
        let relaunch = Spy()
        let module2 = makeModule(bridge, world, spy: relaunch)
        await module2.refreshEntitlementCache()
        await settle()
        XCTAssertEqual(relaunch.changes.count, 0, "offline after a relaunch is not a change")

        world.userId = "user-2"                         // another user never inherits them
        await module2.refreshEntitlementCache()
        let ok2 = await waitUntil { relaunch.changes.count == 1 }
        XCTAssertTrue(ok2)
        XCTAssertEqual(relaunch.changes.last?.map(\.productId), ["monthly"])
    }

    // MARK: - Round 19

    /// NEGATIVE CONTROL: `reset()` (sign-out) left the signed-out user's server-only rows persisted.
    func testResetClearsTheServerOnlyEntitlementCache() async {
        let saved = AppDNA.billing.entitlementSources
        // `AppDNA.reset()` also clears process-wide state other tests read: put it back.
        let globals = GlobalSignOutState.save()
        defer { globals.restore() }
        AppDNA.billing.entitlementSources.defaults = defaults
        defer { AppDNA.billing.entitlementSources = saved }
        ServerOnlyEntitlementCache.save(userId: "user-1", items: [ServerEntitlement(
            productId: "cross", store: "google_play", status: "active", expiresAt: nil, isTrial: false, offerType: nil)], defaults)
        XCTAssertNotNil(ServerOnlyEntitlementCache.load(defaults))
        AppDNA.reset()
        await Self.drainSDKQueue()
        XCTAssertNil(ServerOnlyEntitlementCache.load(defaults), "the signed-out user's server-only rows outlived reset()")
    }

    /// NEGATIVE CONTROL: the in-memory copy survived the clear, so the same user signing back in while
    /// offline still got the signed-out session's cross-platform rows.
    func testClearedServerOnlyCacheIsNotReusedOffline() async {
        let bridge = FakeBridge(); let world = World()
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = [ServerEntitlement(productId: "cross", store: "google_play", status: "active",
                                          expiresAt: nil, isTrial: false, offerType: nil)]
        let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)
        await module.refreshEntitlementCache()
        let ok = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok)

        module.clearServerOnlyEntitlementCache()
        world.server = nil // offline
        await module.refreshEntitlementCache()
        let ok2 = await waitUntil { spy.changes.count == 2 }
        XCTAssertTrue(ok2)
        XCTAssertEqual(spy.changes.last?.map(\.productId), ["monthly"])
    }

    /// A one-shot gate a test opens by hand: `wait()` suspends until `open()`.
    final class AwaitGate {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var _entered = 0
        var entered: Int { lock.lock(); defer { lock.unlock() }; return _entered }
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); _entered += 1
                if opened { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
            }
        }
        func open() {
            lock.lock(); opened = true; let w = waiters; waiters = []; lock.unlock()
            w.forEach { $0.resume() }
        }
    }

    /// A module whose server read suspends on `gate` until the test opens it, then answers `world.server`.
    private func makeGatedModule(_ bridge: FakeBridge, _ world: World, spy: Spy, gate: AwaitGate) -> AppDNA.BillingModule {
        let module = makeModule(bridge, world, spy: spy)
        module.entitlementSources.server = { _ in world.serverCalls += 1; await gate.wait(); return world.server }
        return module
    }

    private let crossRow = ServerEntitlement(productId: "cross", store: "google_play", status: "active",
                                             expiresAt: nil, isTrial: false, offerType: nil)

    /// Round 20 — a refresh in flight across a sign-out. NEGATIVE CONTROL: the pass read the server for user-1,
    /// `reset()` cleared user-1's server-only rows while it was suspended, and when the answer arrived the pass
    /// saved them again — the signed-out user's cross-platform purchase back on the device, and reported.
    func testARefreshInFlightAcrossResetDoesNotReSaveTheSignedOutUsersRows() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = [crossRow]
        let spy = Spy()
        let module = makeGatedModule(bridge, world, spy: spy, gate: gate)
        let refresh = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended, "the refresh never reached the server read")

        // `AppDNA.reset()`: the identity goes anonymous, the billing module clears the server-only rows.
        world.userId = nil
        module.clearServerOnlyEntitlementCache()
        gate.open()
        await refresh.value
        await settle()

        XCTAssertNil(ServerOnlyEntitlementCache.load(defaults), "the in-flight refresh re-saved the signed-out user's rows")
        XCTAssertFalse(spy.changes.flatMap { $0 }.contains { $0.productId == "cross" },
                       "the signed-out user's server-only row was reported after reset()")
        // Nothing in memory either: the same user back, offline, does not get them.
        world.userId = "user-1"; world.server = nil
        await module.refreshEntitlementCache()
        await settle()
        XCTAssertFalse(spy.changes.flatMap { $0 }.contains { $0.productId == "cross" })
    }

    /// The same, when the user signs straight back in while the old pass is suspended: the user id matches
    /// again, but a sign-out happened in between, so the old pass's answer is still dropped (the new user
    /// session's own refresh reads the server afresh).
    func testARefreshOvertakenByResetAndSameUserSignInDoesNotSave() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        world.server = [crossRow]
        let module = makeGatedModule(bridge, world, spy: Spy(), gate: gate)
        let refresh = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended)
        module.clearServerOnlyEntitlementCache() // reset(); then identify("user-1") again
        gate.open()
        await refresh.value
        XCTAssertNil(ServerOnlyEntitlementCache.load(defaults))
    }

    /// A user switch with no reset (identify user-2 while user-1's read is in flight) does not save user-1's
    /// rows as the current cache either.
    func testARefreshWhoseUserChangedDoesNotSave() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        world.server = [crossRow]
        let module = makeGatedModule(bridge, world, spy: Spy(), gate: gate)
        let refresh = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended)
        world.userId = "user-2"
        gate.open()
        await refresh.value
        XCTAssertNil(ServerOnlyEntitlementCache.load(defaults))
    }

    /// Control: with no sign-out and the same user, the gated pass saves the server-only rows as before.
    func testAnUninterruptedGatedRefreshStillSaves() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        world.server = [crossRow]
        let spy = Spy()
        let module = makeGatedModule(bridge, world, spy: spy, gate: gate)
        let refresh = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended)
        gate.open()
        await refresh.value
        XCTAssertEqual(ServerOnlyEntitlementCache.load(defaults)?.userId, "user-1")
        XCTAssertEqual(ServerOnlyEntitlementCache.load(defaults)?.items.map(\.productId), ["cross"])
        let reported = await waitUntil { spy.changes.last?.contains { $0.productId == "cross" } == true }
        XCTAssertTrue(reported)
    }

    /// Round 21 (I4+I5 m1) — sign-out and sign-in again while a refresh is in flight. NEGATIVE CONTROL: the
    /// overtaken pass still swapped the fingerprint and posted what it had read (the device set, without the
    /// server rows its stale answer lost), then the sign-in's own refresh posted the full set — two changes,
    /// the first one wrong. Now the overtaken pass publishes nothing and the sign-in's refresh reports once.
    func testResetAndReIdentifyDuringARefreshFiresExactlyOneChange() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = [crossRow]
        let spy = Spy()
        let module = makeGatedModule(bridge, world, spy: spy, gate: gate)
        let stale = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended, "the refresh never reached the server read")

        // `AppDNA.reset()`, then `AppDNA.identify("user-1")`, which queues its own refresh behind the stale one.
        world.userId = nil
        module.clearServerOnlyEntitlementCache()
        world.userId = "user-1"
        let signIn = Task { await module.refreshEntitlementCache() }
        gate.open()
        await stale.value
        await signIn.value
        await settle()

        XCTAssertEqual(spy.changes.count, 1, "reset + re-identify must report one change, not the stale pass's too")
        XCTAssertEqual(Set(spy.changes.first?.map(\.productId) ?? []), ["monthly", "cross"],
                       "the one change is the signed-in user's full state")
        XCTAssertEqual(ServerOnlyEntitlementCache.load(defaults)?.items.map(\.productId), ["cross"])
    }

    /// Round 21 (I4+I5 m1/m2) — a pass a sign-out overtook publishes nothing: no change, no persisted
    /// fingerprint, no expiry re-check. NEGATIVE CONTROL: it posted the signed-out user's StoreKit set (read
    /// under their `appAccountToken`), saved it as the last-known state and scheduled a re-check for its expiry.
    func testAStalePassPublishesNothing() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = []
        // An expiry 0.2 s ahead of the pass's clock: a scheduled re-check would read again within ~0.2 s.
        world.expirations = ["monthly": world.now.addingTimeInterval(0.2)]
        let spy = Spy()
        let module = makeGatedModule(bridge, world, spy: spy, gate: gate)
        module.expiryRecheckLeeway = 0
        let refresh = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended, "the refresh never reached the server read")

        world.userId = nil                         // `AppDNA.reset()`
        module.clearServerOnlyEntitlementCache()
        gate.open()
        await refresh.value
        try? await Task.sleep(nanoseconds: 700_000_000)  // past the expiry a re-check would have been set for
        await settle()

        XCTAssertEqual(spy.changes.count, 0, "the signed-out user's entitlements were published after reset()")
        XCTAssertNil(defaults.stringArray(forKey: EntitlementFingerprint.storageKey), "the stale pass recorded its answer as the last-known state")
        XCTAssertEqual(bridge.reads, 1, "the stale pass scheduled an expiry re-check")

        // Control: the next (fresh) pass reports the anonymous state against the untouched baseline.
        await module.refreshEntitlementCache()
        let reported = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(reported, "a fresh pass after the stale one must still report")
    }

    /// A switch to another user with no sign-out (identify user-2 while user-1's pass is in flight) makes the
    /// pass stale too — user-1's state is never published, and user-2's refresh reports once.
    ///
    /// Round 22 (m1): the device set depends on the user, as StoreKit's does through the `appAccountToken`
    /// filter — user-1 holds `[monthly, legacy]`, user-2 `[monthly]`. Before, both passes read the same
    /// `[monthly]`, so the stale pass posting its answer was indistinguishable from user-2's and the test
    /// passed without the user check. NEGATIVE CONTROL: with `passUserId == currentUserId` removed from
    /// `commitRefresh`, the stale pass posts user-1's `[monthly, legacy]` first — two changes.
    func testAUserSwitchDuringARefreshFiresOnlyTheNewUsersChange() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        bridge.idsAtRead = { world.userId == "user-2" ? ["monthly"] : ["monthly", "legacy"] }
        world.server = [crossRow]
        let spy = Spy()
        let module = makeGatedModule(bridge, world, spy: spy, gate: gate)
        let stale = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended)
        world.userId = "user-2"
        world.server = []
        let signIn = Task { await module.refreshEntitlementCache() }
        gate.open()
        await stale.value
        await signIn.value
        await settle()
        XCTAssertEqual(bridge.reads, 2, "the stale pass read user-1's set before the switch, user-2's pass its own")
        XCTAssertEqual(spy.changes.count, 1, "only user-2's state is reported, not the stale pass's user-1 set too")
        XCTAssertEqual(spy.changes.first?.map(\.productId), ["monthly"],
                       "user-2's state, without user-1's legacy product or server row")
    }

    // MARK: - Round 22 — sign-out reports the signed-out state

    /// Round 22 (M1) — a sign-out with no sign-in after it. NEGATIVE CONTROL: `reset()` only cleared the
    /// server-only rows and queued no refresh, so the host was never told the signed-out user's
    /// cross-platform purchase was gone (Android fires `[]` from `EntitlementCache.clear()`). Now one change,
    /// with the anonymous state: on iOS the device's StoreKit set, without the server-only row.
    func testSignOutWithNoSignInFiresExactlyOneChangeWithoutTheServerRow() async {
        let bridge = FakeBridge(); let world = World()
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = [crossRow]
        let spy = Spy()
        let module = makeModule(bridge, world, spy: spy)
        await module.refreshEntitlementCache()
        let signedIn = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(signedIn)
        XCTAssertEqual(Set(spy.changes[0].map(\.productId)), ["monthly", "cross"])

        world.userId = nil                         // `AppDNA.reset()`: the identity goes anonymous …
        module.signOut()                           // … and billing signs out. No refresh is called here.
        let reported = await waitUntil { spy.changes.count == 2 }
        XCTAssertTrue(reported, "the sign-out reported no entitlement change")
        await settle()
        XCTAssertEqual(spy.changes.count, 2, "exactly one change for the sign-out")
        XCTAssertEqual(spy.changes.last?.map(\.productId), ["monthly"],
                       "the anonymous state is the device's StoreKit set, without the signed-out user's server row")
        XCTAssertNil(ServerOnlyEntitlementCache.load(defaults))
    }

    /// Round 22 (M1) — the sign-out refresh does not add a second change when the user signs straight back
    /// in while an earlier pass is in flight (the round-21 case, now with the refresh `signOut()` queues).
    func testSignOutRefreshAndReIdentifyDuringARefreshStillFireExactlyOneChange() async {
        let bridge = FakeBridge(); let world = World(); let gate = AwaitGate()
        world.userId = "user-1"
        bridge.ids = ["monthly"]
        world.server = [crossRow]
        let spy = Spy()
        let module = makeGatedModule(bridge, world, spy: spy, gate: gate)
        let stale = Task { await module.refreshEntitlementCache() }
        let suspended = await waitUntil { gate.entered == 1 }
        XCTAssertTrue(suspended, "the refresh never reached the server read")

        world.userId = nil
        module.signOut()                           // `AppDNA.reset()`: queues the sign-out refresh
        world.userId = "user-1"
        let signIn = Task { await module.refreshEntitlementCache() }   // `identify("user-1")`
        gate.open()
        await stale.value
        await signIn.value
        await settle()

        XCTAssertEqual(spy.changes.count, 1, "reset + re-identify must report one change")
        XCTAssertEqual(Set(spy.changes.first?.map(\.productId) ?? []), ["monthly", "cross"],
                       "the one change is the signed-in user's full state")
    }

    /// Round 22 (M1) — the same through the public `AppDNA.reset()`, on the process-wide `AppDNA.billing`.
    /// NEGATIVE CONTROL: as above — `reset()` posted nothing.
    ///
    /// It borrows process-wide state and leaves it as it found it: the billing module's wiring, sources,
    /// delegate AND that delegate's `deliversPurchases` flag, its last-known fingerprint, and — because
    /// `AppDNA.reset()` clears them — `SessionDataStore.shared` and the persisted subscription snapshot.
    func testAppDNAResetReportsTheSignedOutState() async {
        let billing = AppDNA.billing
        let prior = (configured: billing.configured, bridge: billing.bridge, policy: billing.ownershipPolicy,
                     tracker: billing.eventTracker, sources: billing.entitlementSources, delegate: billing.currentDelegate,
                     delivers: billing.currentDelegateDelivers, fingerprint: billing.lastKnownFingerprintForTesting,
                     deadline: billing.serverReadDeadline)
        let globals = GlobalSignOutState.save()
        defer { globals.restore() }
        billing.serverReadDeadline = 60    // not under test; see `makeModule`
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        // Unique ids: the process-wide module keeps its last-known state from earlier tests.
        let device = "r22-\(UUID().uuidString)", cross = "r22-cross-\(UUID().uuidString)"
        bridge.ids = [device]
        world.userId = "user-1"
        world.server = [ServerEntitlement(productId: cross, store: "google_play", status: "active",
                                          expiresAt: nil, isTrial: false, offerType: nil)]
        billing.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        billing.entitlementSources = EntitlementSources(
            server: { _ in world.server }, localExpirations: { _, _ in [:] },
            currentUserId: { world.userId }, defaults: defaults, now: { world.now })
        billing.setDelegate(spy, deliversPurchases: false)
        await billing.refreshEntitlementCache()
        let signedIn = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(signedIn)

        world.userId = nil
        AppDNA.reset()
        // Wait on what the report depends on, not on a clock (round 28): `reset()` runs on the SDK queue and
        // appends the sign-out pass to the serial refresh chain; a refresh appended after it returns once that
        // pass has run. In CI order an earlier test's pass can still hold the chain on a server read — each pass
        // now waits at most `serverReadDeadline` for it, where it used to wait out the 30 s timeout and retries,
        // and this test's 10 s wait gave up first.
        await Self.drainSDKQueue()
        await billing.refreshEntitlementCache()
        await settle()
        XCTAssertGreaterThanOrEqual(spy.changes.count, 2, "AppDNA.reset() reported no entitlement change")
        XCTAssertEqual(spy.changes.count, 2, "exactly one change for the sign-out")
        XCTAssertEqual(spy.changes.last?.map(\.productId), [device], "without the signed-out user's server row")

        await billing.refreshEntitlementCache()    // drain the chain before restoring
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

    /// What `AppDNA.reset()` clears beyond billing, saved and put back byte for byte: the three
    /// `SessionDataStore` buckets (in memory and persisted) and the persisted subscription snapshot.
    struct GlobalSignOutState {
        static let sessionKeys = ["appdna.session.onboarding_responses", "appdna.session.computed_data",
                                  "appdna.session.session_data"]
        let onboarding: [String: [String: Any]]
        let computed: [String: Any]
        let session: [String: Any]
        let persisted: [String: Any?]

        static func save() -> GlobalSignOutState {
            let store = SessionDataStore.shared
            var persisted: [String: Any?] = [:]
            for key in sessionKeys + [SubscriptionStatusObserver.snapshotKey] {
                persisted.updateValue(UserDefaults.standard.object(forKey: key), forKey: key)   // nil kept as "absent"
            }
            return GlobalSignOutState(onboarding: store.onboardingResponses, computed: store.computedData,
                                      session: store.sessionData, persisted: persisted)
        }

        func restore() {
            let store = SessionDataStore.shared
            store.clearAll()
            if !onboarding.isEmpty { store.setOnboardingResponses(onboarding) }
            if !computed.isEmpty { store.mergeComputedData(computed) }
            for (key, value) in session { store.setSessionData(key: key, value: value) }
            for (key, value) in persisted {     // the exact stored bytes, whatever the setters wrote
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    /// The borrowed-state guard above works. NEGATIVE CONTROL: without `GlobalSignOutState.restore()` the
    /// session value and the snapshot written here are gone after `AppDNA.reset()`.
    func testGlobalSignOutStateRestoresWhatResetClears() async {
        let key = "r24-probe-\(UUID().uuidString)"
        let saved = GlobalSignOutState.save()
        SessionDataStore.shared.setSessionData(key: key, value: "kept")
        let snapshot = Data("r24".utf8)
        UserDefaults.standard.set(snapshot, forKey: SubscriptionStatusObserver.snapshotKey)
        let probe = GlobalSignOutState.save()

        AppDNA.reset()
        // `reset()` is one block on the SDK's serial queue: wait for that block, not for a clock.
        await Self.drainSDKQueue()
        XCTAssertNil(SessionDataStore.shared.getSessionData(key: key), "precondition: reset() clears session data")
        XCTAssertNil(UserDefaults.standard.data(forKey: SubscriptionStatusObserver.snapshotKey),
                     "precondition: reset() clears the subscription snapshot")
        probe.restore()

        XCTAssertEqual(SessionDataStore.shared.getSessionData(key: key) as? String, "kept")
        XCTAssertEqual(UserDefaults.standard.data(forKey: SubscriptionStatusObserver.snapshotKey), snapshot)
        saved.restore()
        XCTAssertNil(SessionDataStore.shared.getSessionData(key: key))
    }

    // MARK: - Sign-out refresh: only when the SDK reads StoreKit itself

    /// Under RevenueCat or Adapty LINKED into the build a sign-out queues no refresh: the provider's entitlements are for the
    /// provider's current user, which `reset()` does not change. NEGATIVE CONTROL: `signOut()` queued the
    /// refresh under every provider, so `bridge.reads` went 1 → 2 and the provider's (signed-out) user's set
    /// was reported as the signed-out state.
    func testSignOutQueuesNoRefreshUnderAProvider() async {
        for provider in [BillingProvider.revenueCat, .adapty(apiKey: "k")] {
            defaults.removePersistentDomain(forName: suite)   // each provider starts from no last-known state
            let bridge = FakeBridge(); let world = World(); let spy = Spy()
            world.userId = "user-1"
            bridge.ids = ["rc_monthly"]
            let module = makeModule(bridge, world, spy: spy, provider: provider)
            await module.refreshEntitlementCache()
            XCTAssertEqual(bridge.reads, 1)

            world.userId = nil
            module.signOut()
            await settle()
            await settle()
            XCTAssertEqual(bridge.reads, 1, "\(provider): sign-out must not read the provider's current user")
            XCTAssertEqual(spy.changes.count, 1, "\(provider): nothing reported for the sign-out by the SDK")
            XCTAssertNil(ServerOnlyEntitlementCache.load(defaults), "\(provider): the server-only rows are still forgotten")
        }
    }

    /// Under StoreKit 2 the sign-out still refreshes (the round-22 behaviour, kept).
    func testSignOutStillRefreshesUnderStoreKit2() async {
        let bridge = FakeBridge(); let world = World(); let spy = Spy()
        bridge.ids = ["monthly"]
        let module = makeModule(bridge, world, spy: spy, provider: .storeKit2)
        await module.refreshEntitlementCache()
        module.signOut()
        let read = await waitUntil { bridge.reads == 2 }
        XCTAssertTrue(read, "storeKit2: the sign-out queues one refresh")
    }

    func testSignOutRefreshesOnlyWhenTheSDKReadsStoreKit() {
        XCTAssertTrue(AppDNA.BillingModule.signOutRefreshes(
            hasProvider: true, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true)))
        XCTAssertFalse(AppDNA.BillingModule.signOutRefreshes(
            hasProvider: false, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true)))
        XCTAssertFalse(AppDNA.BillingModule.signOutRefreshes(
            hasProvider: true, policy: BillingOwnership.policy(for: .revenueCat, bridgeLinked: true)))
        XCTAssertFalse(AppDNA.BillingModule.signOutRefreshes(
            hasProvider: true, policy: BillingOwnership.policy(for: .adapty(apiKey: "k"), bridgeLinked: true)))
        // Published builds: the provider SDK is not linked, `ExternalProviderBridge` reads StoreKit.
        XCTAssertTrue(AppDNA.BillingModule.signOutRefreshes(
            hasProvider: true, policy: BillingOwnership.policy(for: .revenueCat, bridgeLinked: false)))
        XCTAssertTrue(AppDNA.BillingModule.signOutRefreshes(
            hasProvider: true, policy: BillingOwnership.policy(for: .adapty(apiKey: "k"), bridgeLinked: false)))
        XCTAssertFalse(AppDNA.BillingModule.signOutRefreshes(
            hasProvider: false, policy: BillingOwnership.unavailable))
    }

    /// Under RevenueCat or Adapty NOT linked into the build — every published channel, where
    /// `ExternalProviderBridge` reads the device's StoreKit set — the sign-out refreshes like StoreKit 2 and
    /// reports exactly one change: the anonymous state, without the signed-out user's server-only row.
    /// NEGATIVE CONTROL: `signOutRefreshes` keyed on the REQUESTED provider, so no refresh was queued,
    /// `bridge.reads` stayed 1 and nothing reported the sign-out until the next foreground or purchase.
    func testSignOutRefreshesUnderAnUnlinkedProvider() async {
        for provider in [BillingProvider.revenueCat, .adapty(apiKey: "k")] {
            defaults.removePersistentDomain(forName: suite)   // each provider starts from no last-known state
            let bridge = FakeBridge(); let world = World(); let spy = Spy()
            world.userId = "user-1"
            bridge.ids = ["monthly"]
            world.server = [crossRow]
            let module = makeModule(bridge, world, spy: spy, provider: provider, bridgeLinked: false)
            await module.refreshEntitlementCache()
            let signedIn = await waitUntil { spy.changes.count == 1 }
            XCTAssertTrue(signedIn, "\(provider)")
            XCTAssertEqual(bridge.reads, 1)

            world.userId = nil
            module.signOut()
            let reported = await waitUntil { spy.changes.count == 2 }
            XCTAssertTrue(reported, "\(provider): the sign-out reported no entitlement change")
            await settle()
            await settle()
            XCTAssertEqual(bridge.reads, 2, "\(provider): the sign-out queues exactly one refresh")
            XCTAssertEqual(spy.changes.count, 2, "\(provider): exactly one change for the sign-out")
            XCTAssertEqual(spy.changes.last?.map(\.productId), ["monthly"],
                           "\(provider): the device's StoreKit set, without the signed-out user's server row")
            XCTAssertNil(ServerOnlyEntitlementCache.load(defaults), "\(provider)")
        }
    }

    /// With no billing provider configured a sign-out queues nothing. NEGATIVE CONTROL: it queued a pass that
    /// logged "no billing provider configured" on every `reset()`.
    func testSignOutWithoutAProviderQueuesNothingAndLogsNothing() async {
        var logged: [String] = []
        let lock = NSLock()
        let savedLevel = Log.level
        Log.level = .warning
        Log.testSink = { line in lock.lock(); logged.append(line); lock.unlock() }
        defer { Log.testSink = nil; Log.level = savedLevel }

        let module = AppDNA.BillingModule()          // never wired: no bridge
        module.signOut()
        await settle()
        await settle()
        lock.lock(); let lines = logged; lock.unlock()
        XCTAssertFalse(lines.contains { $0.contains("no billing provider configured") },
                       "a sign-out without a billing provider must not queue a refresh: \(lines)")
    }

    /// RevenueCat / Adapty purchases do not carry the SDK's `appAccountToken`. NEGATIVE CONTROL: the owner
    /// filter ran on them too, so for any user but the first identifier every one was denied as
    /// "untagged, another user" and `expiresAt` was always nil.
    func testProviderProductExpiriesSkipTheOwnerFilter() {
        let me = UUID(), first = UUID()
        let d = Date(timeIntervalSince1970: 3_000)
        let facts = [StoreKitEntitlementReader.ExpiryFact(productId: "rc_monthly", appAccountToken: nil, revoked: false, expirationDate: d),
                     StoreKitEntitlementReader.ExpiryFact(productId: "rc_monthly", appAccountToken: nil, revoked: true,
                                                          expirationDate: d.addingTimeInterval(99))]
        XCTAssertEqual(StoreKitEntitlementReader.expirations(of: facts, for: ["rc_monthly"], appAccountToken: me, firstIdentifiedToken: first),
                       [:], "the StoreKit-owned path still filters")
        XCTAssertEqual(StoreKitEntitlementReader.expirations(of: facts, for: ["rc_monthly"], appAccountToken: me, firstIdentifiedToken: first,
                                                             applyOwnerFilter: false),
                       ["rc_monthly": d], "a revoked transaction still never lends its expiry")
    }

    /// The refresh and `getEntitlements` read expiries owner-filtered exactly when the product ids were: when
    /// the SDK reads StoreKit itself — `storeKit2`, or RevenueCat / Adapty NOT linked (`ExternalProviderBridge`,
    /// whose ids pass `EntitlementOwnerFilter`). Unfiltered only when a linked provider SDK answers.
    /// NEGATIVE CONTROL: the flag keyed on the REQUESTED provider (`provider == "storeKit2"`), so the unlinked
    /// RevenueCat / Adapty rows read `false` — ids filtered, expiries not.
    func testExpiryOwnerFilterFollowsTheBridgeThatReadsTheIds() async {
        let cases: [(BillingProvider, Bool, Bool)] = [
            (.storeKit2, true, true),
            (.revenueCat, true, false), (.adapty(apiKey: "k"), true, false),     // linked: the provider's answer
            (.revenueCat, false, true), (.adapty(apiKey: "k"), false, true),     // unlinked: StoreKit, filtered ids
        ]
        for (provider, linked, expected) in cases {
            let policy = BillingOwnership.policy(for: provider, bridgeLinked: linked)
            XCTAssertEqual(AppDNA.BillingModule.expiryOwnerFiltered(policy), policy.sdkReadsStoreKitEntitlements,
                           "\(provider) linked=\(linked)")
            let bridge = FakeBridge(); let world = World()
            bridge.ids = ["monthly"]
            let module = makeModule(bridge, world, spy: Spy(), provider: provider, bridgeLinked: linked)
            _ = await module.getEntitlements()
            await module.refreshEntitlementCache()
            XCTAssertEqual(world.ownerFiltered, [expected, expected], "\(provider) linked=\(linked)")
        }
        XCTAssertFalse(AppDNA.BillingModule.expiryOwnerFiltered(BillingOwnership.unavailable))
    }

    /// Under an unlinked provider (`ExternalProviderBridge`) the ids and the expiry agree on WHICH transaction
    /// is the current user's: two transactions of one product (the current user's, and another app user's with
    /// a later expiry — e.g. Family Sharing, or a second app account on the same Apple ID) give the product
    /// through the current user's transaction, so its expiry is that transaction's.
    /// NEGATIVE CONTROL: unfiltered, the other user's later expiry was lent to the current user.
    func testUnlinkedProviderExpiryComesFromTheTransactionThatGrantedTheId() {
        let me = UUID(), other = UUID()
        let mine = Date(timeIntervalSince1970: 10_000), theirs = Date(timeIntervalSince1970: 90_000)
        let facts = [
            StoreKitEntitlementReader.ExpiryFact(productId: "monthly", appAccountToken: me, revoked: false, expirationDate: mine),
            StoreKitEntitlementReader.ExpiryFact(productId: "monthly", appAccountToken: other, revoked: false, expirationDate: theirs),
        ]
        // The id filter grants only the current user's transaction …
        XCTAssertEqual(EntitlementOwnerFilter.decide(transactionToken: me, expectedToken: me, firstIdentifiedToken: other), .grant)
        XCTAssertEqual(EntitlementOwnerFilter.decide(transactionToken: other, expectedToken: me, firstIdentifiedToken: other), .denyOtherUser)
        for provider in [BillingProvider.revenueCat, .adapty(apiKey: "k")] {
            let policy = BillingOwnership.policy(for: provider, bridgeLinked: false)
            // … so the expiry is read from that transaction only.
            XCTAssertEqual(StoreKitEntitlementReader.expirations(
                of: facts, for: ["monthly"], appAccountToken: me, firstIdentifiedToken: other,
                applyOwnerFilter: AppDNA.BillingModule.expiryOwnerFiltered(policy)),
                ["monthly": mine], "\(provider) unlinked: another user's later expiry must not be lent")
        }
    }

    /// An older SDK kept ONE `<key>.corrupt` copy. NEGATIVE CONTROL: it was outside the index, so it was never
    /// listed and never pruned — a fourth copy beside the cap of three.
    func testLegacyCorruptCopyIsFoldedIntoTheIndexAndPruned() {
        let key = "ai.appdna.test.legacy"
        struct Bad: Error {}
        defaults.set(Data("legacy".utf8), forKey: "\(key).corrupt")
        XCTAssertEqual(CorruptStore.copyKeys(for: key, defaults: defaults), ["\(key).corrupt"], "listed before any new copy")

        CorruptStore.preserve(Data("bad-0".utf8), key: key, defaults: defaults, error: Bad(), now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(CorruptStore.copyKeys(for: key, defaults: defaults), ["\(key).corrupt", "\(key).corrupt.1000"])
        XCTAssertEqual(defaults.stringArray(forKey: CorruptStore.indexKey(for: key)), ["\(key).corrupt", "\(key).corrupt.1000"],
                       "the index itself now holds it")

        for i in 1..<3 {
            CorruptStore.preserve(Data("bad-\(i)".utf8), key: key, defaults: defaults, error: Bad(),
                                  now: Date(timeIntervalSince1970: 1 + Double(i)))
        }
        XCTAssertEqual(CorruptStore.copyKeys(for: key, defaults: defaults),
                       ["\(key).corrupt.1000", "\(key).corrupt.2000", "\(key).corrupt.3000"])
        XCTAssertNil(defaults.data(forKey: "\(key).corrupt"), "the legacy copy is pruned like any oldest copy")
    }
}
