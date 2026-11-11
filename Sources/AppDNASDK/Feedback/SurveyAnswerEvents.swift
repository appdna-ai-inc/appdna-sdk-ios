import Foundation

/// When `survey_question_answered` is tracked: once per question answered, not once per change.
///
/// A typed answer is tracked when the user moves on from the question (Next or Submit), with what they typed, and only
/// if it is not blank. A tap answer (NPS, choice, rating, …) is tracked when it is picked, as before. Either way an answer
/// equal to the one already tracked for that question is not tracked again. Mirrors Android `SurveyAnswerEvents`; shared
/// fixture `survey_question_answered_once`.
final class SurveyAnswerEvents {
    struct Emit { let questionId: String; let type: String; let answer: Any }

    /// Question types answered by typing.
    static let typed: Set<String> = ["free_text"]

    private var tracked: [String: String] = [:]
    private var pending: [String: (type: String, answer: Any)] = [:]

    /// The answer to `questionId` changed. Returns the event to track now, or nil.
    func changed(questionId: String, type: String, answer: Any) -> Emit? {
        if Self.typed.contains(type) {
            pending[questionId] = (type, answer)
            return nil
        }
        return emitIfNew(questionId, type, answer)
    }

    /// The user moved on from `questionId` (Next or Submit). Returns the typed answer's event, or nil.
    func leaving(questionId: String) -> Emit? {
        guard let p = pending.removeValue(forKey: questionId) else { return nil }
        if let s = p.answer as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return emitIfNew(questionId, p.type, p.answer)
    }

    private func emitIfNew(_ questionId: String, _ type: String, _ answer: Any) -> Emit? {
        let key = String(describing: answer)
        if tracked[questionId] == key { return nil }
        tracked[questionId] = key
        return Emit(questionId: questionId, type: type, answer: answer)
    }
}
