// PaywallManagerNoProviderTests.swift
//
// A paywall tap the SDK cannot buy (`none`, or RevenueCat / Adapty not
// linked) fails LOUDLY: one `purchase_failed{error_type: providerNotAvailable}`, one
// `onPaywallPurchaseFailed(errorType: providerNotAvailable, productId:)`, no `purchase_started`, no
// `onPaywallPurchaseStarted`, and the paywall's failure routing runs. It used to be a silent no-op.

import XCTest
import UIKit
@testable import AppDNASDK

final class PaywallManagerNoProviderTests: XCTestCase {

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var failureRoutes: [String] = []
    private var observerToken: NSObjectProtocol?
    private var endedToken: NSObjectProtocol?
    private var purchaseEnded = 0

    override func setUp() {
        super.setUp()
        events = []
        failureRoutes = []
        purchaseEnded = 0
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        tracker = EventTracker(identityManager: identity)
        tracker.eventSink = { [weak self] event in self?.events.append(event) }
        observerToken = NotificationCenter.default.addObserver(
            forName: .paywallPurchaseFailure, object: nil, queue: nil
        ) { [weak self] note in
            self?.failureRoutes.append(note.userInfo?["action"] as? String ?? "?")
        }
        endedToken = NotificationCenter.default.addObserver(
            forName: .paywallPurchaseEnded, object: nil, queue: nil
        ) { [weak self] _ in self?.purchaseEnded += 1 }
    }

    override func tearDown() {
        if let observerToken { NotificationCenter.default.removeObserver(observerToken) }
        if let endedToken { NotificationCenter.default.removeObserver(endedToken) }
        super.tearDown()
    }

