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
        var purchaseError: Error?
        var result = PurchaseResult(productId: "p", transactionId: "1", price: 1, currency: "USD",
                                    provider: "storekit2", isSubscription: false, isConsumable: false)
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
            if let purchaseError { throw purchaseError }
            return result
        }
        func restore(appAccountToken: UUID?) async throws -> [String] { ids }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { ids }
    }

    /// Mutable inputs the injected entitlement sources read.
    final class World {
        var expirations: [String: Date] = [:]
        var server: [ServerEntitlement]? = nil
        var userId: String? = nil
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var serverCalls = 0
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

    private func makeModule(_ bridge: FakeBridge, _ world: World, spy: Spy) -> AppDNA.BillingModule {
        let module = AppDNA.BillingModule()
        module.wire(bridge: bridge, policy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true), tracker: tracker)
        module.entitlementSources = EntitlementSources(
            server: { _ in world.serverCalls += 1; return world.server },
            localExpirations: { ids in world.expirations.filter { ids.contains($0.key) } },
            currentUserId: { world.userId },
            defaults: defaults,
            now: { world.now }
        )
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
        bridge.ids = ["weekly"]
        world.expirations = ["weekly": Date().addingTimeInterval(0.4)]
        await module.refreshEntitlementCache()
        let ok8 = await waitUntil { spy.changes.count == 1 }
        XCTAssertTrue(ok8)
        bridge.ids = []                                // StoreKit drops the expired transaction
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
        XCTAssertEqual(defaults.data(forKey: CorruptStore.key(for: PurchaseDeliveryQueue.storageKey)), garbage,
                       "the unreadable payload is preserved")
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
}
