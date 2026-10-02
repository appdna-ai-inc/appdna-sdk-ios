import Foundation

// SPEC-497 §3.2 (A1) — who owns a store transaction, decided ONCE.
//
// The defect this retires: the observer's mode used to be derived from the bridge that got BUILT
// (`bridge is StoreKit2Bridge`). A host that asked for RevenueCat without linking it got the
// StoreKit2Bridge fallback, and the observer then finished every `Transaction.updates` item —
// renewals, Ask-to-Buy approvals, offer codes — out from under RevenueCat. Everything below is decided
// from the REQUESTED provider instead, by one pure function that production and the shared fixtures
// both call.

/// What the SDK's subscription observer does under a provider. On Android the same three names describe
/// the reconcile mode (verify/acknowledge vs read-only vs no billing) — the fixtures assert one value for
/// both platforms.
enum BillingObserverMode: String, Equatable {
    /// `storeKit2`: the SDK owns transactions — it drains `Transaction.updates` and finishes them.
    case storeKitOwned
    /// A non-owning provider (RevenueCat / Adapty): read-only reconcile; never drains updates, never
    /// finishes.
    case providerOwned
    /// `none`: no billing, no observer.
    case none

    /// The observer mode to construct, or nil when no observer runs.
    var subscriptionObserverMode: SubscriptionObserverMode? {
        switch self {
        case .storeKitOwned: return .storeKitOwned
        case .providerOwned: return .providerOwned
        case .none: return nil
        }
    }
}

/// The ownership table of SPEC-497 §3.2, one row per provider.
struct BillingOwnershipPolicy: Equatable {
    /// The SDK finishes (iOS) / acknowledges (Android) transactions. Only `storeKit2`.
    let ownsTransactions: Bool
    /// The SDK can start a purchase itself (StoreKit, or a LINKED provider SDK).
    let sdkCanPurchase: Bool
    /// The SDK can restore itself.
    let sdkCanRestore: Bool
    let observerMode: BillingObserverMode
    /// Device-side `subscription_renewed` / `_canceled` / `_renewal_failed` (owner Q2, LD-R10-1).
    let emitsLifecycleEvents: Bool
    /// The wire name of the requested provider (`storeKit2`, `revenueCat`, `adapty`, `none`).
    let provider: String
    /// RevenueCat's or Adapty's own SDK is compiled into this build and answers entitlements
    /// (`RevenueCatBridge` / `AdaptyBridge` — source builds only; published channels link neither).
    /// False for `storeKit2`, `none`, and an unlinked provider (`ExternalProviderBridge`).
    let providerSDKLinked: Bool

    /// The SDK's entitlement read is the device's StoreKit set (`Transaction.currentEntitlements`):
    /// `storeKit2` (`StoreKit2Bridge`), or RevenueCat / Adapty whose SDK is NOT linked into this build
    /// (`ExternalProviderBridge`, every published channel). False when a linked provider SDK answers
    /// (`RevenueCatBridge` / `AdaptyBridge`, source builds only) and for `none`.
    var sdkReadsStoreKitEntitlements: Bool {
        switch provider {
        case "storeKit2": return true
        case "revenueCat", "adapty": return !providerSDKLinked
        default: return false
        }
    }

    /// The message a refused purchase or restore carries (§3.2 rule 2, §3.3).
    var refusalMessage: String {
        switch provider {
        case "revenueCat": return "RevenueCat: purchases are made by RevenueCat in your app"
        case "adapty": return "Adapty: purchases are made by Adapty in your app"
        default: return "No billing provider configured"
        }
    }
}

enum BillingOwnership {

    /// SPEC-497 §3.2 — the whole ownership table.
    ///
    /// | provider              | owns | purchase/restore | observer      | lifecycle events |
    /// |-----------------------|------|------------------|---------------|------------------|
    /// | storeKit2             | yes  | yes / yes        | storeKitOwned | yes              |
    /// | revenueCat, unlinked  | no   | no / no          | providerOwned | no  (owner Q2)   |
    /// | revenueCat, linked    | no   | yes / yes        | providerOwned | no  (owner Q2)   |
    /// | adapty, linked        | no   | no / yes         | providerOwned | yes (LD-R10-1)   |
    /// | adapty, unlinked      | no   | no / no          | providerOwned | yes (LD-R10-1)   |
    /// | none                  | no   | no / no          | none          | no               |
    static func policy(for provider: BillingProvider, bridgeLinked: Bool) -> BillingOwnershipPolicy {
        switch provider {
        case .storeKit2:
            return BillingOwnershipPolicy(
                ownsTransactions: true, sdkCanPurchase: true, sdkCanRestore: true,
                observerMode: .storeKitOwned, emitsLifecycleEvents: true, provider: provider.type,
                providerSDKLinked: false
            )
        case .revenueCat:
            return BillingOwnershipPolicy(
                ownsTransactions: false, sdkCanPurchase: bridgeLinked, sdkCanRestore: bridgeLinked,
                observerMode: .providerOwned, emitsLifecycleEvents: false, provider: provider.type,
                providerSDKLinked: bridgeLinked
            )
        case .adapty:
            // No purchase even when Adapty is linked: Adapty (2.x and 3.x) buys only an
            // `AdaptyPaywallProduct` from its own paywall, never a product id — see `AdaptyBridge.purchase`.
            // Restore goes through `Adapty.restorePurchases()`.
            return BillingOwnershipPolicy(
                ownsTransactions: false, sdkCanPurchase: false, sdkCanRestore: bridgeLinked,
                observerMode: .providerOwned, emitsLifecycleEvents: true, provider: provider.type,
                providerSDKLinked: bridgeLinked
            )
        case .none:
            return BillingOwnershipPolicy(
                ownsTransactions: false, sdkCanPurchase: false, sdkCanRestore: false,
                observerMode: .none, emitsLifecycleEvents: false, provider: provider.type,
                providerSDKLinked: false
            )
        }
    }

