import SwiftUI

/*
 #998 — the likert scale, on iOS.

 Android has rendered one since its first survey release; iOS had no `likert_config` field at all,
 so `SurveyRenderer`'s `default:` arm drew an `EmptyView()` and a respondent saw the question text
 above empty space. The owner's call was to make it real on every surface.

 This mirrors `LikertQuestionView.kt` deliberately and closely — the same bounds and defaults
 (1...5), the same malformed-config clamp, the same anchor labels hidden when neither is set, and
 the answer recorded as the selected `Int` through `SurveyAnswer` so the upload and `show_if`
 branching work with no further change. Its visual style follows `NPSQuestionView` on this
 platform, as the Android one follows `NpsQuestionView` on that one, so the survey appearance theme
 applies without a special case.
*/

/// Configurable numeric scale with optional anchor labels (e.g. "Strongly disagree" → "Strongly agree").
struct LikertQuestionView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?
    var accentColor: Color = Color(hex: "#6366F1")
    var buttonTextColor: Color = .white
    var textColor: Color = .primary

    private var selectedScore: Int? { answer?.answer as? Int }

    private var config: LikertConfig? { question.resolvedLikertConfig }

    /// Through {@link LikertScaleRule}, which the shared fixture drives — never re-stated here.
    private var bounds: ClosedRange<Int> {
        let b = LikertScaleRule.bounds(min: config?.min, max: config?.max)
        return b.lo...b.hi
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ForEach(Array(bounds), id: \.self) { score in
                    Button("\(score)") {
                        answer = SurveyAnswer(question_id: question.id ?? "", answer: score)
                    }
                    .accessibilityIdentifier("survey.likert.\(score)")
                    .accessibilityLabel("Rating \(score) of \(bounds.upperBound)")
                    .frame(width: 40, height: 44)
                    .background(selectedScore == score ? accentColor : Color.gray.opacity(0.1))
                    .foregroundColor(selectedScore == score ? buttonTextColor : textColor)
                    .cornerRadius(8)
                    .font(.system(size: 14, weight: .medium))
                }
            }

            // Hidden when neither label is set, so a bare numeric scale reserves no empty space.
            if LikertScaleRule.showsAnchors(low: config?.low_label, high: config?.high_label) {
                HStack {
                    Text(config?.low_label ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(config?.high_label ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
