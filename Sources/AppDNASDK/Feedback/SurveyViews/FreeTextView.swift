import SwiftUI

/// Multi-line text input with character count.
struct FreeTextView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var maxLength: Int {
        question.free_text_config?.max_length ?? 500
    }

    private var placeholder: String {
        question.free_text_config?.placeholder ?? "Type your answer..."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundColor(.gray.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .onTapGesture {
                            isFocused = true
                        }
                }

                TextEditor(text: $text)
                    .accessibilityIdentifier("survey.freetext")
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 200)
                    .padding(4)
                    .onChange(of: text) { newValue in
                        if newValue.count > maxLength {
                            text = String(newValue.prefix(maxLength))
                        }
                        answer = SurveyAnswer(question_id: question.id ?? "", answer: text)
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .onTapGesture {
                isFocused = true
            }

            HStack {
                Spacer()
                Text("\(text.count)/\(maxLength)")
                    .font(.caption)
                    .foregroundColor(text.count >= maxLength ? .red : .secondary)
            }
        }
    }
}
