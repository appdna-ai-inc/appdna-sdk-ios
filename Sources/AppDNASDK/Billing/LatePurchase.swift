import Foundation
import StoreKit

// SPEC-497 §13a.2, D-R40-1(a) — iOS late purchases.
//
// Before: under `.storeKitOwned` the observer called `finish()` on every `Transaction.updates` item and
// emitted nothing. An interrupted purchase, an Ask-to-Buy approval or an offer-code redemption completing
// through `Transaction.updates` was therefore finished WITHOUT a `purchase_completed` and without
// `onPurchaseCompleted` — the host never granted what the user paid for.
//
// Now each update is classified by ONE pure predicate, `LatePurchaseFilter.decide`, and a reported one is
// written to the durable delivery queue (one UserDefaults write with the reported set), emitted, finished,
// and delivered by the drain.

/// The facts `LatePurchaseFilter.decide` needs, as plain values (the shared fixtures feed these; the
/// observer maps a real `Transaction` onto them).
struct TransactionFacts: Equatable {
    /// `purchased` | `familyShared`.
    let ownershipType: String
    let revocationDate: Date?
    let isUpgraded: Bool
    /// iOS 17+: `purchase` | `renewal`. Nil before iOS 17.
    let reason: String?
    /// `autoRenewable` | `nonRenewable` | `consumable` | `nonConsumable`.
    let productType: String
    let id: String
    let originalID: String
    /// The transaction's `appAccountToken` (SDK-derived or a host's custom one), or nil.
    let appAccountToken: UUID?
    /// The user the owner map says made the purchase that carried `appAccountToken`, or nil (unmapped).
    let ownerUserId: String?
    /// The current user's derived token (nil when anonymous).
    let currentToken: UUID?
    let currentUserId: String?
    /// The id is already in the reported set (the purchase path reported it).
    let alreadyReported: Bool
    let purchaseDate: Date
}

enum LateDecision: String, Equatable {
    /// Report now: persist (reported set + queue entry, one write) → emit → finish → drain.
    case report
    /// Tagged for ANOTHER user: persist an owner-tagged entry with the envelope, finish; emitted and
    /// delivered when that owner identifies.
    case deferToOwner
    /// Renewals, family-shared, upgraded, revoked, already-reported: finish and say nothing (today's
    /// behaviour for every update).
    case finishSilently
}

enum LatePurchaseFilter {

    /// SPEC-497 §13a.2 (R41–R51, R76). First match wins.
    static func decide(_ f: TransactionFacts) -> LateDecision {
        guard f.ownershipType == "purchased" else { return .finishSilently }   // family-shared
        guard f.revocationDate == nil else { return .finishSilently }
        guard !f.isUpgraded else { return .finishSilently }
        // A FIRST purchase only — renewals are never reported. iOS 17+ says so directly; before that a
        // renewal is an auto-renewable whose id differs from its original id. (Known, R42: a resubscribe
        // or crossgrade made outside the app is reported on 17+ and silent on 16.)
        if let reason = f.reason {
            guard reason == "purchase" else { return .finishSilently }
        } else {
            guard f.productType != "autoRenewable" || f.id == f.originalID else { return .finishSilently }
        }
        guard !f.alreadyReported else { return .finishSilently }

        // Whose purchase is it? (R49) nil token, the current user's token, or a (custom) token the owner
        // map attributes to the current user → report. A token the owner map attributes to ANOTHER user →
        // defer to that owner. An unmapped token → report, queued untagged.
        guard let token = f.appAccountToken else { return .report }
        if let current = f.currentToken, current == token { return .report }
        if let owner = f.ownerUserId {
            if let currentUser = f.currentUserId, currentUser == owner { return .report }
            return .deferToOwner
        }
        return .report
    }

    /// The queue entry's `ownerToken` (queue rule 4). `report` of the current user's token, or of a token
    /// mapped to the current user → the current user's DERIVED token (the one `EntitlementOwnerFilter`
    /// grants on); `deferToOwner` → the owner's derived token; nil or unmapped → untagged.
    static func ownerToken(for f: TransactionFacts, decision: LateDecision) -> UUID? {
        switch decision {
        case .finishSilently:
            return nil
        case .deferToOwner:
            return f.ownerUserId.flatMap { AppAccountTokenResolver.token(forUserId: $0) }
        case .report:
            guard let token = f.appAccountToken else { return nil }
            if let current = f.currentToken, current == token { return current }
            if let owner = f.ownerUserId, let currentUser = f.currentUserId, owner == currentUser {
                return f.currentToken ?? AppAccountTokenResolver.token(forUserId: currentUser)
            }
            return nil
        }
    }
}

