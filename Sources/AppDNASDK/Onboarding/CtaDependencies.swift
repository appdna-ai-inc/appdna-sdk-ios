import Foundation

/// A button that stays inactive until named conditions on this screen hold.
///
/// `field_config.cta_dependencies` on a `button` is a list of `{ block_id, condition, count?, value? }`. Every entry
/// must hold for the button to be active; until then a tap does nothing, and it draws in `cta_disabled_bg_color` (or
/// its own colour at 40% opacity when none is set), and once they hold in `cta_enabled_bg_color` (or its own colour).
///
/// A condition reads the answer of the block it names (`field_id`, else its id), anywhere on the step:
/// `answered` (something picked, typed or switched on), `all_selected` (every authored option picked), `min_selected`
/// (at least `count`, default 1), `correct` (right by that Select's `correct_values`; answered when none are marked) and
/// `equals` (the answer is, or includes, `value`). An entry naming a block that is not on the step, or a condition this
/// build does not know, holds: a button must never be left dead by a reference the user cannot satisfy.
///
/// Mirrors Android `CtaDependencies.kt` and the console's `ctaDependenciesMet`. Pinned on both platforms by the shared
/// fixture `step_advance/cta_dependencies`.
enum CtaDependencies {

    /// The opacity of an inactive button that has no authored inactive colour.
    static let inactiveOpacity: Double = 0.4

    /// Whether the button has any dependency at all (an unset or empty list: the button behaves as it always has).
    static func has(_ button: ContentBlock) -> Bool { !entries(button).isEmpty }

    private static func entries(_ button: ContentBlock) -> [[String: Any]] {
        ((button.field_config?["cta_dependencies"]?.value as? [Any]) ?? []).compactMap { entry in
            guard let d = entry as? [String: Any], let id = d["block_id"] as? String, !id.isEmpty else { return nil }
            return d
        }
    }

    /// The block with `id` at any depth (`children`, `stack_children`).
    static func find(_ blocks: [ContentBlock]?, id: String) -> ContentBlock? {
        for b in blocks ?? [] {
            if b.id == id { return b }
            if let n = find(b.children, id: id) ?? find(b.stack_children, id: id) { return n }
        }
        return nil
    }

    /// Whether the button is active: it has no dependencies, or every one holds.
    static func met(button: ContentBlock, blocks: [ContentBlock], inputValues: [String: Any]) -> Bool {
        entries(button).allSatisfy { holds($0, blocks: blocks, inputValues: inputValues) }
    }

    private static func holds(_ dep: [String: Any], blocks: [ContentBlock], inputValues: [String: Any]) -> Bool {
        guard let id = dep["block_id"] as? String, let target = find(blocks, id: id) else { return true }
        let picked = SelectAnswerFeedback.selection(from: inputValues[target.field_id ?? target.id])
        switch dep["condition"] as? String {
        case "answered":
            return !picked.isEmpty
        case "all_selected":
            let options = (target.field_options ?? []).map { $0.value ?? $0.id ?? "" }.filter { !$0.isEmpty }
            if options.isEmpty { return !picked.isEmpty }
            return options.allSatisfy { picked.contains($0) }
        case "min_selected":
            let raw = (dep["count"] as? NSNumber)?.doubleValue ?? 1
            let n = raw.isFinite ? max(1, Int(raw.rounded(.down))) : 1
            return picked.count >= n
        case "correct":
            guard !picked.isEmpty else { return false }
            guard let message = SelectAnswerFeedback.message(block: target, selection: picked) else {
                // Nothing marked: answered is all that can be asked. Marked but unfinished (a multi-select short of
                // the marked count): not yet.
                return SelectAnswerFeedback.correctValues(target).isEmpty
            }
            return message.isCorrect
        case "equals":
            guard let v = dep["value"] as? String, !v.isEmpty else { return false }
            return picked.contains(v)
        default:
            return true
        }
    }
}
