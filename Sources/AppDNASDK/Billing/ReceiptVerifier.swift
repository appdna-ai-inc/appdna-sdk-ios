import Foundation

/// One `/billing/verify` reply item, or one `/billing/entitlements` subscription — the server's explicit
/// DTO (`{entitled, product_id, product_type, store, status, expires_at, is_trial, original_transaction_id,
/// consume}`), with the legacy `{entitled, subscription: {product_id, store, status, current_period_end,
/// offer_applied}}` shape of older servers still accepted. Every field is optional on the wire: a missing
/// key never fails the whole reply.
struct VerifyReplyItem: Decodable {
    let entitled: Bool?
    let product_id: String?
    let product_type: String?
    let store: String?
    let status: String?
    let expires_at: String?
    let current_period_end: String?
    let is_trial: Bool?
    let original_transaction_id: String?
    let consume: Bool?
    let offer_type: String?
    let offer_applied: OfferApplied?
    /// Legacy servers nest the row here.
    let subscription: Legacy?

    struct OfferApplied: Decodable {
        let offer_type: String?
    }

    struct Legacy: Decodable {
        let product_id: String?
        let store: String?
        let status: String?
        let current_period_end: String?
        let offer_applied: OfferApplied?
    }
}

/// The parsed reply, in the SDK's terms. Mirrors Android's `VerifiedPurchase`.
struct VerifiedPurchase: Equatable {
    let entitled: Bool
    let productId: String
    /// `"subs"` / `"inapp"`, or nil when an older server did not say.
    let productType: String?
    let store: String
    let status: String
    let expiresAt: String?
    let isTrial: Bool
    let originalTransactionId: String?
    let consume: Bool
    let offerType: String?

    var serverEntitlement: ServerEntitlement {
        ServerEntitlement(productId: productId, store: store, status: status,
                          expiresAt: expiresAt, isTrial: isTrial, offerType: offerType)
    }

    /// One reply item → `VerifiedPurchase` (the Android `ReceiptVerifier.parseItem` rules).
    static func parse(_ item: VerifyReplyItem) -> VerifiedPurchase {
        let legacy = item.subscription
        let status = legacy?.status ?? item.status ?? "unknown"
        let productType = item.product_type.flatMap { $0 == "subs" || $0 == "inapp" ? $0 : nil }
        return VerifiedPurchase(
            entitled: item.entitled ?? true,
            productId: legacy?.product_id ?? item.product_id ?? "",
            productType: productType,
            store: legacy?.store ?? item.store ?? "app_store",
            status: status,
            expiresAt: legacy?.current_period_end ?? item.expires_at ?? item.current_period_end,
            isTrial: item.is_trial ?? (status == "trialing"),
            originalTransactionId: item.original_transaction_id,
            consume: item.consume ?? false,
            offerType: legacy?.offer_applied?.offer_type ?? item.offer_applied?.offer_type ?? item.offer_type
        )
    }
}

/// `POST /billing/verify` reply: `{ data: <item> }`.
struct VerifyReply: Decodable {
    let data: VerifyReplyItem
}

/// `GET /billing/entitlements` reply: `{ data: { has_active_subscription, subscriptions: [<item>] } }`.
struct EntitlementsReply: Decodable {
    let data: DataBody

    struct DataBody: Decodable {
        let has_active_subscription: Bool?
        let subscriptions: [VerifyReplyItem]?
    }
}

/// The class of a failed verify — the same per-status rule as Android's `classifyVerifyStatus`:
/// `terminal` for 400, 403, 409, 422 and any other 4xx except 401 / 429 (never retried); `retryable` for
/// 401, 429, 5xx, a network error or an unreadable reply (retried later).
enum VerifyFailureClass: Equatable {
    case terminal
    case retryable

    static func classify(_ error: Error) -> VerifyFailureClass {
        guard let api = error as? APIError else { return .retryable }
        switch api {
        case .httpError(let status, _):
            if status == 401 || status == 429 { return .retryable }
            if (400..<500).contains(status) { return .terminal }
            return .retryable
        case .invalidURL, .compressionError:
            return .terminal
        case .networkError, .decodingError:
            return .retryable
        }
    }
}

/// Server-side verification of App Store purchases and the server's view of the user's entitlements.
///
/// - `POST /api/v1/billing/verify` — one StoreKit 2 transaction, sent as its signed JWS
///   (`VerificationResult.jwsRepresentation`). Driven by `PurchaseVerificationQueue`: never on the
///   purchase's critical path, and a failure never fails the purchase.
/// - `GET /api/v1/billing/entitlements?app_user_id=` — read by `BillingModule.refreshEntitlementCache`.
///
/// Every body carries `billing_owner` (LD-R4-1) and, when known, `product_type` and `app_user_id` — the
/// fields Android's `ReceiptVerifier` sends.
final class ReceiptVerifier {
    typealias Send = (Endpoint) async throws -> Data

    private let send: Send

    /// `send` performs one request and returns the 2xx body (throwing `APIError` otherwise).
    init(send: @escaping Send) {
        self.send = send
    }

    convenience init(apiClient: APIClient) {
        self.init(send: { endpoint in try await apiClient.requestData(endpoint) })
    }

    /// The request body of one verify (pure — pinned by tests).
    static func verifyBody(
        signedTransaction: String,
        productType: String?,
        billingOwner: String,
        appUserId: String?,
        paywallId: String? = nil,
        experimentId: String? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "platform": "ios",
            "transaction": signedTransaction,
            "billing_owner": billingOwner,
        ]
        if let productType { body["product_type"] = productType }
        if let paywallId { body["paywall_id"] = paywallId }
        if let experimentId { body["experiment_id"] = experimentId }
        // The server decodes `appAccountToken` from the JWS and compares it with the token derived from
        // this user (tagged + match → grant; tagged + mismatch → 403 unless no other user owns it;
        // untagged → grant and claim). Anonymous → no `app_user_id` (an unowned row).
        if let appUserId, !appUserId.isEmpty { body["app_user_id"] = appUserId }
        return body
    }

    /// Verify one transaction. Throws `APIError` (classify with `VerifyFailureClass.classify`).
    func verify(
        signedTransaction: String,
        productType: String?,
        billingOwner: String,
        appUserId: String?
    ) async throws -> VerifiedPurchase {
        let body = Self.verifyBody(
            signedTransaction: signedTransaction,
            productType: productType,
            billingOwner: billingOwner,
            appUserId: appUserId
        )
        let data = try await send(.verifyReceipt(body: body))
        do {
            return VerifiedPurchase.parse(try JSONDecoder().decode(VerifyReply.self, from: data).data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// The server's current entitlements for `appUserId`. Returns nil when the call failed (the caller
    /// then falls back to local StoreKit state); `[]` is a real "nothing active" answer.
    func fetchEntitlements(appUserId: String) async -> [ServerEntitlement]? {
        do {
            let data = try await send(.getEntitlements(appUserId: appUserId))
            let reply = try JSONDecoder().decode(EntitlementsReply.self, from: data)
            return (reply.data.subscriptions ?? []).map { VerifiedPurchase.parse($0) }
                .filter { !$0.productId.isEmpty && $0.entitled }
                .map(\.serverEntitlement)
        } catch {
            Log.debug("ReceiptVerifier: /billing/entitlements unavailable (\(error.localizedDescription)) — using local StoreKit state")
            return nil
        }
    }
}