    /// The policy of a configured SDK whose billing is unavailable (`none`, or a billing init failure).
    static var unavailable: BillingOwnershipPolicy { policy(for: BillingProvider.none, bridgeLinked: false) }

    /// Is the provider's own SDK compiled into this build? Published channels link neither
    /// (`Package.swift`: both are commented out; the podspec declares neither).
    ///
    /// 🔴 `canImport` alone is not a link decision. Under Swift Package Manager every package module
    /// lands in one build-products directory, so a host app that adds `purchases-ios` made
    /// `canImport(RevenueCat)` TRUE inside AppDNASDK (proved on an Xcode 26 SPM host, twice) — the
    /// RevenueCat bridge was compiled in and the SDK bought through RevenueCat, against the docs and
    /// unlike CocoaPods; with Adapty the same build left `canImport(Adapty)` false. Whether a module is
    /// visible depends on build order, so it is not a contract. A provider is linked only when the
    /// build defines `APPDNA_LINK_REVENUECAT` / `APPDNA_LINK_ADAPTY` (a source build that also adds the
    /// dependency — see `Package.swift`) AND the module imports.
    static func isLinked(_ provider: BillingProvider) -> Bool {
        switch provider {
        case .storeKit2: return true
        case .none: return false
        case .revenueCat:
            #if APPDNA_LINK_REVENUECAT && canImport(RevenueCat)
            return true
            #else
            return false
            #endif
        case .adapty:
            #if APPDNA_LINK_ADAPTY && canImport(Adapty)
            return true
            #else
            return false
            #endif
        }
    }
}

extension BillingOwnership {
    /// The bridge production builds for a requested provider — `configure` and the shared fixtures call
    /// this one function (SPEC-497 §3.9: "runners drive production code").
    static func makeBridge(for provider: BillingProvider, tracker: EventTracker) -> BillingBridgeProtocol? {
        switch provider {
        case .storeKit2:
            return StoreKit2Bridge()
        case .revenueCat:
            #if APPDNA_LINK_REVENUECAT && canImport(RevenueCat)
            return RevenueCatBridge(eventTracker: tracker)
            #else
            Log.warning("RevenueCat is not linked into this build — the SDK will not buy or restore; purchases are made by RevenueCat in your app (onPaywallPurchaseFailed errorType providerNotAvailable).")
            return ExternalProviderBridge(provider: .revenueCat)
            #endif
        case .adapty(let adaptyKey):
            #if APPDNA_LINK_ADAPTY && canImport(Adapty)
            return AdaptyBridge(apiKey: adaptyKey, eventTracker: tracker)
            #else
            _ = adaptyKey
            Log.warning("Adapty is not linked into this build — the SDK will not buy or restore; purchases are made by Adapty in your app (onPaywallPurchaseFailed errorType providerNotAvailable).")
            return ExternalProviderBridge(provider: .adapty)
            #endif
        case .none:
            return nil
        }
    }
}

/// SPEC-497 §11.9 — the marker that tells revenue dedupe an SDK-device row from a host-tracked one.
/// Every internal billing emitter adds it through this one helper; the public `AppDNA.track` strips it
/// (and the server-only `_appdna_origin`) so a host cannot forge it.
enum BillingEventProps {
    static let emittedByKey = "emitted_by"
    static let originKey = "_appdna_origin"

    static func marked(_ properties: [String: Any]) -> [String: Any] {
        var out = properties
        out[emittedByKey] = "sdk"
        return out
    }

    /// The public-`track` strip. Nil stays nil; an empty result stays an (empty) dictionary.
    static func strippingReservedKeys(_ properties: [String: Any]?) -> [String: Any]? {
        guard var props = properties else { return nil }
        props.removeValue(forKey: emittedByKey)
        props.removeValue(forKey: originKey)
        return props
    }
}
