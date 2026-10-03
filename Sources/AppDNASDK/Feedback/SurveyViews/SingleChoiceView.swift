import SwiftUI

/// Radio-button style single selection.
struct SingleChoiceView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?
    // Gap #19 — option_style from SurveyAppearance applied to each option card
    var optionStyle: ElementStyleConfig? = nil
    // Honor the survey theme's resolved accent + text colors. Previously the
    // selected radio was hardcoded `Color(hex: "#6366F1")` and the option label was
    // `.primary`, ignoring SurveyTheme.accent_color / text_color and diverging from
    // the console SurveyPreview (which paints both with the theme colors). Defaults
    // preserve prior behavior for any caller that does not pass them.
    var accentColor: Color = Color(hex: "#6366F1")
    var textColor: Color = .primary

    private var selectedId: String? {
        answer?.answer as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            ForEach(question.options ?? [], id: \.id) { option in
                Button {
                    answer = SurveyAnswer(question_id: question.id ?? "", answer: option.id ?? "")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedId == option.id ? "circle.inset.filled" : "circle")
                            .foregroundColor(selectedId == option.id ? accentColor : .gray)

                        if let icon = option.icon {
                            Text(icon)
                        }

                        Text(option.text ?? "")
                            .foregroundColor(textColor)

                        Spacer()
                    }
                    .padding(.vertical, optionStyle == nil ? 8 : 0)
                    .padding(.horizontal, optionStyle == nil ? 12 : 0)
                    // Apply option_style if provided, otherwise fall back to default card border
                    // Thread the survey accent so the selected card border honors accent_color.
                    .applyContainerStyleOrDefault(optionStyle, isSelected: selectedId == option.id, accentColor: accentColor)
                }
            }
        }
    }
}