extension TransactionFacts {
    /// Map a real StoreKit transaction onto the facts.
    init(
        transaction: Transaction,
        ownerUserId: String?,
        currentToken: UUID?,
        currentUserId: String?,
        alreadyReported: Bool
    ) {
        var reason: String?
        if #available(iOS 17.0, *) {
            reason = transaction.reason == .renewal ? "renewal" : "purchase"
        }
        self.init(
            ownershipType: transaction.ownershipType == .familyShared ? "familyShared" : "purchased",
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            reason: reason,
            productType: TransactionFacts.productTypeName(transaction.productType),
            id: String(transaction.id),
            originalID: String(transaction.originalID),
            appAccountToken: transaction.appAccountToken,
            ownerUserId: ownerUserId,
            currentToken: currentToken,
            currentUserId: currentUserId,
            alreadyReported: alreadyReported,
            purchaseDate: transaction.purchaseDate
        )
    }

    static func productTypeName(_ type: Product.ProductType) -> String {
        switch type {
        case .autoRenewable: return "autoRenewable"
        case .nonRenewable: return "nonRenewable"
        case .consumable: return "consumable"
        case .nonConsumable: return "nonConsumable"
        default: return "unknown"
        }
    }

    var purchasedAtMs: Int64 { Int64((purchaseDate.timeIntervalSince1970 * 1000).rounded()) }
}

/// What the late path reports for one transaction: the same `PurchaseResult` the purchase path builds,
/// so the envelope comes from the same `PurchaseSuccessEvents.properties`.
struct LateEnvelope {
    let result: PurchaseResult
    /// False when neither the transaction nor the product lookup gave a price: the envelope then OMITS
    /// `price` (and `currency`) rather than booking a fabricated 0 as revenue. A free trial is priced 0 by
    /// definition, so it is always known.
    var priceKnown: Bool = true

    /// `purchase_completed` properties: `paywall_id: ""` (no paywall), `emitted_by: "sdk"`, the charged
    /// price, `is_trial`, the ids, and `purchased_at_ms` (the event's `ts_ms` is the emit time; this
    /// carries the purchase time, Int64 epoch ms — R49).
    func properties(purchasedAtMs: Int64) -> [String: Any] {
        var props = PurchaseSuccessEvents.properties(paywallId: "", result: result, extra: ["purchased_at_ms": Int(purchasedAtMs)])
        if !priceKnown {
            props.removeValue(forKey: "price")
            props.removeValue(forKey: "currency")
        }
        return props
    }

    /// Build from the facts plus the price the store charged. `price` / `currency` nil = unknown (the
    /// transaction carried none and the product lookup failed) — omitted from the envelope, never 0.
    static func make(
        facts: TransactionFacts,
        productId: String,
        price: Double?,
        currency: String?,
        isTrial: Bool
    ) -> LateEnvelope {
        LateEnvelope(
            result: PurchaseResult(
                productId: productId,
                transactionId: facts.id,
                originalTransactionId: facts.originalID,
                price: price ?? 0,
                currency: currency ?? "",
                provider: "storekit2",
                isSubscription: facts.productType == "autoRenewable",
                isConsumable: facts.productType == "consumable",
                isTrial: isTrial
            ),
            priceKnown: isTrial || (price != nil && currency != nil)
        )
    }
}

/// One `Transaction.updates` item as the observer handles it (SPEC-497 §13a.2): its ids, whether it is
/// revoked, how to build its facts and envelope, and how to finish it. Production wraps a verified
/// StoreKit `Transaction` (`init(transaction:)`); a unit test cannot construct a `Transaction`, so it
/// passes plain values and a recording `finish` — and drives the REAL
/// `SubscriptionStatusObserver.handleOwnedUpdate(_:)`.
struct OwnedTransactionUpdate {
    let transactionId: String
    let productId: String
    let isRevoked: Bool
    let appAccountToken: UUID?
    let facts: (_ ownerUserId: String?, _ currentToken: UUID?, _ currentUserId: String?, _ alreadyReported: Bool) -> TransactionFacts
    let envelope: (TransactionFacts) async -> LateEnvelope
    let finish: () async -> Void
}

