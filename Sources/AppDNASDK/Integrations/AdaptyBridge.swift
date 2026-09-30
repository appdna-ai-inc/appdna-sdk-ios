import Foundation
#if canImport(Adapty)
import Adapty
#endif

/// Adapty SDK billing bridge implementation.
/// Wraps Adapty SDK calls and maps models to AppDNA's billing types.
///
/// Usage: Configure via `AppDNA.configure(billing: .adapty(apiKey: "..."))`
///
/// Requires Adapty SDK to be available (conditionally imported).
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

    func purchase(
        productId: String,
        appAccountToken: UUID?
    ) async throws -> PurchaseResult {
        // Adapty binds purchases to its own customer-user-id (set via
        // `Adapty.identify(customerUserId:)` when AppDNA.identify runs),
        // so passing `appAccountToken` separately would risk inconsistent
        // attribution between Apple-side and Adapty-side ownership.
        _ = appAccountToken
        eventTracker?.track(event: "purchase_started", properties: BillingEventProps.marked([
            "product_id": productId,
            "provider": "adapty",
        ]))

        #if canImport(Adapty)
        do {
            let result = try await Adapty.makePurchase(product: productId)
            let purchaseResult = PurchaseResult(
                productId: productId,
                transactionId: result.transactionId ?? UUID().uuidString,
                price: result.price ?? 0,
                currency: result.currencyCode ?? "USD",
                provider: "adapty",
                // Adapty's purchase result does not carry the product TYPE at this site, so ask the store
                // that actually billed it. Same rule as StoreKit2Bridge (`product.subscription != nil`),
                // just resolved a level up — an Adapty customer must not be the one customer whose
                // subscriptions never emit `subscription_started`.
                isSubscription: await PurchaseSuccessEvents.isAutoRenewable(productId: productId),
                // SPEC-497 §13a.2 (C1, round-20 SDK minor 2) — a StoreKit product lookup, as for
                // `isAutoRenewable`. `isTrial` stays nil (`is_trial` omitted for Adapty, R45).
                isConsumable: await PurchaseSuccessEvents.isConsumable(productId: productId)
            )
            // 🔴 NO EMIT HERE. A bridge NEVER emits the metered purchase events — its CALLER does.
            //
            // This bridge used to emit, and `PaywallManager` (which calls `bridge.purchase(...)`)
            // emitted again on the very result returned below — so every Adapty purchase through a
            // native paywall fired `purchase_completed` AND `subscription_started` TWICE, inflating
            // purchase counts and revenue sums. Meanwhile StoreKit2Bridge emitted nothing and relied on
            // its caller, so the DIRECT `AppDNA.billing.purchase()` path emitted nothing at all.
            //
            // One rule, both callers, every provider: emission belongs to whoever called us. See
            // `AppDNA.BillingModule.purchase(_:options:)`. `check-purchase-emit-chokepoint.ts` fails
            // the build if a bridge ever emits again.
            //
            // `isSubscription` above is still resolved HERE, because only the bridge knows which store
            // actually billed — the caller cannot ask Adapty what kind of product it just sold.
            // SPEC-400 — fire onPurchaseCompleted to the host's
            // AppDNABillingDelegate. Bridges are the single source of
            // truth for billing-delegate purchase events.
            let txInfo = TransactionInfo(
                transactionId: purchaseResult.transactionId,
                productId: productId,
                purchaseDate: Date(),
                environment: "production"
            )
            await MainActor.run {
                AppDNA.billingDelegate?.onPurchaseCompleted(productId: productId, transaction: txInfo)
            }
            // Adapty's subscriber state just moved. Reconcile so the observer's snapshot records the new
            // subscription immediately — otherwise the FIRST post-purchase reconcile would see a product
            // that is new to it, and a product new to the snapshot is (correctly) not a renewal, but the
            // snapshot would only be written at the next foreground.
            AppDNA.reconcileSubscriptionState()
            return purchaseResult
        } catch {
            eventTracker?.track(event: "purchase_failed", properties: BillingEventProps.marked([
                "product_id": productId,
                "error": error.localizedDescription,
                "provider": "adapty",
            ]))
            // SPEC-400 — fire onPurchaseFailed.
            await MainActor.run {
                AppDNA.billingDelegate?.onPurchaseFailed(productId: productId, error: error)
            }
            throw error
        }
        #else
        // Stub: Adapty not available
        let err = NSError(
            domain: "ai.appdna.sdk",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Adapty SDK not linked"]
        )
        await MainActor.run {
            AppDNA.billingDelegate?.onPurchaseFailed(productId: productId, error: err)
        }
        throw err
        #endif
    }

    func restore(appAccountToken: UUID?) async throws -> [String] {
        _ = appAccountToken  // Adapty binds via its own customerUserId
        #if canImport(Adapty)
        let profile = try await Adapty.restorePurchases()
        let ids = profile.accessLevels.filter(\.value.isActive).map(\.key)
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

    func getEntitlements(appAccountToken: UUID?) async -> [String] {
        _ = appAccountToken  // Adapty binds via its own customerUserId
        #if canImport(Adapty)
        do {
            let profile = try await Adapty.getProfile()
            return profile.accessLevels.filter(\.value.isActive).map(\.key)
        } catch {
            Log.error("Adapty getEntitlements failed: \(error.localizedDescription)")
            return []
        }
        #else
        return []
        #endif
    }
}
