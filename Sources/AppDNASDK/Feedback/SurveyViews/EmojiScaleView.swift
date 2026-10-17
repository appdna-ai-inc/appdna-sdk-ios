import SwiftUI

/// Emoji row selection (e.g., 😡😕😐😊😍).
struct EmojiScaleView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?

    private var emojis: [String] {
        question.emoji_config?.emojis ?? ["😡", "😕", "😐", "😊", "😍"]
    }

    private var selectedEmoji: String? {
        answer?.answer as? String
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                ForEach(emojis, id: \.self) { emoji in
                    Button(emoji) {
                        answer = SurveyAnswer(question_id: question.id ?? "", answer: emoji)
                    }
                    .accessibilityIdentifier("survey.emoji.\(emoji)")
                    .font(.system(size: 36))
                    .scaleEffect(selectedEmoji == emoji ? 1.3 : 1.0)
                    .animation(.spring(response: 0.3), value: selectedEmoji)
                }
            }
        }
    }
}
