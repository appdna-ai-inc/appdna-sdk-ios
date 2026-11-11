import Foundation
import StoreKit

/// Asks the App Store what a paywall's products cost, bounded, and never fails.
///
/// The renderer's door to StoreKit. `PriceResolver` could already do this and had ZERO
/// callers; `StoreKit2Bridge.loadProducts` sits inside `purchase(...)`, long after the screen has
/// been drawn. So a paywall showed whatever an author typed, and a price change in App Store
/// Connect never reached it.
///
/// 🔴 THE COMPLETION ALWAYS RUNS, exactly once, on a bounded deadline. A paywall that waits on a
/// slow network is worse than one showing a stale price, so a lookup that throws, that returns
/// nothing, or that outlives `timeout` lands on an empty map — and every plan then falls back to
/// its authored `price_display` through `StorePriceSubstitution`. The deadline is a timer
/// INDEPENDENT of the call, the same shape `handleStepAppear` uses for the host-data hook: a
/// StoreKit request that never returns cannot hold the screen.
///
/// Queried for DISPLAY only, and so it runs whoever owns transactions — a RevenueCat or Adapty
/// paywall still names App Store product ids, and reading their prices does not touch the purchase
/// path or `BillingOwnership`.
enum StorePriceLookup {

    /// Localized display prices by product id. Products the store does not know are simply absent,
    /// which is the same signal as a failed lookup and resolves the same way.
    /**
     What the store knows about a product: its localized price and its ISO billing period.

     Both come off the SAME `Product`, so they are fetched in ONE call. A second lookup for the
     period would double the round-trips and could disagree with the price it sits beside — a
     paywall showing this month's price against last month's cadence is worse than showing neither.
     */
    struct StoreFacts {
        let price: String?
        let periodIso: String?

        /**
         The free-trial period, as ISO, and ONLY when this user can actually have it.

         🔴 A TRIAL SENTENCE IS A PROMISE. `isEligibleForIntroOffer` is a real per-user flag: a user
         who has already taken the trial on this Apple ID answers false, and this stays nil, so the
         paywall says nothing rather than offering a trial the purchase sheet will refuse.

         Only a `.freeTrial` payment mode qualifies. An introductory PRICE is a different promise
         and is deliberately not rendered as a free trial.
         */
        let trialIso: String?

        /// The NUMERIC price, for arithmetic on it — a savings figure (`PlanSavings`). nil when absent.
        var amount: Double? = nil
    }

    /**
     StoreKit reports a subscription's period structurally, as a unit and a count. The SDKs speak
     ISO-8601 for a period everywhere else (Play reports `P1M` directly, the shared fixtures use it,
     and `BillingPeriodPhrase` parses it), so iOS's structural value is normalised to the same
     spelling rather than given its own representation to diverge in.
     */
    private static func iso(_ period: Product.SubscriptionPeriod?) -> String? {
        guard let period, period.value > 0 else { return nil }
        let unit: String
        switch period.unit {
        case .day: unit = "D"
        case .week: unit = "W"
        case .month: unit = "M"
        case .year: unit = "Y"
        @unknown default: return nil
        }
        return "P\(period.value)\(unit)"
    }

    /// Price AND period by product id, in one store round-trip.
    static func facts(
        for productIds: [String],
        timeout: TimeInterval = 1.5,
        completion: @escaping ([String: StoreFacts]) -> Void
    ) {
        let ids = Array(Set(productIds.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { completion([:]); return }

        // One-shot, the same way `prices` is: whichever arrives first — the reply or the deadline —
        // answers, and the other is dropped. Without this a slow reply calls back after the paywall
        // is already on screen.
        let answered = AtomicFlag()
        let finish: ([String: StoreFacts]) -> Void = { facts in
            guard answered.testAndSet() else { return }
            completion(facts)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            Log.info("[Paywall] store lookup may have exceeded \(timeout)s — authored values stand if so")
            finish([:])
        }

        Task {
            do {
                let products = try await Product.products(for: ids)
                var map: [String: StoreFacts] = [:]
                for p in products {
                    // A one-time product has no subscription and therefore no period, which is
                    // correct rather than missing.
                    let sub = p.subscription
                    var trial: String? = nil
                    if let sub, let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial {
                        // The per-user question, asked of the store rather than inferred.
                        if await sub.isEligibleForIntroOffer {
                            trial = iso(intro.period)
                        }
                    }
                    map[p.id] = StoreFacts(
                        price: p.displayPrice,
                        periodIso: iso(sub?.subscriptionPeriod),
                        trialIso: trial,
                        amount: NSDecimalNumber(decimal: p.price).doubleValue
                    )
                }
                if map.isEmpty {
                    Log.info("[Paywall] the store knows none of \(ids.count) product(s) — using authored values")
                }
                finish(map)
            } catch {
                Log.info("[Paywall] store lookup failed (\(error.localizedDescription)) — using authored values")
                finish([:])
            }
        }
    }

    static func prices(
        for productIds: [String],
        timeout: TimeInterval = 1.5,
        completion: @escaping ([String: String]) -> Void
    ) {
        let ids = Set(productIds.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !ids.isEmpty else { completion([:]); return }

        // One-shot: whichever arrives first — the reply or the deadline — answers, and the other
        // is dropped. Without this a slow reply would call back after the paywall is on screen.
        let answered = AtomicFlag()
        let finish: ([String: String]) -> Void = { prices in
            guard answered.testAndSet() else { return }
            completion(prices)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !answered.isSet {
                Log.info("[Paywall] store price lookup exceeded \(timeout)s — using authored prices")
            }
            finish([:])
        }

        Task {
            do {
                let products = try await Product.products(for: ids)
                var map: [String: String] = [:]
                for p in products { map[p.id] = p.displayPrice }
                if map.isEmpty {
                    Log.info("[Paywall] the store knows none of \(ids.count) product(s) — using authored prices")
                }
                finish(map)
            } catch {
                Log.info("[Paywall] store price lookup failed (\(error.localizedDescription)) — using authored prices")
                finish([:])
            }
        }
    }
}

/// A set-once flag, safe from the two queues this is raced on.
///
/// Not `os_unfair_lock` or an actor: the deadline fires on main and the StoreKit reply on a Task's
/// executor, so the race is real but tiny, and a lock here is cheaper to read than an actor hop in
/// a path that runs while a user waits for a screen.
final class AtomicFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// True for the FIRST caller only.
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
