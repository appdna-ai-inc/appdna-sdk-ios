import XCTest
@testable import AppDNASDK

/// 🔴 `subscription_started` is METERED and NO SDK EMITTED IT.
///
/// `BigQueryBillingService` bills MTPU over
/// `event_name IN ('purchase_completed', 'subscription_started', 'subscription_renewed')`. iOS, Android,
/// Flutter and RN had zero emit sites for the middle one — the only production rows carrying that name
/// are seeded demo data (sdk_version 1.0.0 / 1.0.3, versions that never shipped). Totals survived
/// (COUNT(DISTINCT user) over the union, and a new subscriber lands via `purchase_completed`), but the
/// subscription funnel was a fiction: nothing could distinguish a NEW SUBSCRIPTION from a one-off.
///
/// These tests drive the REAL emitter every purchase path now funnels through
/// (`PurchaseSuccessEvents.emit`, called by `PaywallManager.handlePurchase` for StoreKit2 + RevenueCat
/// and by `AdaptyBridge.purchase` for Adapty) and read back what the REAL `EventTracker` produced, via
/// the `eventSink` seam. The per-provider half of the rule — "is this product auto-renewing?" — is the
/// `PurchaseResult.isSubscription` flag each bridge sets from its own product model
/// (`product.subscription != nil` / `storeProduct.subscriptionPeriod != nil` /
/// `PurchaseSuccessEvents.isAutoRenewable`), so a provider is exercised here by the result it returns.
final class SubscriptionStartedEventTests: XCTestCase {

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!

