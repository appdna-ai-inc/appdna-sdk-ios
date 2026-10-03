import SwiftUI

/// Checkbox-style multi-selection.
struct MultiChoiceView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?
    // Gap #19 — option_style from SurveyAppearance applied to each option card
    var optionStyle: ElementStyleConfig? = nil
    // Honor the survey theme's resolved accent + text colors (was hardcoded
    // #6366F1 checkbox / `.primary` label, which ignored SurveyTheme.accent_color /
    // text_color and diverged from the console SurveyPreview). Defaults preserve
    // prior behavior for any caller that does not pass them.
    var accentColor: Color = Color(hex: "#6366F1")
    var textColor: Color = .primary

    private var selectedIds: [String] {
        answer?.answer as? [String] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            ForEach(question.options ?? [], id: \.id) { option in
                Button {
                    toggleOption(option.id ?? "")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIds.contains(option.id ?? "") ? "checkmark.square.fill" : "square")
                            .foregroundColor(selectedIds.contains(option.id ?? "") ? accentColor : .gray)

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
                    .applyContainerStyleOrDefault(optionStyle, isSelected: selectedIds.contains(option.id ?? ""), accentColor: accentColor)
                }
            }
        }
    }

    private func toggleOption(_ id: String) {
        var current = selectedIds
        if let index = current.firstIndex(of: id) {
            current.remove(at: index)
        } else {
            current.append(id)
        }
        answer = SurveyAnswer(question_id: question.id ?? "", answer: current)
    }
}