extension OwnedTransactionUpdate {
    init(transaction: Transaction) {
        self.init(
            transactionId: String(transaction.id),
            productId: transaction.productID,
            isRevoked: transaction.revocationDate != nil,
            appAccountToken: transaction.appAccountToken,
            facts: { owner, token, user, reported in
                TransactionFacts(
                    transaction: transaction,
                    ownerUserId: owner,
                    currentToken: token,
                    currentUserId: user,
                    alreadyReported: reported
                )
            },
            envelope: { facts in await OwnedTransactionUpdate.lateEnvelope(for: transaction, facts: facts) },
            // Called only by `SubscriptionStatusObserver.handleOwnedUpdate`, behind its
            // `mode == .storeKitOwned` guard (SPEC-497 §3.8).
            finish: { await transaction.finish() }
        )
    }

    /// The late path's envelope: the CHARGED price (`transaction.price` / `currency`, the product's only
    /// when nil) and the trial flag, from the same helpers the purchase path uses. When neither gives a
    /// price the envelope omits it (no fabricated 0).
    static func lateEnvelope(for transaction: Transaction, facts: TransactionFacts) async -> LateEnvelope {
        let product = try? await Product.products(for: [transaction.productID]).first
        var price: Double?
        if let productPrice = product?.price {
            price = chargedPrice(transactionPrice: transaction.price, productPrice: productPrice)
        } else if let transactionPrice = transaction.price {
            price = chargedPrice(transactionPrice: transactionPrice, productPrice: transactionPrice)
        }
        let currency = transaction.currency?.identifier ?? product?.priceFormatStyle.currencyCode
        return LateEnvelope.make(
            facts: facts,
            productId: transaction.productID,
            price: price,
            currency: currency,
            isTrial: TrialDetection.isFreeTrial(transaction: transaction, product: product)
        )
    }
}

/// The one seam the observer (production) and the `late_purchase` / `delivery_queue` fixtures drive:
/// decide → persist → emit. The caller finishes the transaction afterwards and then triggers the drain
/// (trigger (i)).
enum LatePurchaseProcessor {

    @discardableResult
    static func process(
        facts: TransactionFacts,
        queue: PurchaseDeliveryQueue,
        tracker: EventTracker?,
        envelope: () async -> LateEnvelope
    ) async -> LateDecision {
        let decision = LatePurchaseFilter.decide(facts)
        switch decision {
        case .finishSilently:
            return decision

        case .report:
            let env = await envelope()
            let props = env.properties(purchasedAtMs: facts.purchasedAtMs)
            let entry = PendingDelivery(
                transactionId: facts.id,
                productId: env.result.productId,
                purchaseTime: facts.purchasedAtMs,
                ownerToken: LatePurchaseFilter.ownerToken(for: facts, decision: decision)?.uuidString.lowercased(),
                emitPending: false,
                properties: nil,
                isSubscription: env.result.isSubscription
            )
            // Q1 — the reported set and the queue entry in ONE write, before the emit.
            await queue.recordReport(entry)
            if let tracker {
                PurchaseSuccessEvents.emit(tracker: tracker, properties: props, isSubscription: env.result.isSubscription)
            }
            return decision

        case .deferToOwner:
            let env = await envelope()
            let props = env.properties(purchasedAtMs: facts.purchasedAtMs)
            let entry = PendingDelivery(
                transactionId: facts.id,
                productId: env.result.productId,
                purchaseTime: facts.purchasedAtMs,
                ownerToken: LatePurchaseFilter.ownerToken(for: facts, decision: decision)?.uuidString.lowercased(),
                emitPending: true,
                properties: props.mapValues { AnyCodable($0) },
                isSubscription: env.result.isSubscription
            )
            // R46 (1) — persist first; the caller then finishes, so nothing stays unfinished (no StoreKit
            // re-delivery, no re-buy blocking, no cross-user misgrant).
            await queue.recordDeferred(entry)
            return decision
        }
    }
}

/// `Transaction.updates` as an injectable `AsyncStream` (the observer's default updates source). Kept out
/// of `SubscriptionStatusObserver.swift` so the only `finish()` calls in that file are transaction
/// finishes on the `.storeKitOwned` path (`check:billing-ownership`).
enum TransactionUpdatesSource {
    static func storeKit() -> AsyncStream<VerificationResult<Transaction>> {
        AsyncStream { continuation in
            let task = Task {
                for await update in Transaction.updates {
                    continuation.yield(update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
