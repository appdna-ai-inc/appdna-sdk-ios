import Foundation

/// Result of a completed purchase.
public struct PurchaseResult {
    public let productId: String
    public let transactionId: String
    public let price: Double
    public let currency: String
    public let provider: String

    /// Does this product AUTO-RENEW? (`purchase_completed` vs `subscription_started`.)
    ///
    /// 🔴 `subscription_started` is one of the three MTPU-metered events the billing query counts
    /// (`purchase_completed`, `subscription_started`, `subscription_renewed`) — and NO SDK emitted it.
    /// The only rows in BigQuery carrying that name were seeded demo data. MTPU totals survived (a new
    /// subscriber still lands via `purchase_completed`, and the metric is COUNT(DISTINCT user) over the
    /// union), but the subscription funnel was fiction: nothing downstream could tell a NEW SUBSCRIPTION
    /// from a one-off / consumable / lifetime purchase.
    ///
    /// Every bridge must decide this at the ONE place that knows the product's real type:
    ///   - `StoreKit2Bridge` → `product.subscription != nil` (`Product.SubscriptionInfo?`)
    ///   - `RevenueCatBridge` → `storeProduct.subscriptionPeriod != nil`
    ///   - `AdaptyBridge`    → `PurchaseSuccessEvents.isAutoRenewable(productId:)` (asks StoreKit, since
    ///     Adapty's own product model is not in scope at that emit site)
    ///
    /// It is deliberately non-optional and has no default: a new bridge MUST answer the question rather
    /// than silently inherit `false`, which is exactly how an SDK ships a metered event nobody emits.
    /// This is the Android `Entitlement.expiresAt != null` discriminator, in the iOS type that carries it.
    public let isSubscription: Bool

    /// Is this product a CONSUMABLE? Emitted as
    /// `is_consumable` on `purchase_completed`. No default, for the same reason as `isSubscription`:
    /// every bridge answers it from the product type it actually sold (StoreKit2 `Transaction.productType`,
    /// RevenueCat `storeProduct.productType`, Adapty a StoreKit `Product` lookup).
    public let isConsumable: Bool

    /// A free-trial start. `StoreKit2Bridge` and the late path always set
    /// it (so `is_trial` is always a Bool on `storeKit2`); the RevenueCat and Adapty bridges leave it nil
    /// and `is_trial` is omitted. When true, the reported price is 0.
    public var isTrial: Bool? = nil

    /// The store's original transaction id (`Transaction.originalID`), emitted as
    /// `original_transaction_id` so revenue dedupe can match provider rows.
    public var originalTransactionId: String? = nil

    /// A re-buy of an owned non-consumable / subscription: StoreKit returned a
    /// transaction that was ALREADY among the current entitlements before the purchase call. The caller
    /// emits one `purchase_restored{reason: "item_already_owned"}` instead of a conversion.
    internal var alreadyOwned: Bool = false

    /// The StoreKit environment the transaction was made in — `"production"`, `"sandbox"` or `"xcode"`
    /// (`Transaction.environment`). Carried into `TransactionInfo.environment`; nil when the bridge could
    /// not tell, which `TransactionInfo` reports as `"production"` (its long-standing default).
    internal var environment: String? = nil

    internal init(
        productId: String,
        transactionId: String,
        originalTransactionId: String? = nil,
        price: Double,
        currency: String,
        provider: String,
        isSubscription: Bool,
        isConsumable: Bool,
        isTrial: Bool? = nil,
        alreadyOwned: Bool = false,
        environment: String? = nil
    ) {
        self.productId = productId
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.price = price
        self.currency = currency
        self.provider = provider
        self.isSubscription = isSubscription
        self.isConsumable = isConsumable
        self.isTrial = isTrial
        self.alreadyOwned = alreadyOwned
        self.environment = environment
    }
}

/// Protocol for billing provider integrations.
///
/// The `appAccountToken:` parameter is the per-user binding token used to
/// defend against the cross-account-entitlement-leak (User A buys → User B
/// signs in on the same device → B should NOT see A's subscription). It is
/// resolved from the currently-identified user (via
/// `AppAccountTokenResolver.tokenForCurrentUser()`) or supplied explicitly by
/// the caller. `nil` means "host has not identified a user yet" — bridges
/// MUST treat that as the legacy unfiltered path (preserves first-launch /
/// pre-identify behaviour).
protocol BillingBridgeProtocol {
    /// Purchase a product by its App Store product ID.
    /// `appAccountToken`, when non-nil, MUST be passed through to
    /// `Product.purchase(options: [.appAccountToken(token)])` so the resulting
    /// transaction is bound to the current user.
    func purchase(
        productId: String,
        appAccountToken: UUID?
    ) async throws -> PurchaseResult

    /// Restore previously purchased products. Returns restored product IDs.
    /// `appAccountToken`, when non-nil, MUST be used to filter entitlements:
    /// transactions tagged with a different token MUST be excluded
    /// (`EntitlementOwnerFilter`).
    func restore(appAccountToken: UUID?) async throws -> [String]

    /// Get current active entitlements. Same filtering contract as `restore`.
    func getEntitlements(appAccountToken: UUID?) async -> [String]
}

// MARK: - Back-compat conveniences

/// Default-nil overloads so existing call sites that don't yet thread a token
/// keep compiling. New call sites should always pass an explicit token.
extension BillingBridgeProtocol {
    func purchase(productId: String) async throws -> PurchaseResult {
        try await purchase(productId: productId, appAccountToken: nil)
    }
    func restore() async throws -> [String] {
        try await restore(appAccountToken: nil)
    }
    func getEntitlements() async -> [String] {
        await getEntitlements(appAccountToken: nil)
    }
}
