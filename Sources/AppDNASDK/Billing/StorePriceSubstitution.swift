import Foundation

/// What a plan's price label says: the STORE's price, or the one an author typed.
///
/// 🔴 Until #923 a paywall NEVER asked the store what a product costs. `price_display` was a
/// free-text field and the only thing a user ever saw, which meant a price change in App Store
/// Connect or Play Console did not reach the screen — the store charged the new price and the
/// paywall kept showing the old one. Proved on a simulator with a StoreKit configuration serving
/// `premium_monthly` at $4.49 while the screen read `AUTHORED-11.11`.
///
/// This is the decision both platforms make, per plan, once the store has answered (or failed to).
///
/// **The authored string is the FALLBACK, never gone.** A paywall that renders nothing because the
/// network is slow is worse than one showing a stale price, so every failure mode here lands on
/// what the author typed: no product id, a product the store does not know, a lookup that threw,
/// a lookup that timed out, an empty display price.
///
/// **Scope.** The PRICE, and only the price. The billing period stays authored (#913) and intro
/// offers stay unrendered, because both need localized words of OURS — the store localizes a
/// price, not the phrase "/month" — and that is a separate product decision (#933).
///
/// Mirrors Android `StorePriceSubstitution.kt`. Pinned on both by the shared fixture
/// `billing/store_price_substitution`.
enum StorePriceSubstitution {

    /// The outcome for one plan, and WHY — the reason is emitted with the paywall's render event so
    /// a customer asking "why does my paywall show the old price" has an answer in the data rather
    /// than in a guess.
    enum Source: String {
        /// The store answered and its price is what the screen shows.
        case store
        /// The author opted this plan out (`use_store_price: false`).
        case authoredByChoice = "authored_opt_out"
        /// The plan names no product, so there is nothing to ask the store about.
        case authoredNoProduct = "authored_no_product"
        /// The store was asked and did not know this product, or the lookup failed.
        case authoredLookupFailed = "authored_lookup_failed"
    }

    struct Outcome: Equatable {
        /// The string to render.
        let priceDisplay: String
        /// Where it came from.
        let source: String
    }

    /// - Parameters:
    ///   - authoredPrice: the plan's `price_display`, exactly as published.
    ///   - productId: the plan's `product_id`, or nil/empty when it names none.
    ///   - useStorePrice: the plan's `use_store_price`; nil means the default, which is TRUE.
    ///   - storePrice: the store's localized `displayPrice` for that product, or nil when the
    ///     lookup failed, timed out, or returned no such product.
    static func resolve(
        authoredPrice: String?,
        productId: String?,
        useStorePrice: Bool?,
        storePrice: String?
    ) -> Outcome {
        let authored = authoredPrice ?? ""

        if useStorePrice == false {
            return Outcome(priceDisplay: authored, source: Source.authoredByChoice.rawValue)
        }
        guard let id = productId, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Outcome(priceDisplay: authored, source: Source.authoredNoProduct.rawValue)
        }
        guard let store = storePrice, !store.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Outcome(priceDisplay: authored, source: Source.authoredLookupFailed.rawValue)
        }
        return Outcome(priceDisplay: store, source: Source.store.rawValue)
    }
}
