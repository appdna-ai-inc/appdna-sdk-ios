// PaywallManagerNoProviderTests.swift
//
// SPEC-497 §3.10 / §3.2 rule 5 — a paywall tap the SDK cannot buy (`none`, or RevenueCat / Adapty not
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

    override func setUp() {
        super.setUp()
        events = []
        failureRoutes = []
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        tracker = EventTracker(identityManager: identity)
        tracker.eventSink = { [weak self] event in self?.events.append(event) }
        observerToken = NotificationCenter.default.addObserver(
            forName: .paywallPurchaseFailure, object: nil, queue: nil
        ) { [weak self] note in
            self?.failureRoutes.append(note.userInfo?["action"] as? String ?? "?")
        }
    }

    override func tearDown() {
        if let observerToken { NotificationCenter.default.removeObserver(observerToken) }
        super.tearDown()
    }

    private final class Spy: AppDNAPaywallDelegate {
        var started: [String] = []
        var failed: [(errorType: String, productId: String?)] = []
        func onPaywallPresented(paywallId: String) {}
        func onPaywallPurchaseStarted(paywallId: String, productId: String) { started.append(productId) }
        func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {}
        func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
            failed.append((errorType, productId))
        }
        func onPaywallDismissed(paywallId: String) {}
    }

    private func tap(provider: BillingProvider, configured: Bool = true) async -> Spy {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let paywall = rcm.decodePaywallPayload([
            "id": "pw_test",
            "plans": [["product_id": "plan_monthly", "price": "9.99"]],
            "post_purchase": ["on_failure": ["action": "show_error", "message": "m"]],
        ])!
        let manager = PaywallManager(
            remoteConfigManager: rcm,
            billingBridge: BillingOwnership.makeBridge(for: provider, tracker: tracker),
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
        for _ in 0..<100 where spy.failed.isEmpty {
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

    /// SPEC-497 I3 r7 m5 / §3.2 rule 3 (R65–R67) — a tap while billing is not configured (before
    /// `configure`, or after `shutdown()`) fails with the `unknown` "not configured yet" error, as Android's
    /// paywall tap and the direct API — even with a StoreKit bridge in hand. NEGATIVE CONTROL: without the
    /// `billingConfigured()` check the StoreKit bridge is called and `purchase_started` is emitted — this fails.
    func testNotConfiguredTapFailsUnknownNotConfigured() async {
        let spy = await tap(provider: .storeKit2, configured: false)
        XCTAssertEqual(events.map(\.event_name), ["purchase_failed"], "exactly one purchase_failed, no purchase_started")
        let props = events.first?.properties
        XCTAssertEqual(props?["error_type"]?.value as? String, "unknown")
        XCTAssertEqual(props?["error"]?.value as? String, AppDNA.BillingModule.notConfiguredMessage)
        XCTAssertEqual(spy.failed.first?.errorType, "unknown")
        XCTAssertEqual(spy.failed.first?.productId, "plan_monthly")
        XCTAssertTrue(spy.started.isEmpty, "the purchase never started")
        XCTAssertEqual(failureRoutes, ["show_error"], "the paywall's failure routing runs")
    }
}
