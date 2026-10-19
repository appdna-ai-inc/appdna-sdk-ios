import Foundation

/**
 WHICH follow-up branch a completed survey takes — in one place both platforms are held to.

 🔴 #1011 — this lived inline in both renderers and classified an emoji answer against a HARD-CODED
 literal of the five default emoji. The Console's own default scale is not that list (it writes 😟
 and 🙂 where the SDKs had 😕 and 😊), so a survey created in the Console and answered with either
 middle face came back `neutral`, and any custom scale came back neutral for every answer —
 `follow_up_actions.on_positive` / `on_negative` silently never ran.

 It is a pure function so a shared fixture can drive the REAL decision on both platforms rather
 than re-implementing it (CLAUDE.md Rule 25).

 🔴 The sentiment is read from the SURVEY's `survey_type`, not from the question's own type. A
 survey left as `custom` is always `neutral` whatever its questions are — documented on all four
 SDK pages, and deliberately not changed here: inferring it would silently re-route every existing
 survey.
 */
public enum SurveySentimentRule {

    /// The scale an emoji question falls back to when none is authored — the SDK's historical five.
    public static let defaultEmojiScale = ["😡", "😕", "😐", "😊", "😍"]

    /// `positive` / `negative` / `neutral`, as the three `follow_up_actions` branches.
    public static func resolve(
        surveyType: String?,
        answer: Any?,
        emojiScale: [String]?
    ) -> SurveySentiment {
        let type = surveyType ?? ""

        // NPS: 9-10 promoter, 0-6 detractor, 7-8 passive.
        if type == "nps", let score = intValue(answer) {
            if score >= 9 { return .positive }
            if score <= 6 { return .negative }
            return .neutral
        }

        // CSAT / rating out of five.
        if ["csat", "rating"].contains(type), let rating = intValue(answer) {
            if rating >= 4 { return .positive }
            if rating <= 2 { return .negative }
            return .neutral
        }

        /*
         * Emoji: ABOVE the middle of the AUTHORED scale is positive, below it negative, the middle
         * itself neutral. The midpoint reproduces the old thresholds exactly for a five-emoji scale
         * (positive 3-4, negative 0-1, neutral 2) and is defined for every other length — a
         * three-emoji scale had no positive branch at all before.
         */
        if type == "emoji_scale" || answer is String {
            if let emoji = answer as? String {
                let scale = (emojiScale?.isEmpty == false ? emojiScale : nil) ?? defaultEmojiScale
                if let idx = scale.firstIndex(of: emoji) {
                    let middle = Double(scale.count - 1) / 2.0
                    if Double(idx) > middle { return .positive }
                    if Double(idx) < middle { return .negative }
                    return .neutral
                }
            }
        }

        return .neutral
    }

    /// An answer arrives as whatever JSON held — `Int`, `Double` or a numeric `String`.
    private static func intValue(_ answer: Any?) -> Int? {
        if let i = answer as? Int { return i }
        if let d = answer as? Double { return Int(d) }
        if let s = answer as? String, let i = Int(s) { return i }
        return nil
    }
}
