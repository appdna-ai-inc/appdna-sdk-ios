import Foundation
#if canImport(Adapty)
import Adapty
#endif

/// Adapty SDK billing bridge implementation.
/// Wraps Adapty SDK calls and maps models to AppDNA's billing types.
///
/// Usage: Configure via `AppDNA.configure(billing: .adapty(apiKey: "..."))`
///
/// Requires Adapty SDK to be available (conditionally imported). Compiled against Adapty 3.17.3 in a
/// scratch package (this file verbatim): `Adapty.activate(_:)`, `Adapty.restorePurchases()`,
/// `Adapty.getProfile()`, `AdaptyProfile.accessLevels`, `AccessLevel.vendorProductId`. The 2.x releases
/// share these APIs but were not compiled against. The SDK does not BUY through Adapty (see `purchase`).
/// If Adapty is not linked, this bridge logs a warning and returns empty results.
///
/// **Subscription lifecycle** (`subscription_renewed` / `_canceled` / `_renewal_failed`) is NOT emitted
/// here — it is emitted by `SubscriptionStatusObserver`, which now runs under this provider too, in
/// `.providerOwned` mode (Adapty owns transaction finishing, so the observer must not drain
/// `Transaction.updates`). The observer reconciles at start, on every app foreground, and whenever this
/// bridge nudges it below. Adapty renewals that happen while the app is backgrounded are therefore
/// caught on the next foreground rather than in real time — the honest limit of not binding to
/// `AdaptyDelegate` here.

final class AdaptyBridge: BillingBridgeProtocol {
    private let apiKey: String
    private weak var eventTracker: EventTracker?
    private var isActivated = false

    init(apiKey: String, eventTracker: EventTracker?) {
        self.apiKey = apiKey
        self.eventTracker = eventTracker
        activate()
    }

    private func activate() {
        #if canImport(Adapty)
        Adapty.activate(apiKey)
        isActivated = true
        Log.info("Adapty bridge activated")
        #else
        Log.warning("Adapty SDK not available — billing operations will return empty results")
        #endif
    }

    // MARK: - BillingBridgeProtocol

    /// The message of the refusal below.
    static let purchaseRefusal = "Adapty: purchases are made by Adapty in your app — Adapty.makePurchase(product:) needs an AdaptyPaywallProduct from an Adapty paywall, which the SDK does not have"

    /// 🔴 THIS NEVER COMPILED AGAINST ANY ADAPTY SDK.
    ///
    /// It called `Adapty.makePurchase(product: productId)` with a product-id STRING and read
    /// `transactionId` / `price` / `currencyCode` off the result. Neither Adapty 2.x nor 3.x has that:
    /// `makePurchase(product:)` takes an `AdaptyPaywallProduct` — which only an Adapty paywall /
    /// placement lookup hands out — and 3.x returns an `AdaptyPurchaseResult` enum. Published builds never
    /// link Adapty (`canImport(Adapty)` is false there), so nobody saw it; a source build that linked
    /// Adapty failed to compile here.
    ///
    /// There is no Adapty API that buys by product id, and buying through StoreKit behind Adapty's back
    /// would finish (or strand) a transaction Adapty owns. So the SDK does not buy under Adapty — linked or
    /// not — and the ownership policy says so (`sdkCanPurchase: false` for `.adapty`): the paywall reports
    /// `providerNotAvailable` with the tapped product id, and the host buys with Adapty
    /// (`Adapty.makePurchase(product:)`), the documented recipe. Restore and entitlements do go through
    /// Adapty when it is linked. This is reached only if a caller bypasses the policy.
    func purchase(
        productId: String,
        appAccountToken: UUID?
    ) async throws -> PurchaseResult {
        _ = appAccountToken
        // NO `purchase_started` / `purchase_failed` HERE — the caller emits them (`PaywallManager` for a
        // paywall tap, `BillingModule.purchase` for a direct call), as for every other bridge. This bridge
        // used to emit both as well, so every Adapty purchase reported `purchase_started` twice.
        let error = BillingError.providerNotAvailable(Self.purchaseRefusal)
        await MainActor.run {
            AppDNA.billingDelegate?.onPurchaseFailed(productId: productId, error: error)
        }
        throw error
    }

    func restore(appAccountToken: UUID?) async throws -> [String] {
        _ = appAccountToken  // Adapty binds via its own customerUserId
        #if canImport(Adapty)
        let profile = try await Adapty.restorePurchases()
        let ids = Self.activeProductIds(profile)
        eventTracker?.track(event: "purchase_restored", properties: BillingEventProps.marked([
            "restored_count": ids.count,
            "provider": "adapty",
        ]))
        // SPEC-400 — fire onRestoreCompleted.
        await MainActor.run {
            AppDNA.billingDelegate?.onRestoreCompleted(restoredProducts: ids)
        }
        // A restore can surface subscriptions this install has never seen. Reconcile so the snapshot
        // records them as PRESENT rather than treating the next pass's sighting as a state change.
        AppDNA.reconcileSubscriptionState()
        return ids
        #else
        // Even when Adapty is not linked we still surface the empty
        // restore so hosts get a consistent callback.
        await MainActor.run {
            AppDNA.billingDelegate?.onRestoreCompleted(restoredProducts: [])
        }
        return []
        #endif
    }

    #if canImport(Adapty)
    /// The PRODUCT ids behind the profile's active access levels — what the bridge contract returns. The
    /// access-level KEYS (e.g. "premium") used to be returned instead, so the entitlement list and the
    /// restore callback named access levels where every other bridge names store products.
    /// `AccessLevel.vendorProductId` / `isActive` exist in Adapty 2.x and 3.x alike.
    static func activeProductIds(_ profile: AdaptyProfile) -> [String] {
        var seen = Set<String>()
        return profile.accessLevels.values
            .filter(\.isActive)
            .map(\.vendorProductId)
            .filter { seen.insert($0).inserted }
    }
    #endif

    func getEntitlements(appAccountToken: UUID?) async -> [String] {
        _ = appAccountToken  // Adapty binds via its own customerUserId
        #if canImport(Adapty)
        do {
            let profile = try await Adapty.getProfile()
            return Self.activeProductIds(profile)
        } catch {
            Log.error("Adapty getEntitlements failed: \(error.localizedDescription)")
            return []
        }
        #else
        return []
        #endif
    }
}
