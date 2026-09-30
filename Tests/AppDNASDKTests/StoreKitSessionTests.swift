// StoreKitSessionTests.swift
//
// SPEC-497 §3.10 / §3.11 / §13a.2 — the StoreKit half of the billing proof, driven by `SKTestSession`
// over `AppDNATestProducts.storekit` (no Apple account, no UI: dialogs disabled).
//
//   SubscriptionObserverOwnership (a) storeKit2: a forced renewal is FINISHED by the owning observer.
//                                  (b) revenueCat (unlinked): baseline, forced renewal → NO lifecycle event,
//                                      the renewal stays in `Transaction.unfinished`, entitlements still
//                                      read the product, the snapshot is persisted.
//                                  (c) adapty (unlinked, LD-R10-1): the same sequence → `subscription_renewed`
//                                      IS emitted, and the renewal still stays unfinished.
//   StoreKitRestoreNoNetwork       a storeKit2 restore succeeds with every network request failing, and
//                                  makes none (replaces device row C1-7i).
//   Purchase path                  charged price == product price for a plain monthly; free trial → 0 and
//                                  is_trial; pay-up-front intro → the intro price; is_consumable; a re-buy
//                                  of the lifetime product is `alreadyOwned`.
//   Late purchase                  an interrupted purchase resolved later arrives through
//                                  `Transaction.updates` → exactly one `purchase_completed`, then finished.
//
// The spec calls SKTestSession inside the hostless SPM test target "unproven" (round-3 SDK minor 8). If
// the session cannot be created here, every test SKIPS with that reason (the fallback target is the RN
// pod's app-hosted `test_spec`); the emission half is always asserted hostless in
// SubscriptionObserverEmissionTests.

import XCTest
import StoreKit
import StoreKitTest
@testable import AppDNASDK

final class StoreKitSessionTests: XCTestCase {