    private final class Spy: AppDNAPaywallDelegate {
        var started: [String] = []
        var failed: [(errorType: String, productId: String?)] = []
        var completed: [String] = []
        func onPaywallPresented(paywallId: String) {}
        func onPaywallPurchaseStarted(paywallId: String, productId: String) { started.append(productId) }
        func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {
            completed.append(productId)
        }
        func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
            failed.append((errorType, productId))
        }
        func onPaywallDismissed(paywallId: String) {}
    }

    private func tap(
        provider: BillingProvider,
        configured: Bool = true,
        withPostPurchase: Bool = true,
        postPurchase: [String: Any]? = nil,
        bridge: BillingBridgeProtocol? = nil
    ) async -> Spy {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        var payload: [String: Any] = [
            "id": "pw_test",
            "plans": [["product_id": "plan_monthly", "price": "9.99"]],
        ]
        if withPostPurchase {
            payload["post_purchase"] = ["on_failure": ["action": "show_error", "message": "m"]]
        }
        if let postPurchase { payload["post_purchase"] = postPurchase }
        let paywall = rcm.decodePaywallPayload(payload)!
        let manager = PaywallManager(
            remoteConfigManager: rcm,
            billingBridge: bridge ?? BillingOwnership.makeBridge(for: provider, tracker: tracker),
            billingPolicy: BillingOwnership.policy(for: provider, bridgeLinked: BillingOwnership.isLinked(provider)),
            billingConfigured: { configured },
            eventTracker: tracker
        )
        let spy = Spy()
        await MainActor.run {
            manager.handlePurchase(
                paywallId: "pw_test", plan: paywall.plans![0], config: paywall,
                delegate: spy, viewController: UIViewController()
            )
        }
        // A failure is reported to the delegate BEFORE the paywall's failure routing posts: wait for both, so
        // the routing assertion never reads a route still on its way.
        for _ in 0..<250 where (spy.failed.isEmpty || failureRoutes.isEmpty) && spy.completed.isEmpty && purchaseEnded == 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return spy
    }

    private func assertFailsLoudly(_ provider: BillingProvider, message: String) async {
        let spy = await tap(provider: provider)
        XCTAssertEqual(events.map(\.event_name), ["purchase_failed"], "exactly one purchase_failed, no purchase_started")
        let props = events.first?.properties
        XCTAssertEqual(props?["error_type"]?.value as? String, "providerNotAvailable")
        XCTAssertEqual(props?["product_id"]?.value as? String, "plan_monthly")
        XCTAssertEqual(props?["paywall_id"]?.value as? String, "pw_test")
        XCTAssertEqual(props?["error"]?.value as? String, message)
        XCTAssertEqual(props?["emitted_by"]?.value as? String, "sdk")
        XCTAssertNil(props?["reason"], "a configured refusal carries no not_configured reason")
        XCTAssertEqual(spy.failed.count, 1)
        XCTAssertEqual(spy.failed.first?.errorType, "providerNotAvailable")
        XCTAssertEqual(spy.failed.first?.productId, "plan_monthly")
        XCTAssertTrue(spy.started.isEmpty, "the purchase never started")
        XCTAssertEqual(failureRoutes, ["show_error"], "the paywall's failure routing runs")
    }

    func testNoProviderTapFailsLoudly() async {
        await assertFailsLoudly(BillingProvider.none, message: "No billing provider configured")
    }

    func testUnlinkedRevenueCatTapFailsLoudly() async {
        await assertFailsLoudly(.revenueCat, message: "RevenueCat: purchases are made by RevenueCat in your app")
    }

    func testUnlinkedAdaptyTapFailsLoudly() async {
        await assertFailsLoudly(.adapty(apiKey: "k"), message: "Adapty: purchases are made by Adapty in your app")
    }

    /// A tap while billing is not configured (before
    /// `configure`, or after `shutdown()`) fails with the `unknown` "not configured yet" error, as Android's
    /// paywall tap and the direct API — even with a StoreKit bridge in hand. NEGATIVE CONTROL: without the
    /// `billingConfigured()` check the StoreKit bridge is called and `purchase_started` is emitted — this fails.
    func testNotConfiguredTapFailsUnknownNotConfigured() async {
        let spy = await tap(provider: .storeKit2, configured: false)
        XCTAssertEqual(events.map(\.event_name), ["purchase_failed"], "exactly one purchase_failed, no purchase_started")
        let props = events.first?.properties
        XCTAssertEqual(props?["error_type"]?.value as? String, "unknown")
        XCTAssertEqual(props?["error"]?.value as? String, AppDNA.BillingModule.notConfiguredMessage)
        // As Android.
        XCTAssertEqual(props?["reason"]?.value as? String, "not_configured")
        XCTAssertEqual(spy.failed.first?.errorType, "unknown")
        XCTAssertEqual(spy.failed.first?.productId, "plan_monthly")
        XCTAssertTrue(spy.started.isEmpty, "the purchase never started")
        XCTAssertEqual(failureRoutes, ["show_error"], "the paywall's failure routing runs")
    }

    // MARK: - — the CTA stops spinning whenever the purchase ends with the paywall still up

    private final class ScriptedBridge: BillingBridgeProtocol, @unchecked Sendable {
        let fail: Bool
        init(fail: Bool) { self.fail = fail }
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
            if fail { throw BillingError.productNotFound(productId) }
            return PurchaseResult(
                productId: productId, transactionId: "txn_r9", price: 9.99, currency: "USD",
                provider: "storekit2", isSubscription: false, isConsumable: false
            )
        }
        func restore(appAccountToken: UUID?) async throws -> [String] { [] }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
    }

    private func settle() async {
        for _ in 0..<25 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// A refused tap on a paywall with NO `on_failure` config still ends the purchase. NEGATIVE CONTROL:
    /// without the `.paywallPurchaseEnded` post in `handlePostPurchaseFailure`, nothing resets the CTA.
    func testRefusedTapWithNoFailureConfigEndsThePurchase() async {
        let spy = await tap(provider: BillingProvider.none, withPostPurchase: false)
        await settle()
        XCTAssertEqual(spy.failed.count, 1)
        XCTAssertEqual(failureRoutes, [], "no on_failure config, no failure overlay")
        XCTAssertEqual(purchaseEnded, 1, "the CTA is re-enabled")
    }

    /// A store failure on a paywall with NO `on_failure` config ends the purchase (it used to leave the
    /// CTA spinning and disabled). NEGATIVE CONTROL: as above.
    func testStoreFailureWithNoFailureConfigEndsThePurchase() async {
        let spy = await tap(provider: .storeKit2, withPostPurchase: false, bridge: ScriptedBridge(fail: true))
        await settle()
        XCTAssertEqual(spy.failed.first?.errorType, "productNotFound")
        XCTAssertEqual(purchaseEnded, 1, "the CTA is re-enabled")
    }

    /// A success on a paywall with NO `on_success` config leaves the paywall up for the host, so the CTA is
    /// re-enabled too (as Android). NEGATIVE CONTROL: without the post in `handlePostPurchaseSuccess`'s
    /// no-config branch, `purchaseEnded` stays 0.
    func testSuccessWithNoSuccessConfigEndsThePurchase() async {
        let spy = await tap(provider: .storeKit2, withPostPurchase: false, bridge: ScriptedBridge(fail: false))
        await settle()
        XCTAssertEqual(spy.completed, ["plan_monthly"])
        XCTAssertEqual(purchaseEnded, 1, "the CTA is re-enabled")
    }

    /// A success whose `on_success.action` this SDK does not know leaves the paywall up,
    /// so the CTA is re-enabled (as Android). NEGATIVE CONTROL: with `handlePostPurchaseSuccess`'s
    /// `default:` back to `break`, `purchaseEnded` stays 0.
    func testSuccessWithUnknownSuccessActionEndsThePurchase() async {
        let spy = await tap(
            provider: .storeKit2, withPostPurchase: false,
            postPurchase: ["on_success": ["action": "a_future_action", "delay_ms": 0]],
            bridge: ScriptedBridge(fail: false)
        )
        await settle()
        XCTAssertEqual(spy.completed, ["plan_monthly"])
        XCTAssertEqual(purchaseEnded, 1, "the CTA is re-enabled")
    }
}
