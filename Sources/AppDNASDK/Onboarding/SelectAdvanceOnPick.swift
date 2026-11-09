import Foundation

/// Whether a pick in a Select moves the step on by itself (`auto_advance: true` on the block).
///
/// A single-select advances on the pick. A multi-select advances once `field_config.max_selections`
/// options are picked, on the pick that reaches the limit: before it the user is not finished, and
/// with no limit there is no moment that could be called finished. A pick that opens the option's
/// bottom sheet does not advance, because the sheet is what the user is now looking at. The advance
/// itself is the step's own `next`, so required fields and next-step rules apply as they do to a CTA.
///
/// Mirrors Android `SelectAdvanceOnPick.kt` and the console's `selectAdvancesOnPick`. Pinned on both
/// platforms by the shared fixture `step_advance/select_advance_on_pick`.
enum SelectAdvanceOnPick {

    /// Long enough to draw the picked option as selected before the screen changes.
    static let delaySeconds: Double = 0.25

    /// `before` and `after` are the selection either side of the pick, in values. A refused or
    /// removing tap leaves a multi-select no longer than it was, which is why both are needed.
    static func shouldAdvance(block: ContentBlock, before: [String], after: [String], opensSheet: Bool) -> Bool {
        guard block.auto_advance == true, !opensSheet else { return false }
        guard SelectOptionTap.isMultiSelect(block) else {
            return !(after.first ?? "").isEmpty
        }
        guard let limit = cfgDouble(block.field_config?["max_selections"]), limit >= 1 else { return false }
        return after.count > before.count && Double(after.count) >= limit
    }
}
