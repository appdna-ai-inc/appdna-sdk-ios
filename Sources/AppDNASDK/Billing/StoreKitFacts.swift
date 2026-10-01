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
    /// when StoreKit has none. (`Transaction.latest(for:)` + `Transaction.environment`: compiled in the SDK
    /// target and, beside the RevenueCat bridge, in a scratch package against RevenueCat 4.44.3 / 5.92.0;
    /// `AppStore.Environment` needs iOS 16, the SDK's floor.)
    static func latest(for productId: String) async -> String? {
        guard let result = await Transaction.latest(for: productId),
              case .verified(let transaction) = result else { return nil }
        return name(of: transaction)
    }
}

extension StoreKitEntitlementReader {
    /// One `Transaction.currentEntitlements` entry, as `expirations` reads it (pure, so it is tested).
    struct ExpiryFact {
        let productId: String
        let appAccountToken: UUID?
        let revoked: Bool
        let expirationDate: Date?
    }

    /// The expiry StoreKit holds for each of `productIds`: the latest `expirationDate` among the verified,
    /// unrevoked `Transaction.currentEntitlements` of that product that BELONG to the current user — the
    /// same `EntitlementOwnerFilter` as `productIds(appAccountToken:)`, so another user's transaction of
    /// the same product can never lend its expiry. A product without an expiry (a non-consumable, a
    /// lifetime unlock) has no key. Read-only; never finishes anything.
    static func expirations(for productIds: [String], appAccountToken: UUID?) async -> [String: Date] {
        guard !productIds.isEmpty else { return [:] }
        var facts: [ExpiryFact] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            facts.append(ExpiryFact(productId: transaction.productID, appAccountToken: transaction.appAccountToken,
                                    revoked: transaction.revocationDate != nil, expirationDate: transaction.expirationDate))
        }
        return expirations(of: facts, for: productIds, appAccountToken: appAccountToken,
                           firstIdentifiedToken: AppAccountTokenResolver.firstIdentifiedToken())
    }

    /// Pure core of `expirations(for:appAccountToken:)`.
    static func expirations(
        of facts: [ExpiryFact],
        for productIds: [String],
        appAccountToken: UUID?,
        firstIdentifiedToken: UUID?
    ) -> [String: Date] {
        let wanted = Set(productIds)
        var out: [String: Date] = [:]
        for fact in facts {
            guard wanted.contains(fact.productId), !fact.revoked, let expiry = fact.expirationDate else { continue }
            switch EntitlementOwnerFilter.decide(transactionToken: fact.appAccountToken, expectedToken: appAccountToken,
                                                 firstIdentifiedToken: firstIdentifiedToken) {
            case .grant, .grantAnonymousPolicy, .grantUntaggedMigration: break
            case .denyOtherUser, .denyUntaggedOtherUser: continue
            }
            if let known = out[fact.productId], known >= expiry { continue }
            out[fact.productId] = expiry
        }
        return out
    }
}
