import Foundation

#if canImport(RevenueCat)
import RevenueCat

/// RevenueCat billing bridge. Wraps RevenueCat Purchases SDK and auto-tracks events.
final class RevenueCatBridge: NSObject, BillingBridgeProtocol {
    private let eventTracker: EventTracker

    init(eventTracker: EventTracker) {
        self.eventTracker = eventTracker
        super.init()

        // Observe RevenueCat purchase delegate
        Purchases.shared.delegate = self
    }

    func purchase(
        productId: String,
        appAccountToken: UUID?
    ) async throws -> PurchaseResult {
        // NOTE on appAccountToken: RevenueCat manages per-user binding
        // through its own `Purchases.shared.logIn(appUserID:)` API — when the
        // host calls `AppDNA.identify(...)` the integration layer is expected
        // to also call `Purchases.logIn(...)`, and RC then attaches the
        // resulting purchase to that appUserID server-side (including via
        // App Store Server-Server notifications). We therefore do NOT pass
        // an `appAccountToken` purchase option here — RC drives the binding,
        // and passing both would risk an inconsistent attribution.
        _ = appAccountToken  // explicitly acknowledged; binding lives in RC
        let offerings: Offerings
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            await fireBillingPurchaseFailed(productId: productId, error: error)
            throw error
        }
        guard let package = offerings.all.values
            .flatMap(\.availablePackages)
            .first(where: { $0.storeProduct.productIdentifier == productId }) else {
            let err = RevenueCatError.productNotFound(productId)
            await fireBillingPurchaseFailed(productId: productId, error: err)
            throw err
        }

        // SPEC-497 §11.9 (R74) — keep the StoreTransaction: its `transactionIdentifier` is the STORE
        // transaction id revenue dedupe matches against the RevenueCat webhook. This used to be discarded
        // and the RevenueCat app-user id was reported as `transaction_id` instead. (`customerInfo` is not
        // needed any more.) Review-only: no CI job compiles this file (RevenueCat is not linked).
        let storeTransaction: StoreTransaction?
        do {
            (storeTransaction, _, _) = try await Purchases.shared.purchase(package: package)
        } catch {
            await fireBillingPurchaseFailed(productId: productId, error: error)
            throw error
        }

        let product = package.storeProduct
        // SPEC-400 — fire onPurchaseCompleted to the host's
        // AppDNABillingDelegate. The PurchasesDelegate.receivedUpdated
        // callback below also fires for entitlement changes, but is
        // not 1:1 with purchases (it fires on restore + cross-device
        // sync too) and only emits an analytics event, never the
        // billing delegate. SPEC-400 single-source-of-truth: every
        // purchase produces exactly one onPurchaseCompleted call from
        // the bridge that drove it.
        // Nil → the key is omitted downstream (`PurchaseSuccessEvents.properties` skips an empty id) —
        // never the user id.
        let transactionId = storeTransaction?.transactionIdentifier ?? ""
        // RevenueCat's `StoreTransaction` does not expose StoreKit's environment; read the latest local
        // transaction of this product instead (was always "production").
        let environment = await StoreKitEnvironment.latest(for: product.productIdentifier) ?? StoreKitEnvironment.fallback
        let txInfo = TransactionInfo(
            transactionId: transactionId,
            productId: product.productIdentifier,
            purchaseDate: Date(),
            environment: environment
        )
        await MainActor.run {
            AppDNA.billingDelegate?.onPurchaseCompleted(productId: product.productIdentifier, transaction: txInfo)
        }

