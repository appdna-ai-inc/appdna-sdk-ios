import Foundation

/// The order a paywall's plans draw in — #1056.
///
/// 🔴 `PaywallPlan.sort_order` WAS DECODED BY BOTH PLATFORMS AND READ BY NEITHER. Plan order came
/// from the array's own order, so a document that carried an explicit rank — a generator's output,
/// an import, a hand-written paywall — drew its plans in whatever order they happened to be
/// serialised in, with no sign that an authored rank had been dropped.
///
/// 🔴 THE RANK IS `sort_order ?? index`, AND THE SORT IS STABLE. Sorting only when EVERY plan
/// carries a value would make the field useless the moment one plan lacked it; sorting with a
/// missing value treated as 0 would silently promote it to the front. Using the plan's own array
/// position as its rank means a plan with no `sort_order` stays exactly where it is, a plan with one
/// moves to that rank, and two plans claiming the same rank keep their relative order — so nothing
/// published today can reorder, which is the risk an explicit rank beside an implicit one carries.
///
/// Mirrors Android `PaywallPlanOrder`.
enum PaywallPlanOrder {

    /// `plans` in the order they should be drawn.
    static func sorted(_ plans: [PaywallPlan]) -> [PaywallPlan] {
        // Nothing to decide, and no allocation for the common case.
        guard plans.contains(where: { $0.sort_order != nil }) else { return plans }
        return plans.enumerated()
            .sorted { a, b in
                let ra = a.element.sort_order ?? a.offset
                let rb = b.element.sort_order ?? b.offset
                // `a.offset < b.offset` on a tie is what makes this STABLE: Swift's `sorted(by:)`
                // is not guaranteed to be, so two plans at the same rank could otherwise swap
                // between runs and the paywall would reorder itself for no authored reason.
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }
}
