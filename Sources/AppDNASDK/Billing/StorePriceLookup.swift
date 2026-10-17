import Foundation
import StoreKit

/// Asks the App Store what a paywall's products cost, bounded, and never fails.
///
/// #923 — the renderer's door to StoreKit. `PriceResolver` could already do this and had ZERO
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