    override func setUp() {
        super.setUp()
        events = []
        let keychain = KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)")
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: keychain))
        tracker.eventSink = { [weak self] event in self?.events.append(event) }
    }

    private func names() -> [String] { events.map(\.event_name) }

    private func count(_ name: String) -> Int { names().filter { $0 == name }.count }

    private func properties(of eventName: String) -> [String: Any] {
        guard let event = events.first(where: { $0.event_name == eventName }),
              let props = event.properties else { return [:] }
        return props.mapValues { $0.value }
    }

    /// A purchase result as a bridge would return it. `isSubscription` is the ONLY difference between
    /// a subscription and a one-off here — which is the point: the discriminator is the product's type,
    /// not the price, the provider or the paywall.
    private func result(
        productId: String = "pro_yearly",
        provider: String = "storekit2",
        isSubscription: Bool
    ) -> PurchaseResult {
        PurchaseResult(
            productId: productId,
            transactionId: "tx-1",
            price: 49.99,
            currency: "USD",
            provider: provider,
            isSubscription: isSubscription,
            isConsumable: false
        )
    }

    // MARK: - The rule

    func testSubscriptionPurchaseEmitsBothPurchaseCompletedAndSubscriptionStarted() {
        PurchaseSuccessEvents.emit(
            tracker: tracker,
            paywallId: "pw_main",
            result: result(isSubscription: true)
        )

        // Order matters as much as presence: `purchase_completed` stays FIRST and stays emitted — this
        // is additive, not a replacement.
        XCTAssertEqual(names(), ["purchase_completed", "subscription_started"])
        XCTAssertEqual(count("purchase_completed"), 1)
        XCTAssertEqual(count("subscription_started"), 1)
    }

    func testOneOffPurchaseEmitsOnlyPurchaseCompleted() {
        PurchaseSuccessEvents.emit(
            tracker: tracker,
            paywallId: "pw_main",
            result: result(productId: "lifetime_unlock", isSubscription: false)
        )

        XCTAssertEqual(names(), ["purchase_completed"])
        XCTAssertEqual(count("subscription_started"), 0)
    }

    func testSubscriptionStartedCarriesTheSamePropertyEnvelopeAsPurchaseCompleted() {
        PurchaseSuccessEvents.emit(
            tracker: tracker,
            paywallId: "pw_main",
            result: result(isSubscription: true),
            extra: ["is_trial": true, "experiment_id": "exp_1", "transaction_id": "tx-1"]
        )

        let completed = properties(of: "purchase_completed")
        let started = properties(of: "subscription_started")

        XCTAssertEqual(Set(completed.keys), Set(started.keys))
        XCTAssertEqual(started["product_id"] as? String, "pro_yearly")
        XCTAssertEqual(started["paywall_id"] as? String, "pw_main")
        XCTAssertEqual(started["price"] as? Double, 49.99)
        XCTAssertEqual(started["currency"] as? String, "USD")
        XCTAssertEqual(started["provider"] as? String, "storekit2")
        XCTAssertEqual(started["is_trial"] as? Bool, true)
        XCTAssertEqual(started["experiment_id"] as? String, "exp_1")
        XCTAssertEqual(started["transaction_id"] as? String, "tx-1")
    }

    // MARK: - Every provider, not just the store path

    /// RevenueCat purchases return through the same `PaywallManager` emit site, tagged
    /// `provider: revenuecat` and carrying `isSubscription` from `storeProduct.subscriptionPeriod != nil`.
    /// A fix that only covered StoreKit would leave every RC customer with the same hole.
    func testRevenueCatSubscriptionEmitsSubscriptionStarted() {
        PurchaseSuccessEvents.emit(
            tracker: tracker,
            paywallId: "pw_main",
            result: result(provider: "revenuecat", isSubscription: true)
        )

        XCTAssertEqual(names(), ["purchase_completed", "subscription_started"])
        XCTAssertEqual(properties(of: "subscription_started")["provider"] as? String, "revenuecat")
    }

    func testRevenueCatOneOffDoesNotEmitSubscriptionStarted() {
        PurchaseSuccessEvents.emit(
            tracker: tracker,
            paywallId: "pw_main",
            result: result(productId: "coins_100", provider: "revenuecat", isSubscription: false)
        )

        XCTAssertEqual(names(), ["purchase_completed"])
    }

    /// Adapty emits from inside its own bridge (no paywall in scope), so its envelope has no
    /// `paywall_id` — and must still produce `subscription_started` for an auto-renewing product.
    func testAdaptySubscriptionEmitsSubscriptionStartedWithoutPaywallId() {
        PurchaseSuccessEvents.emit(
            tracker: tracker,
            paywallId: nil,
            result: result(provider: "adapty", isSubscription: true)
        )

        XCTAssertEqual(names(), ["purchase_completed", "subscription_started"])
        let started = properties(of: "subscription_started")
        XCTAssertEqual(started["provider"] as? String, "adapty")
        XCTAssertNil(started["paywall_id"])
    }

    func testAdaptyOneOffDoesNotEmitSubscriptionStarted() {
        PurchaseSuccessEvents.emit(
            tracker: tracker,
            paywallId: nil,
            result: result(productId: "coins_100", provider: "adapty", isSubscription: false)
        )

        XCTAssertEqual(names(), ["purchase_completed"])
    }

    // MARK: - Not once per renewal

    /// `subscription_started` is a PURCHASE-TIME event. `SubscriptionStatusObserver` owns the
    /// renewal/reconcile diff and must never emit it: its snapshot sees the purchased product as NEW on
    /// the very next pass, so emitting there would double-count every purchase, and again on every
    /// renewal. This pins that the observer's diff stays silent for a brand-new product.
    func testSubscriptionObserverDoesNotEmitSubscriptionStartedForANewProduct() {
        let suite = "appdna.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let observer = SubscriptionStatusObserver(eventTracker: tracker, defaults: defaults)

        observer.diffAndEmit(
            previous: [:],
            current: ["pro_yearly": SubSnapshot(productId: "pro_yearly", purchaseTime: 1_000, isAutoRenewing: true)]
        )

        XCTAssertEqual(names(), [])
        XCTAssertEqual(count("subscription_started"), 0)
    }
}
