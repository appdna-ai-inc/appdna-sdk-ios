import Foundation
import StoreKit

/// The bridge for a provider that owns billing but is NOT linked into this build
/// (RevenueCat or Adapty on every published channel).
///
/// Before this, `.revenueCat` without RevenueCat linked silently built a `StoreKit2Bridge`: the SDK's
/// paywall bought through StoreKit directly and the subscription observer finished every transaction
/// RevenueCat was about to process. Now:
///   - `purchase` and `restore` throw `BillingError.providerNotAvailable` WITHOUT calling StoreKit — the
///     host buys and restores through its own provider SDK (documented recipe: catch
///     `onPaywallPurchaseFailed(errorType: "providerNotAvailable")` and call the provider).
///   - `getEntitlements` reads `Transaction.currentEntitlements` exactly as `StoreKit2Bridge` does (same
///     `EntitlementOwnerFilter`), read-only: nothing here ever calls `finish()`.
///   - Product metadata (`Product.products(for:)`, used for paywall prices) is not a bridge concern and
///     stays available.
///
/// A bridge never emits the metered purchase events (`check-purchase-emit-chokepoint.ts`): the caller
/// emits `purchase_failed`.
final class ExternalProviderBridge: BillingBridgeProtocol {

    enum Provider: String {
        case revenueCat
        case adapty

        var displayName: String {
            switch self {
            case .revenueCat: return "RevenueCat"
            case .adapty: return "Adapty"
            }
        }
    }

    let provider: Provider

    init(provider: Provider) {
        self.provider = provider
    }

    /// The error every refused call throws.
    var refusal: BillingError {
        .providerNotAvailable("\(provider.displayName): purchases are made by \(provider.displayName) in your app")
    }

    func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
        _ = appAccountToken
        let error = refusal
        // Parity: every bridge reports its failures to the billing delegate.
        await MainActor.run {
            AppDNA.billingDelegate?.onPurchaseFailed(productId: productId, error: error)
        }
        throw error
    }

    func restore(appAccountToken: UUID?) async throws -> [String] {
        _ = appAccountToken
        // `AppStore.sync()` is deliberately NOT called: restoring is the provider's job.
        throw refusal
    }

    func getEntitlements(appAccountToken: UUID?) async -> [String] {
        await StoreKitEntitlementReader.productIds(appAccountToken: appAccountToken, label: "ExternalProviderBridge")
    }
}

/// The read-only `Transaction.currentEntitlements` pass shared by `StoreKit2Bridge` and
/// `ExternalProviderBridge`. Never finishes anything.
enum StoreKitEntitlementReader {
    static func productIds(appAccountToken: UUID?, label: String) async -> [String] {
        var entitlements: [String] = []
        // Resolve the first-identifier anchor once, so the decision matrix sees a stable value even if
        // the host identifies a different user mid-iteration.
        let firstIdentifier = AppAccountTokenResolver.firstIdentifiedToken()

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            switch EntitlementOwnerFilter.decide(
                transactionToken: transaction.appAccountToken,
                expectedToken: appAccountToken,
                firstIdentifiedToken: firstIdentifier
            ) {
            case .grant, .grantAnonymousPolicy, .grantUntaggedMigration:
                entitlements.append(transaction.productID)
            case .denyOtherUser:
                Log.warning("\(label).getEntitlements: skipped transaction \(transaction.id) — appAccountToken does not match the current user.")
            case .denyUntaggedOtherUser:
                Log.warning("\(label).getEntitlements: skipped untagged transaction \(transaction.id) — the current user is not the device's first-identifier, so the untagged history is not inherited (cross-account leak guard).")
            }
        }
        return entitlements
    }
}
