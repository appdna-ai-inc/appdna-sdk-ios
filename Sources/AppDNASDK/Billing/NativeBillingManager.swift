import Foundation
import StoreKit

/// ServerEntitlement model returned from server verification.
public struct ServerEntitlement: Codable {
    public let productId: String
    public let store: String
    public let status: String
    public let expiresAt: String?
    public let isTrial: Bool
    public let offerType: String?
}

/// Result of a billing operation.
public enum BillingResult {
    case purchased(ServerEntitlement)
    case cancelled
    case pending
    case unknown
}

/// Errors from billing operations.
public enum BillingError: LocalizedError {
    case productNotFound(String)
    case verificationFailed
    case networkError(Error)
    case serverError(String)
    case providerNotAvailable(String)
    case userCancelled

    public var errorDescription: String? {
        switch self {
        case .productNotFound(let id): return "Product not found: \(id)"
        case .verificationFailed: return "Transaction verification failed"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .serverError(let msg): return "Server error: \(msg)"
        case .providerNotAvailable(let msg): return msg
        case .userCancelled: return "Purchase was cancelled"
        }
    }

    /// Stable, non-localized discriminator. `errorDescription` is a human string that changes with
    /// wording and locale, so a host (and every cross-platform wrapper, which only ever receives an
    /// untyped `Error` across the bridge) had no way to tell "user cancelled" from "card declined".
    public var errorType: String {
        switch self {
        case .productNotFound: return "productNotFound"
        case .verificationFailed: return "verificationFailed"
        case .networkError: return "networkError"
        case .serverError: return "serverError"
        case .providerNotAvailable: return "providerNotAvailable"
        case .userCancelled: return "userCancelled"
        }
    }
}

/// Map ANY billing error — `BillingError`, the active `StoreKit2Bridge`'s `StoreKit2Error`, a raw
/// `SKError`, RevenueCat's `purchaseCancelledError`, or a transport failure — onto the same discriminator vocabulary. Unrecognized errors
/// are "unknown" rather than being force-fit into a category the host would act on wrongly.
///
/// **Public** because it is the wrappers' only way to type a failure. React Native and Flutter receive
/// a plain `Error` across their bridge and can read nothing off it but a LOCALIZED message; without
/// this they rejected every purchase with one code and hosts string-matched English prose to tell a
/// user cancel from a declined card.
public func billingErrorType(_ error: Error) -> String {
    if let billingError = error as? BillingError {
        return billingError.errorType
    }
    if let skError = error as? StoreKit2Error {
        switch skError {
        case .productNotFound: return "productNotFound"
        case .userCancelled: return "userCancelled"
        // 🔴 "purchasePending" on iOS, "pending" on Android — the SAME condition, two discriminators,
        // in the one vocabulary whose entire purpose is not to fork. It reached `onPaywallPurchaseFailed
        // (errorType:)` and every wrapper. Android's name wins: it is the one the vocabulary was
        // documented with. (The `purchase_pending` EVENT name is unchanged.)
        case .purchasePending: return "pending"
        case .verificationFailed: return "verificationFailed"
        case .unknown: return "unknown"
        }
    }
    if let skError = error as? SKError, skError.code == .paymentCancelled {
        return "userCancelled"
    }
    // RevenueCat's `purchaseCancelledError` (the bridge maps it to `BillingError.userCancelled`; this
    // covers one that reaches a caller untranslated).
    if RevenueCatErrors.isPurchaseCancelled(error) {
        return "userCancelled"
    }
    if error is URLError {
        return "networkError"
    }
    return "unknown"
}

/// Product info from StoreKit.
public struct ProductInfo {
    public let id: String
    public let displayName: String
    public let description: String
    public let price: Decimal
    public let displayPrice: String
    public let subscription: SubscriptionInfo?
}

public struct SubscriptionInfo {
    public let period: Product.SubscriptionPeriod
    public let introOffer: Product.SubscriptionOffer?
    public let isEligibleForIntroOffer: Bool
}

// ────────────────────────────────────────────────────────────────────────────────────────────────
// The `NativeBillingManager` CLASS that used to live below this line has been DELETED.
//
// It was a decoy. It carried a `Transaction.updates` listener, `purchase_started` /
// `purchase_completed` / `purchase_canceled` / `purchase_pending` / `purchase_restored` emits, and
// server receipt verification — and it was NEVER INSTANTIATED. The live billing surface is
// `BillingModule.bridge` → `Integrations/StoreKit2Bridge` (wired in `AppDNA.configure`), which tracks
// nothing. So the file read as if iOS emitted a full purchase + subscription event family while the
// shipping SDK emitted only what `Paywalls/PaywallManager` emits — and `check:event-name-parity` went
// green off these dead callsites, which is precisely how iOS shipped with ZERO subscription-lifecycle
// events for as long as it did.
//
// What replaced it:
//   • subscription lifecycle → `Billing/SubscriptionStatusObserver.swift`, started from
//     `AppDNA.configure()` and stopped in `AppDNA.shutdown()` — on the live path.
//   • purchase / cancel / pending / failed → `Paywalls/PaywallManager.swift` (the only emitter).
//   • purchase execution + entitlements → `Integrations/StoreKit2Bridge.swift`.
//
// The types ABOVE (ServerEntitlement, BillingResult, BillingError, billingErrorType, ProductInfo,
// SubscriptionInfo) are live and used across the SDK — they stay.
// ────────────────────────────────────────────────────────────────────────────────────────────────
