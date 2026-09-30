import Foundation
import StoreKit

/// The StoreKit environment of a transaction, as the SDK reports it in `TransactionInfo.environment`.
///
/// Every bridge used to hard-code `"production"`, so a host could not tell a sandbox / TestFlight / Xcode
/// purchase from a real one — the one field on `TransactionInfo` meant for exactly that.
enum StoreKitEnvironment {
    /// The value used when the environment cannot be read (the field's long-standing default).
    static let fallback = "production"

    /// `"production"`, `"sandbox"` or `"xcode"` — the lowercased `AppStore.Environment` raw value.
    static func name(of transaction: Transaction) -> String {
        name(rawValue: transaction.environment.rawValue)
    }

    /// Pure mapping (pinned by tests): `Production` → `production`, `Sandbox` → `sandbox`,
    /// `Xcode` → `xcode`; anything new is lowercased; empty → the fallback.
    static func name(rawValue: String) -> String {
        let lowered = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.isEmpty ? fallback : lowered
    }

    /// For a provider bridge (RevenueCat / Adapty) whose purchase result does not expose StoreKit's
    /// transaction: the environment of the latest verified transaction for `productId`, read locally. Nil
    /// when StoreKit has none.
    static func latest(for productId: String) async -> String? {
        guard let result = await Transaction.latest(for: productId),
              case .verified(let transaction) = result else { return nil }
        return name(of: transaction)
    }
}

extension StoreKitEntitlementReader {
    /// The expiry StoreKit holds for each of `productIds`: the latest `expirationDate` among the verified,
    /// unrevoked `Transaction.currentEntitlements` of that product. A product without an expiry (a
    /// non-consumable, a lifetime unlock) has no key. Read-only; never finishes anything.
    static func expirations(for productIds: [String]) async -> [String: Date] {
        let wanted = Set(productIds)
        guard !wanted.isEmpty else { return [:] }
        var out: [String: Date] = [:]
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  wanted.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  let expiry = transaction.expirationDate else { continue }
            if let known = out[transaction.productID], known >= expiry { continue }
            out[transaction.productID] = expiry
        }
        return out
    }
}