        return PurchaseResult(
            productId: product.productIdentifier,
            transactionId: transactionId,
            price: NSDecimalNumber(decimal: product.price).doubleValue,
            currency: product.currencyCode ?? "USD",
            provider: "revenuecat",
            // RC's `StoreProduct.subscriptionPeriod` is non-nil ONLY for an auto-renewing product — the
            // RC-model equivalent of StoreKit's `Product.subscription != nil`. `PaywallManager` reads
            // this off the result and emits `subscription_started` alongside `purchase_completed`, so RC
            // customers are covered by the same rule as the native store path.
            //
            // NOT emitted from `purchases(_:receivedUpdated:)` below: that callback fires on renewals,
            // restores and cross-device syncs too, so a `subscription_started` there would fire once per
            // renewal — an over-count on a METERED event, and the exact double-count
            // `SubscriptionStatusObserver` was written to avoid.
            isSubscription: product.subscriptionPeriod != nil,
            // SPEC-497 §13a.2 (C1, round-20 SDK minor 2). `isTrial` stays nil: `is_trial` is omitted for
            // RevenueCat purchases (R45).
            isConsumable: product.productType == .consumable,
            environment: environment
        )
    }

    func restore(appAccountToken: UUID?) async throws -> [String] {
        // RC restores against its own currently-logged-in appUserID (set via
        // `Purchases.logIn` during identify), so `appAccountToken` is not
        // applied here — RC's server-side binding is the source of truth.
        _ = appAccountToken
        let customerInfo = try await Purchases.shared.restorePurchases()
        let restoredIds = Array(customerInfo.entitlements.active.keys)
        // SPEC-400 — fire onRestoreCompleted.
        await MainActor.run {
            AppDNA.billingDelegate?.onRestoreCompleted(restoredProducts: restoredIds)
        }
        return restoredIds
    }

    /// SPEC-400 — single helper for the purchase-failure delegate fan-out.
    private func fireBillingPurchaseFailed(productId: String, error: Error) async {
        await MainActor.run {
            AppDNA.billingDelegate?.onPurchaseFailed(productId: productId, error: error)
        }
    }

    func getEntitlements(appAccountToken: UUID?) async -> [String] {
        _ = appAccountToken  // RC binds entitlements to its own appUserID
        guard let info = try? await Purchases.shared.customerInfo() else { return [] }
        return Array(info.entitlements.active.keys)
    }
}

extension RevenueCatBridge: PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        // 🔴 THIS LISTENER USED TO EMIT `purchase_completed` — ON EVERY DELIVERY WITH A LIVE
        // ENTITLEMENT. It was labelled "auto-track entitlement changes", but it did not track a
        // CHANGE: it fired whenever `active` was non-empty, and RevenueCat delivers `customerInfo` on
        // app launch, on every refresh, on restore, and on cross-device sync.
        //
        // So every launch of the app by an existing subscriber emitted a purchase that never happened.
        // `purchase_completed` is one of the three MTPU-metered events (`COUNT(DISTINCT user)`), which
        // means a subscriber who merely OPENED THE APP was counted as a transacting user — inflating
        // the customer's revenue reporting and our own metering, every month, for as long as they kept
        // the app installed. A real RC purchase is already emitted exactly once by the caller of
        // `bridge.purchase(...)` (`PaywallManager` / `AppDNA.billing.purchase()`), so this emit was
        // never the one carrying the signal — it was pure fabrication on top of it.
        //
        // The give-away was three lines below, and had been there all along: the LIFECYCLE call
        // deliberately diffs against a persisted snapshot precisely because "RC fires it on restore and
        // on cross-device sync too". The emit above it had no such guard.
        //
        // `check-purchase-emit-chokepoint.ts` now fails the build if a bridge emits a metered event.

        // 🔴 Subscription LIFECYCLE. RC's own listener is the right trigger — RC owns transaction
        // finishing, so `SubscriptionStatusObserver` runs in `.providerOwned` mode and never drains
        // `Transaction.updates`. This is the only callback RC gives us when subscriber state moves
        // (renewal, expiry, cross-device sync), and it is deliberately fired even when the entitlement
        // set is EMPTY: an expiry — the whole point of `subscription_canceled` /
        // `subscription_renewal_failed` — arrives exactly as an empty `active`.
        //
        // The observer diffs against its persisted snapshot, so a `receivedUpdated` that changed nothing
        // (RC fires it on restore and on cross-device sync too) emits nothing.
        AppDNA.reconcileSubscriptionState()
    }
}

enum RevenueCatError: LocalizedError {
    case productNotFound(String)

    var errorDescription: String? {
        switch self {
        case .productNotFound(let id): return "RevenueCat product not found: \(id)"
        }
    }
}

#else

/// Stub when RevenueCat is not available. Should never be instantiated at runtime
/// (AppDNA.swift falls back to StoreKit2Bridge).
final class RevenueCatBridge: BillingBridgeProtocol {
    private let eventTracker: EventTracker

    init(eventTracker: EventTracker) {
        self.eventTracker = eventTracker
        Log.warning("RevenueCat module not available — RevenueCatBridge is a no-op stub")
    }

    func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
        throw BillingError.providerNotAvailable("RevenueCat is not available. Install the RevenueCat SDK or use native StoreKit.")
    }

    func restore(appAccountToken: UUID?) async throws -> [String] {
        throw BillingError.providerNotAvailable("RevenueCat is not available. Install the RevenueCat SDK or use native StoreKit.")
    }

    func getEntitlements(appAccountToken: UUID?) async -> [String] {
        return []
    }
}

#endif
