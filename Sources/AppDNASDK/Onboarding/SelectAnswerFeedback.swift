import Foundation

/// A Select that tells the user whether their pick was right.
///
/// The author marks the correct option(s) in `field_config.correct_values`. Once the user has answered, a message
/// shows under the options: `feedback_correct_text` in `feedback_correct_color` for a right answer,
/// `feedback_wrong_text` in `feedback_wrong_color` for a wrong one. A single-select is judged on its pick. A
/// multi-select is judged once as many options are picked as there are correct ones, and is right only when the
/// picked set IS the correct set; before that the user has not finished answering and nothing shows.
///
/// Mirrors Android `SelectAnswerFeedback.kt` and the console's `selectAnswerFeedback`. Pinned on both platforms by
/// the shared fixture `dto_parsing/select_answer_feedback`.
enum SelectAnswerFeedback {

    struct Message: Equatable {
        let isCorrect: Bool
        let text: String
        let colorHex: String
    }

    static let defaultCorrectText = "Correct!"
    static let defaultWrongText = "Not quite."
    static let defaultCorrectColor = "#16A34A"
    static let defaultWrongColor = "#DC2626"

    /// A stored or authored value as the string an option's value is compared with. A whole number is written
    /// without a fraction, so an authored `2` matches the option `"2"`.
    static func valueString(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        // A number and a Bool both bridge to NSNumber; a CFBoolean is the Bool (a checked toggle).
        guard let n = any as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : nil }
        let d = n.doubleValue
        guard d.isFinite else { return nil }
        return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }

    /// The authored correct option values, deduplicated in order; empty when the feature is off.
    static func correctValues(_ block: ContentBlock) -> [String] {
        let raw = block.field_config?["correct_values"]?.value
        let list: [Any] = (raw as? [Any]) ?? (raw.map { [$0] } ?? [])
        var seen = Set<String>()
        return list.compactMap { valueString($0) }.filter { seen.insert($0).inserted }
    }

    /// What a stored answer picked, in values.
    static func selection(from stored: Any?) -> [String] {
        if let list = stored as? [Any] { return list.compactMap { valueString($0) } }
        return valueString(stored).map { [$0] } ?? []
    }

    private static func text(_ block: ContentBlock, _ key: String, _ fallback: String) -> String {
        guard let s = block.field_config?[key]?.value as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return s
    }

    /// The message for `selection` (what the user has picked, in values), or nil when nothing is to be shown.
    static func message(block: ContentBlock, selection: [String]) -> Message? {
        let correct = correctValues(block)
        let picked = selection.filter { !$0.isEmpty }
        guard !correct.isEmpty, !picked.isEmpty else { return nil }
        let isRight: Bool
        if SelectOptionTap.isMultiSelect(block) {
            let set = Set(picked)
            guard set.count >= correct.count else { return nil }
            isRight = set == Set(correct)
        } else {
            isRight = correct.contains(picked[0])
        }
        return isRight
            ? Message(isCorrect: true, text: text(block, "feedback_correct_text", defaultCorrectText),
                      colorHex: text(block, "feedback_correct_color", defaultCorrectColor))
            : Message(isCorrect: false, text: text(block, "feedback_wrong_text", defaultWrongText),
                      colorHex: text(block, "feedback_wrong_color", defaultWrongColor))
    }
}
