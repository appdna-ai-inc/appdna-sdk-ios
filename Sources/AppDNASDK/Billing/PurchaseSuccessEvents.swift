import Foundation
import StoreKit

/// The ONE place a *successful purchase* becomes analytics on iOS.
///
/// 🔴 **`subscription_started` was a metered event that no SDK emitted.**
/// `BigQueryBillingService` meters MTPU over
/// `event_name IN ('purchase_completed', 'subscription_started', 'subscription_renewed')` — iOS,
/// Android, Flutter and RN had ZERO emit sites for the middle one. The only production rows carrying
/// that name were seeded demo data. Nothing downstream could separate a NEW SUBSCRIPTION from a
/// one-off / consumable / lifetime purchase, so every subscription funnel built on it was fiction.
///
/// The rule, and it is the whole reason this type exists:
///   - EVERY successful purchase emits `purchase_completed` (unchanged — this is additive).
///   - A purchase of an AUTO-RENEWING product ALSO emits `subscription_started`, once, with the SAME
///     property envelope.
///   - A one-off product emits `purchase_completed` and nothing else.
///
/// `subscription_started` is a PURCHASE-TIME event. It is deliberately NOT emitted from
/// `SubscriptionStatusObserver`: that class owns the renewal/reconcile diff, and a product that is new
/// to its snapshot is explicitly not its business ("that is `purchase_completed`'s job — emitting here
/// too is how you get the double-count Android had on its purchase events"). Emitting here as well
/// would double-count the first pass after every purchase — on the single most-metered event family.
enum PurchaseSuccessEvents {

    /// The property envelope shared by `purchase_completed` and `subscription_started`.
    ///
    /// Byte-identical between the two events on purpose: a funnel that joins them on `product_id` /
    /// `paywall_id` / `experiment_id` must not have to special-case one of them. Property names are the
    /// ones `purchase_completed` already shipped (`paywall_id`, `product_id`, `price`, `currency`,
    /// `provider`) — this builder is a *reuse* of that shape, not a new one.
    static func properties(
        paywallId: String?,
        result: PurchaseResult,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var props: [String: Any] = [
            "product_id": result.productId,
            // SPEC-497 §13a.2 (R42–R46) — a free trial is not revenue: price 0 when `isTrial` is true.
            // Otherwise the bridge's price, which on `storeKit2` is the CHARGED price
            // (`chargedPrice(transactionPrice:productPrice:)`).
            "price": result.isTrial == true ? 0.0 : result.price,
            "currency": result.currency,
            "provider": result.provider,
            // SPEC-497 §13a.2 (C1) — additive, both platforms.
            "is_consumable": result.isConsumable,
        ]
        // Round-34 — emit transaction_id (Android includes purchase.orderId). A dashboard de-duping by
        // transaction_id dropped every iOS row.
        // A synthetic id (`adapty:<uuid>`, impl audit round 2 I3) is for the host's idempotent grant only:
        // it names no store transaction, so it is never a §13e.5 dedupe key — the key is omitted, as for
        // an unknown id (rule 1: NULL for empty).
        if !result.transactionId.isEmpty, !SyntheticTransactionId.isSynthetic(result.transactionId) {
            props["transaction_id"] = result.transactionId
        }
        if let original = result.originalTransactionId, !original.isEmpty {
            props["original_transaction_id"] = original
        }
        // SPEC-497 §13a.2 (R42/R45) — `is_trial` only when the bridge knows (always a Bool on
        // `storeKit2`; the RevenueCat / Adapty bridges leave it nil and the key is omitted).
        if let isTrial = result.isTrial {
            props["is_trial"] = isTrial
        }
        // Omitted rather than fabricated on the non-paywall paths (a direct/host-driven purchase has no
        // paywall), matching what those call sites emitted before. The late path passes "" (no paywall).
        if let paywallId {
            props["paywall_id"] = paywallId
        }
        for (key, value) in extra {
            props[key] = value
        }
        // SPEC-497 §11.9 — the SDK-device marker revenue dedupe keys on.
        return BillingEventProps.marked(props)
    }

    /// Emit `purchase_completed` and — only for an auto-renewing product — `subscription_started`.
    ///
    /// Exactly one of each, from the one site that observed the purchase.
    static func emit(
        tracker: EventTracker,
        paywallId: String?,
        result: PurchaseResult,
        extra: [String: Any] = [:]
    ) {
        emit(
            tracker: tracker,
            properties: properties(paywallId: paywallId, result: result, extra: extra),
            isSubscription: result.isSubscription
        )
    }

    /// The same emit from a STORED envelope — the delivery queue's deferred emit (SPEC-497 §13a.2,
    /// `deferToOwner`): the properties were computed when the transaction arrived, the events go out when
    /// its owner identifies.
    static func emit(tracker: EventTracker, properties: [String: Any], isSubscription: Bool) {
        let props = BillingEventProps.marked(properties)
        tracker.track(event: "purchase_completed", properties: props)
        guard isSubscription else { return }
        tracker.track(event: "subscription_started", properties: props)
    }

    /// SPEC-497 §13a.2 (R40/R41) — a re-buy of an owned non-consumable / subscription
    /// (`PurchaseResult.alreadyOwned`) books NO revenue: its caller emits this — one
    /// `purchase_restored{reason: "item_already_owned"}` with no price or currency — INSTEAD of `emit`.
    static func emitAlreadyOwned(tracker: EventTracker, paywallId: String?, result: PurchaseResult) {
        var props: [String: Any] = [
            "product_id": result.productId,
            "reason": "item_already_owned",
        ]
        if !result.transactionId.isEmpty, !SyntheticTransactionId.isSynthetic(result.transactionId) {
            props["transaction_id"] = result.transactionId
        }
        if let paywallId { props["paywall_id"] = paywallId }
        tracker.track(event: "purchase_restored", properties: BillingEventProps.marked(props))
    }

    /// SPEC-497 §13a.2 (C1) — is this product a consumable? Same best-effort StoreKit lookup as
    /// `isAutoRenewable`; a failed lookup answers `false`.
    static func isConsumable(productId: String) async -> Bool {
        guard let product = try? await Product.products(for: [productId]).first else { return false }
        return product.type == .consumable
    }

    static func isAutoRenewable(productId: String) async -> Bool {
        guard let product = try? await Product.products(for: [productId]).first else {
            Log.warning("PurchaseSuccessEvents: product lookup failed for \(productId) — treating as non-subscription for subscription_started")
            return false
        }
        return product.subscription != nil
    }
}

/// SPEC-497 impl audit round 2 (I3) — the transaction id of a purchase whose provider reported none.
///
/// `PurchaseResult.transactionId` and `TransactionInfo.transactionId` are non-optional, and the docs tell
/// a host to grant idempotently BY `transactionId`. An empty string made every such purchase share one id,
/// so a host's dedupe swallowed the second one. The id is instead unique per purchase and clearly marked
/// as not a store id — `<provider>:<lowercased UUID>`, e.g. `adapty:6f1c…` — so it cannot collide with a
/// real one (Apple's are digits). It never reaches analytics: `PurchaseSuccessEvents` omits a synthetic
/// id, so §13e.5 dedupe sees the same NULL key as an unknown id (a made-up key would match no provider row).
enum SyntheticTransactionId {
    static let providers: Set<String> = ["adapty"]

    static func make(provider: String) -> String {
        "\(provider):\(UUID().uuidString.lowercased())"
    }

    static func isSynthetic(_ id: String) -> Bool {
        guard let colon = id.firstIndex(of: ":") else { return false }
        return providers.contains(String(id[..<colon]))
    }
}
