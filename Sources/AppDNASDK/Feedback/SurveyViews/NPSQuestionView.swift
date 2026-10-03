import SwiftUI

/// 0-10 number scale with endpoint labels.
struct NPSQuestionView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?
    // Honor the survey theme's resolved colors. Selected score fill was hardcoded
    // Color(hex:"#6366F1") with a `.white` label (white-on-white when accent is white);
    // unselected label was `.primary`. Defaults preserve prior behavior.
    var accentColor: Color = Color(hex: "#6366F1")
    var buttonTextColor: Color = .white
    var textColor: Color = .primary

    private var selectedScore: Int? {
        answer?.answer as? Int
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)

            // 0-10 number scale
            HStack(spacing: 4) {
                ForEach(0...10, id: \.self) { score in
                    Button("\(score)") {
                        answer = SurveyAnswer(question_id: question.id ?? "", answer: score)
                    }
                    .frame(width: 30, height: 40)
                    .background(selectedScore == score ? accentColor : Color.gray.opacity(0.1))
                    .foregroundColor(selectedScore == score ? buttonTextColor : textColor)
                    .cornerRadius(8)
                    .font(.system(size: 14, weight: .medium))
                }
            }

            // Labels
            HStack {
                Text(question.nps_config?.low_label ?? "Not likely")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(question.nps_config?.high_label ?? "Extremely likely")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
