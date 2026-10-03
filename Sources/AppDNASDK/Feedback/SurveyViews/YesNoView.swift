import SwiftUI

/// Two-button yes/no question.
struct YesNoView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?
    // Honor the survey theme's resolved colors. Selected button fill was hardcoded
    // Color(hex:"#6366F1") and the selected label was `.white` (white-on-white when the
    // theme accent is white); the unselected label was `.primary`. Defaults preserve prior
    // behavior for any caller that does not pass them.
    var accentColor: Color = Color(hex: "#6366F1")
    var buttonTextColor: Color = .white
    var textColor: Color = .primary

    private var selectedValue: String? {
        answer?.answer as? String
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    answer = SurveyAnswer(question_id: question.id ?? "", answer: "yes")
                } label: {
                    Text("Yes")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedValue == "yes" ? accentColor : Color.gray.opacity(0.1))
                        .foregroundColor(selectedValue == "yes" ? buttonTextColor : textColor)
                        .cornerRadius(10)
                }

                Button {
                    answer = SurveyAnswer(question_id: question.id ?? "", answer: "no")
                } label: {
                    Text("No")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedValue == "no" ? Color(hex: "#6366F1") : Color.gray.opacity(0.1))
                        .foregroundColor(selectedValue == "no" ? .white : .primary)
                        .cornerRadius(10)
                }
            }
        }
    }
}
