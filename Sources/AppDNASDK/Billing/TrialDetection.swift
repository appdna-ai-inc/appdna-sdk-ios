import Foundation
import StoreKit

// SPEC-497 §13a.2 (R42–R47, R64, R76) — is a purchase a free trial, and what was actually charged.
//
// Before: iOS `purchase_completed` carried the product's full list price and no `is_trial`, so every
// free-trial start was booked as revenue at full price. Now a trial reports `is_trial: true` and price 0,
// and every other purchase reports the price the store actually charged (the intro price for a paid
// intro) — on the purchase path and the late path alike.

/// The facts `TrialDetection` decides on. Plain strings so the shared fixtures can feed them.
struct TrialFacts: Equatable {
    /// The transaction's offer type: `introductory` | `promotional` | `code` | `winBack` | nil.
    let offerType: String?
    /// The offer's payment mode (17.2 offer API): `freeTrial` | `payAsYouGo` | `payUpFront` | nil.
    let offerPaymentMode: String?
    /// The product's introductory-offer payment mode (legacy path).
    let introPaymentMode: String?
    /// Whether the iOS 17.2 `Transaction.offer` API supplied the facts.
    let usesOfferAPI: Bool
}

enum TrialDetection {

    private static let trialOfferTypes: Set<String> = ["introductory", "promotional", "code", "winBack"]

    /// The one pure rule, called by the purchase path and the late observer.
    ///
    /// - 17.2 offer API: any introductory / promotional / offer-code / win-back offer whose payment mode
    ///   is `freeTrial` (a promotional free trial counts, matching Play's `offerPhase`).
    /// - Legacy (before 17.2): an introductory offer whose product intro payment mode is `freeTrial`.
    ///   Known: a promotional free trial before 17.2 is not detected.
    static func isFreeTrial(_ f: TrialFacts) -> Bool {
        if f.usesOfferAPI {
            guard let type = f.offerType, trialOfferTypes.contains(type) else { return false }
            return f.offerPaymentMode == "freeTrial"
        }
        return f.offerType == "introductory" && f.introPaymentMode == "freeTrial"
    }

    /// The StoreKit overload: map the real types onto `TrialFacts`, then decide.
    static func isFreeTrial(transaction: Transaction, product: Product?) -> Bool {
        isFreeTrial(facts(transaction: transaction, product: product))
    }

    static func facts(transaction: Transaction, product: Product?) -> TrialFacts {
        let introMode = product?.subscription?.introductoryOffer.map { paymentModeName($0.paymentMode) } ?? nil
        #if compiler(>=5.9.2)
        if #available(iOS 17.2, *) {
            return TrialFacts(
                offerType: transaction.offer.flatMap { offerTypeName($0.type) },
                offerPaymentMode: transaction.offer?.paymentMode.flatMap { offerPaymentModeName($0) },
                introPaymentMode: introMode,
                usesOfferAPI: true
            )
        }
        #endif
        return TrialFacts(
            offerType: legacyOfferType(transaction),
            offerPaymentMode: nil,
            introPaymentMode: introMode,
            usesOfferAPI: false
        )
    }

    // MARK: - StoreKit → strings

    static func offerTypeName(_ type: Transaction.OfferType) -> String? {
        if type == .introductory { return "introductory" }
        if type == .promotional { return "promotional" }
        if type == .code { return "code" }
        #if compiler(>=6.0)
        if #available(iOS 18.0, *), type == .winBack { return "winBack" }
        #endif
        return nil
    }

    #if compiler(>=5.9.2)
    @available(iOS 17.2, *)
    static func offerPaymentModeName(_ mode: Transaction.Offer.PaymentMode) -> String? {
        if mode == .freeTrial { return "freeTrial" }
        if mode == .payAsYouGo { return "payAsYouGo" }
        if mode == .payUpFront { return "payUpFront" }
        return nil
    }
    #endif

    static func paymentModeName(_ mode: Product.SubscriptionOffer.PaymentMode) -> String? {
        if mode == .freeTrial { return "freeTrial" }
        if mode == .payAsYouGo { return "payAsYouGo" }
        if mode == .payUpFront { return "payUpFront" }
        return nil
    }

    /// Pre-17.2: `Transaction.offerType` (deprecated in 17.2, which is exactly why it is only read here).
    private static func legacyOfferType(_ transaction: Transaction) -> String? {
        transaction.offerType.flatMap { offerTypeName($0) }
    }
}

/// SPEC-497 §13a.2 (R46, R64) — the reported price is what the store CHARGED: `transaction.price` when
/// StoreKit has it (the intro price for a paid intro, 0 for a free trial), the product's list price only
/// when it is nil. Used by `StoreKit2Bridge` and the late path.
func chargedPrice(transactionPrice: Decimal?, productPrice: Decimal) -> Double {
    // Through the decimal STRING: `NSDecimalNumber.doubleValue` turns 2.99 into 2.9899999999999998.
    let number = NSDecimalNumber(decimal: transactionPrice ?? productPrice)
    return Double(number.stringValue) ?? number.doubleValue
}
