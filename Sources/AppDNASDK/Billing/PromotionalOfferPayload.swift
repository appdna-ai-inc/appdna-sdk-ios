import Foundation

/// Payload for a signed promotional offer (signed by your own server — AppDNA does not sign offers).
///
/// Not applied: `AppDNA.billing.purchase(_:options:)` does not pass it to StoreKit, so a purchase made with it is
/// a purchase at the regular price. Kept for source compatibility with `PurchaseOptions`.
public struct PromotionalOfferPayload: Codable {
    public let offerId: String
    public let keyId: String
    public let nonce: String
    public let timestamp: Int
    public let signature: String
}
