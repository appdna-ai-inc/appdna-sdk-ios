import Foundation

/*
 #1013 — WHAT A `visibility_condition` IS EVALUATED AGAINST, as one rule both platforms call.

 `responses` holds COMPLETED steps only: a step writes its answers under its own id when it ends
 (`responses[step.id] = data`). So a condition naming a field on the step currently on screen
 resolved against nothing, and a block authored "show when the category above is Modern" never
 appeared — the category is chosen and the step is still open, which is the only moment the
 condition matters.

 The merge is the whole mechanism behind a category-bubbles row filtering the blocks beneath it:
 the row is an ordinary single-select, the blocks beneath it carry ordinary visibility conditions
 naming its field, and this is what makes those conditions react while the step is open.

 🔴 LIVE VALUES WIN. A step re-entered by back navigation already has saved answers under its own
 id, and the author is looking at the control, not at what it held last time. Saved values stay
 for every field the author has not touched this visit, so a restored step filters correctly on
 the first frame rather than collapsing to its unfiltered shape.

 🔴 Nothing else is reshaped. `responses` is what customer webhooks receive, and it is handed to
 bindings and to the template engine as well — this merge is built for the visibility evaluator
 and handed to nothing else, so a completed-step answer is still the only thing a `{{responses.…}}`
 string resolves to.
 */
public enum VisibilityScope {
    /**
     `responses` with the current step's live input values merged in under its own step id.

     Returns `responses` untouched when there is no step id or nothing live to merge, so a caller
     that cannot supply them (a Screens surface, an option sheet, the preview of a single block)
     behaves exactly as it did before.
     */
    public static func merge(
        responses: [String: Any],
        stepId: String?,
        stepInputs: [String: Any]?
    ) -> [String: Any] {
        guard let stepId = stepId, !stepId.isEmpty,
              let live = stepInputs, !live.isEmpty else { return responses }

        var merged = responses
        // A step entry that is not a dictionary is not an answer map — a stray value replaces
        // nothing, and the live inputs stand alone rather than being dropped on the floor.
        let saved = responses[stepId] as? [String: Any] ?? [:]
        merged[stepId] = saved.merging(live) { _, liveValue in liveValue }
        return merged
    }
}
