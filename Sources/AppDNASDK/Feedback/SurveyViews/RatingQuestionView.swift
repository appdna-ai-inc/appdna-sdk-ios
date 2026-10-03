import SwiftUI

/// Star, heart, or thumb rating (configurable max).
struct RatingQuestionView: View {
    let question: SurveyQuestion
    @Binding var answer: SurveyAnswer?
    // Filled rating icons honor the survey theme's resolved accent_color, matching
    // the console SurveyPreview (which fills rating icons with accentColor for every style).
    // Was hardcoded per-style (heart .red / thumb #6366F1 / star #FBBF24), which ignored
    // SurveyTheme.accent_color. Defaults to the brand indigo for callers that don't pass it.
    var accentColor: Color = Color(hex: "#6366F1")

    private var maxRating: Int {
        question.rating_config?.resolvedMax ?? 5
    }

    private var style: String {
        question.rating_config?.resolvedIcon ?? "star"
    }

    private var selectedRating: Int? {
        answer?.answer as? Int
    }

    private var filledIcon: String {
        switch style {
        case "heart": return "heart.fill"
        case "thumb": return "hand.thumbsup.fill"
        default: return "star.fill"
        }
    }

    private var emptyIcon: String {
        switch style {
        case "heart": return "heart"
        case "thumb": return "hand.thumbsup"
        default: return "star"
        }
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
                        Image(systemName: (selectedRating ?? 0) >= rating ? filledIcon : emptyIcon)
                            .font(.system(size: 28))
                            .foregroundColor((selectedRating ?? 0) >= rating ? accentColor : Color(hex: "#D1D5DB"))
                    }
                }
            }
        }
    }
}