    private var session: SKTestSession!
    private var observer: SubscriptionStatusObserver?
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var queue: PurchaseDeliveryQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let url = Bundle.module.url(forResource: "AppDNATestProducts", withExtension: "storekit") else {
            throw XCTSkip("AppDNATestProducts.storekit is not in the test bundle")
        }
        do {
            session = try SKTestSession(contentsOf: url)
        } catch {
            throw XCTSkip("SKTestSession cannot run in this (hostless) test target: \(error)")
        }
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        suiteName = "ai.appdna.sdk.test.sk.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        events = []
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "t.\(UUID())")))
        tracker.eventSink = { [weak self] in self?.events.append($0) }
        queue = PurchaseDeliveryQueue(environment: PurchaseDeliveryQueue.Environment(
            defaults: defaults, now: Date.init, currentToken: { nil }, firstIdentifiedToken: { nil },
            deliveringDelegate: { nil }, tracker: { [weak self] in self?.tracker }
        ))
    }

    override func tearDown() {
        observer?.stop()
        observer = nil
        session?.clearTransactions()
        defaults?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func unfinishedIds(productId: String) async -> [UInt64] {
        var ids: [UInt64] = []
        for await result in Transaction.unfinished {
            if case .verified(let t) = result, t.productID == productId { ids.append(t.id) }
        }
        return ids
    }

    private func buyWithoutFinishing(_ productId: String) async throws -> Transaction {
        let product = try XCTUnwrap(try await Product.products(for: [productId]).first)
        let result = try await product.purchase()
        guard case .success(.verified(let transaction)) = result else {
            throw XCTSkip("SKTestSession purchase did not succeed in this target: \(result)")
        }
        return transaction
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }

    private func makeObserver(mode: SubscriptionObserverMode, emits: Bool) -> SubscriptionStatusObserver {
        SubscriptionStatusObserver(
            eventTracker: tracker, defaults: defaults, mode: mode,
            emitsLifecycleEvents: emits, deliveryQueue: queue
        )
    }

    // MARK: - (a) storeKit2 finishes

    func testStoreKit2ObserverFinishesARenewal() async throws {
        let obs = makeObserver(mode: .storeKitOwned, emits: true)
        observer = obs
        obs.start()
        _ = try await StoreKit2Bridge(deliveryQueue: queue).purchase(productId: "ai.appdna.test.monthly", appAccountToken: nil)
        try session.forceRenewalOfSubscription(productIdentifier: "ai.appdna.test.monthly")
        let drained = await waitUntil { await self.unfinishedIds(productId: "ai.appdna.test.monthly").isEmpty }
        XCTAssertTrue(drained, "the owning observer finishes the renewal")
    }

    // MARK: - (b) revenueCat never finishes, never emits lifecycle

    func testRevenueCatObserverNeverFinishesAndEmitsNothing() async throws {
        let obs = makeObserver(mode: .providerOwned, emits: false)
        observer = obs
        _ = try await buyWithoutFinishing("ai.appdna.test.monthly")
        await obs.reconcile()                                            // baseline
        try session.forceRenewalOfSubscription(productIdentifier: "ai.appdna.test.monthly")
        try? await Task.sleep(nanoseconds: 500_000_000)
        await obs.reconcile()
        XCTAssertFalse(events.contains { $0.event_name.hasPrefix("subscription_") }, "owner Q2: no device lifecycle events")
        let unfinished = await unfinishedIds(productId: "ai.appdna.test.monthly")
        XCTAssertFalse(unfinished.isEmpty, "the SDK finished nothing — the renewal is still unfinished")
        XCTAssertFalse(obs.loadSnapshot().isEmpty, "the snapshot is still persisted")
        let entitlements = await ExternalProviderBridge(provider: .revenueCat).getEntitlements(appAccountToken: nil)
        XCTAssertTrue(entitlements.contains("ai.appdna.test.monthly"), "entitlements still read from the store")
    }

    // MARK: - (c) adapty emits, never finishes

    func testAdaptyObserverEmitsRenewalButNeverFinishes() async throws {
        let obs = makeObserver(mode: .providerOwned, emits: true)
        observer = obs
        _ = try await buyWithoutFinishing("ai.appdna.test.monthly")
        await obs.reconcile()                                            // baseline
        try session.forceRenewalOfSubscription(productIdentifier: "ai.appdna.test.monthly")
        let renewed = await waitUntil {
            await obs.reconcile()
            return self.events.contains { $0.event_name == "subscription_renewed" }
        }
        XCTAssertTrue(renewed, "LD-R10-1: Adapty keeps device lifecycle events")
        let unfinished = await unfinishedIds(productId: "ai.appdna.test.monthly")
        XCTAssertFalse(unfinished.isEmpty, "…and the SDK still finishes nothing")
    }

    // MARK: - Restore without network (replaces C1-7i)

    func testStoreKit2RestoreSucceedsAndMakesNoNetworkCall() async throws {
        _ = try await StoreKit2Bridge(deliveryQueue: queue).purchase(productId: "ai.appdna.test.lifetime", appAccountToken: nil)
        FailingURLProtocol.requests = 0
        URLProtocol.registerClass(FailingURLProtocol.self)
        defer { URLProtocol.unregisterClass(FailingURLProtocol.self) }
        let restored = try await StoreKit2Bridge(deliveryQueue: queue).restore(appAccountToken: nil)
        XCTAssertTrue(restored.contains("ai.appdna.test.lifetime"))
        XCTAssertEqual(FailingURLProtocol.requests, 0, "a storeKit2 restore makes no network call")
    }

    final class FailingURLProtocol: URLProtocol {
        static var requests = 0
        override class func canInit(with request: URLRequest) -> Bool { requests += 1; return true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    // MARK: - Purchase path: charged price, trial, consumable, re-buy

    func testPlainMonthlyReportsTheChargedPriceEqualToTheProductPrice() async throws {
        let product = try XCTUnwrap(try await Product.products(for: ["ai.appdna.test.monthly"]).first)
        let result = try await StoreKit2Bridge(deliveryQueue: queue).purchase(productId: product.id, appAccountToken: nil)
        XCTAssertEqual(result.price, NSDecimalNumber(decimal: product.price).doubleValue, accuracy: 1e-9)
        XCTAssertEqual(result.isTrial, false)
        XCTAssertFalse(result.isConsumable)
        XCTAssertTrue(result.isSubscription)
        XCTAssertNotNil(result.originalTransactionId)
    }

    func testFreeTrialIsTrialWithPriceZero() async throws {
        let result = try await StoreKit2Bridge(deliveryQueue: queue).purchase(productId: "ai.appdna.test.monthly_trial", appAccountToken: nil)
        XCTAssertEqual(result.isTrial, true)
        XCTAssertEqual(PurchaseSuccessEvents.properties(paywallId: nil, result: result)["price"] as? Double, 0)
    }

    func testPaidIntroReportsTheIntroPriceAndIsNotATrial() async throws {
        let result = try await StoreKit2Bridge(deliveryQueue: queue).purchase(productId: "ai.appdna.test.monthly_paidintro", appAccountToken: nil)
        XCTAssertEqual(result.isTrial, false)
        XCTAssertEqual(result.price, 2.99, accuracy: 1e-9)
    }

    func testConsumableFlagAndLifetimeRebuyIsAlreadyOwned() async throws {
        let bridge = StoreKit2Bridge(deliveryQueue: queue)
        let coins = try await bridge.purchase(productId: "ai.appdna.test.coins", appAccountToken: nil)
        XCTAssertTrue(coins.isConsumable)
        XCTAssertFalse(coins.alreadyOwned)

        let first = try await bridge.purchase(productId: "ai.appdna.test.lifetime", appAccountToken: nil)
        XCTAssertFalse(first.isConsumable)
        XCTAssertFalse(first.alreadyOwned)
        let second = try await bridge.purchase(productId: "ai.appdna.test.lifetime", appAccountToken: nil)
        XCTAssertTrue(second.alreadyOwned, "a re-buy of an owned non-consumable is flagged")
    }

    // MARK: - Late purchase (interrupted)

    func testInterruptedPurchaseIsReportedOnceThroughUpdatesThenFinished() async throws {
        let obs = makeObserver(mode: .storeKitOwned, emits: true)
        observer = obs
        obs.start()
        session.interruptedPurchasesEnabled = true
        _ = try? await StoreKit2Bridge(deliveryQueue: queue).purchase(productId: "ai.appdna.test.coins", appAccountToken: nil)
        session.interruptedPurchasesEnabled = false
        guard let interrupted = session.allTransactions().last(where: { $0.productIdentifier == "ai.appdna.test.coins" }) else {
            throw XCTSkip("SKTestSession produced no interrupted transaction in this target")
        }
        try session.resolveIssueForTransaction(identifier: interrupted.identifier)
        let reported = await waitUntil { self.events.contains { $0.event_name == "purchase_completed" } }
        XCTAssertTrue(reported, "the late purchase is reported")
        XCTAssertEqual(events.filter { $0.event_name == "purchase_completed" }.count, 1)
        XCTAssertEqual(events.first { $0.event_name == "purchase_completed" }?.properties?["paywall_id"]?.value as? String, "")
        let finished = await waitUntil { await self.unfinishedIds(productId: "ai.appdna.test.coins").isEmpty }
        XCTAssertTrue(finished, "…then finished")
        let queued = await queue.queuedIds()
        XCTAssertEqual(queued.count, 1, "queued for delivery (no delegate here)")
    }
}
