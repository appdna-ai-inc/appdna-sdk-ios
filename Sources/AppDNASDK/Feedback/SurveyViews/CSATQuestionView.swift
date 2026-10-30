import SwiftUI

/// Star or emoji rating (1-5 by default).
struct CSATQuestionView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?

    private var maxRating: Int {
        question.csat_config?.resolvedMax ?? 5
    }

    private var style: String {
        question.csat_config?.style ?? "star"
    }

    private var selectedRating: Int? {
        answer?.answer as? Int
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(question.text ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ForEach(1...maxRating, id: \.self) { rating in
                    Button {
                        answer = SurveyAnswer(question_id: question.id ?? "", answer: rating)
                    } label: {
                        if style == "emoji" {
                            Text(emojiFor(rating: rating, max: maxRating))
                                .font(.system(size: 32))
                        } else {
                            Image(systemName: (selectedRating ?? 0) >= rating ? "star.fill" : "star")
                                .font(.system(size: 28))
                                .foregroundColor((selectedRating ?? 0) >= rating ? Color(hex: "#FBBF24") : Color(hex: "#D1D5DB"))
                        }
                    }
                    // A control a UI test cannot address is a control a WALK cannot
                    // operate. These are SF Symbol images inside a Button, so without an
                    // identifier a test is reduced to tapping by index and hoping the order is
                    // what it thinks. The whole survey surface had none.
                    .accessibilityIdentifier("survey.rating.\(rating)")
                }
            }
        }
    }

    private func emojiFor(rating: Int, max: Int) -> String {
        let emojis = ["😡", "😕", "😐", "😊", "😍"]
        let index = Int(Double(rating - 1) / Double(max - 1) * Double(emojis.count - 1))
        return emojis[min(index, emojis.count - 1)]
    }
}
