import Foundation

// MARK: - Firestore schema types for surveys

/// Root config from Firestore `/config/surveys`.
struct SurveyRoot: Codable {
    let version: Int?
    let surveys: [String: SurveyConfig]?
}

/// A single survey definition.
public struct SurveyConfig: Codable {
    public let name: String?
    public let survey_type: String? // "nps", "csat", "custom"
    public let questions: [SurveyQuestion]?
    public let trigger_rules: SurveyTriggerRules?
    public let appearance: SurveyAppearance?
    public let follow_up_actions: SurveyFollowUpActions?
}

/// A single survey question.
/// Choice config wrapper — Firestore nests options inside choice_config
public struct ChoiceConfig: Codable {
    public let options: [SurveyQuestionOption]?
}

public struct SurveyQuestion: Codable {
    public let id: String?
    public let type: String? // "nps", "csat", "rating", "single_choice", "multi_choice", "free_text", "yes_no", "emoji_scale"
    public let text: String?
    public let required: Bool?
    public let show_if: ShowIfCondition?

    // Type-specific configs
    public let nps_config: NPSConfig?
    public let csat_config: CSATConfig?
    public let rating_config: RatingConfig?
    public let choice_config: ChoiceConfig?     // Firestore format
    private let _options: [SurveyQuestionOption]?  // Legacy flat format
    public let emoji_config: EmojiConfig?
    public let free_text_config: FreeTextConfig?
    // Question-level image
    public let image_url: String?

    /// Resolved options — prefer choice_config.options, fall back to flat options
    public var options: [SurveyQuestionOption]? { choice_config?.options ?? _options }

    /// Convenience init for creating interpolated copies
    public init(
        id: String?, type: String?, text: String?, required: Bool?,
        show_if: ShowIfCondition?, nps_config: NPSConfig?, csat_config: CSATConfig?,
        rating_config: RatingConfig?, options: [SurveyQuestionOption]?,
        emoji_config: EmojiConfig?, free_text_config: FreeTextConfig?, image_url: String?
    ) {
        self.id = id; self.type = type; self.text = text; self.required = required
        self.show_if = show_if; self.nps_config = nps_config; self.csat_config = csat_config
        self.rating_config = rating_config; self.choice_config = nil; self._options = options
        self.emoji_config = emoji_config; self.free_text_config = free_text_config
        self.image_url = image_url
    }

    enum CodingKeys: String, CodingKey {
        case id, type, text, required, show_if
        case nps_config, csat_config, rating_config, choice_config
        case _options = "options"
        case emoji_config, free_text_config, image_url
    }
}

public struct ShowIfCondition: Codable {
    public let question_id: String?
    public let answer_in: [AnyCodable]?
}

public struct NPSConfig: Codable {
    public let low_label: String?
    public let high_label: String?
}

public struct CSATConfig: Codable {
    private let max_rating: Int?  // Legacy SDK field
    public let scale: Int?        // Firestore sends "scale" (3, 5, or 7)
    public let labels: [String]?
    public let style: String?

    /// Resolved max — prefer scale (Firestore), fall back to max_rating (legacy)
    public var resolvedMax: Int { scale ?? max_rating ?? 5 }
}

public struct RatingConfig: Codable {
    private let max_rating: Int?  // Legacy SDK field
    public let max: Int?          // Firestore sends "max"
    public let icon: String?      // "star", "heart", "thumb"
    public let style: String?

    /// Resolved max — prefer max (Firestore), fall back to max_rating (legacy)
    public var resolvedMax: Int { max ?? max_rating ?? 5 }
    /// Resolved icon — prefer icon (Firestore), fall back to style (legacy)
    public var resolvedIcon: String { icon ?? style ?? "star" }
}

public struct SurveyQuestionOption: Codable {
    public let id: String?
    private let _text: String?   // Legacy "text"
    public let label: String?    // Firestore sends "label"
    public let icon: String?
    public let emoji: String?

    /// Display text — prefer label (Firestore), fall back to text (legacy)
    public var text: String? { label ?? _text }

    /// Convenience init for creating interpolated copies
    public init(id: String?, text: String?, icon: String?) {
        self.id = id; self._text = text; self.label = nil; self.icon = icon; self.emoji = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, label, icon, emoji
        case _text = "text"
    }
}

public struct EmojiConfig: Codable {
    public let emojis: [String]? // default: ["😡","😕","😐","😊","😍"]
}

public struct FreeTextConfig: Codable {
    public let placeholder: String?
    public let max_length: Int? // default 500
}

/// Survey trigger rules.
public struct SurveyTriggerRules: Codable {
    public let event: String?
    public let conditions: [TriggerCondition]?
    public let love_score_range: ScoreRange?
    public let frequency: MessageFrequency? // reuse from in-app messaging
    public let max_displays: Int?
    public let delay_seconds: Int?
    public let min_sessions: Int?
}

public struct ScoreRange: Codable {
    public let min: Int?
    public let max: Int?
}

/// Survey appearance settings.
public struct SurveyAppearance: Codable {
    public let presentation: String? // "bottom_sheet", "modal", "fullscreen"
    /// Supports both legacy flat SurveyTheme AND `{ light, dark }`
    /// via ThemeSet's back-compat decoder. Callers resolve via
    /// `theme?.resolved(for: colorScheme)` at render time.
    public let theme: ThemeSet<SurveyTheme>?
    public let dismiss_allowed: Bool?
    public let show_progress: Bool?
    // Style engine integration
    public let question_text_style: TextStyleConfig?
    public let option_style: ElementStyleConfig?
    public let corner_radius: Int?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presentation = try container.decodeIfPresent(String.self, forKey: .presentation) ?? "modal"
        theme = try container.decodeIfPresent(ThemeSet<SurveyTheme>.self, forKey: .theme)
        dismiss_allowed = try container.decodeIfPresent(Bool.self, forKey: .dismiss_allowed) ?? true
        show_progress = try container.decodeIfPresent(Bool.self, forKey: .show_progress) ?? false
        question_text_style = try container.decodeIfPresent(TextStyleConfig.self, forKey: .question_text_style)
        option_style = try container.decodeIfPresent(ElementStyleConfig.self, forKey: .option_style)
        corner_radius = try container.decodeIfPresent(Int.self, forKey: .corner_radius)
    }
}

public struct SurveyTheme: Codable, SparseMergeable {
    public let background_color: String?
    public let text_color: String?
    public let accent_color: String?
    public let button_color: String?
    public let button_text_color: String?
    public let font_family: String?
    // Rich media in surveys
    public let intro_lottie_url: String?
    public let thankyou_lottie_url: String?
    public let thankyou_particle_effect: ParticleEffect?
    public let blur_backdrop: BlurConfig?
    public let haptic: HapticConfig?
    // Configurable thank-you text for interpolation
    public let thank_you_text: String?
    // Gradients + typography (previously authored by console but
    // silently ignored by the SDK — see audit). Now decoded + merged so the
    // dark variant can override any of them.
    public let gradient: GradientConfig?
    public let button_gradient: GradientConfig?
    public let text_align: String?          // "left" | "center" | "right"
    public let question_font_size: Double?
    public let font_weight: String?         // "normal" | "medium" | "semibold" | "bold"

    public init(
        background_color: String? = nil,
        text_color: String? = nil,
        accent_color: String? = nil,
        button_color: String? = nil,
        button_text_color: String? = nil,
        font_family: String? = nil,
        intro_lottie_url: String? = nil,
        thankyou_lottie_url: String? = nil,
        thankyou_particle_effect: ParticleEffect? = nil,
        blur_backdrop: BlurConfig? = nil,
        haptic: HapticConfig? = nil,
        thank_you_text: String? = nil,
        gradient: GradientConfig? = nil,
        button_gradient: GradientConfig? = nil,
        text_align: String? = nil,
        question_font_size: Double? = nil,
        font_weight: String? = nil
    ) {
        self.background_color = background_color
        self.text_color = text_color
        self.accent_color = accent_color
        self.button_color = button_color
        self.button_text_color = button_text_color
        self.font_family = font_family
        self.intro_lottie_url = intro_lottie_url
        self.thankyou_lottie_url = thankyou_lottie_url
        self.thankyou_particle_effect = thankyou_particle_effect
        self.blur_backdrop = blur_backdrop
        self.haptic = haptic
        self.thank_you_text = thank_you_text
        self.gradient = gradient
        self.button_gradient = button_gradient
        self.text_align = text_align
        self.question_font_size = question_font_size
        self.font_weight = font_weight
    }

    /// Sparse-merge self (overrides) onto baseline. Any field
    /// set on self wins; otherwise fall back to the baseline value.
    public func merged(onto baseline: SurveyTheme) -> SurveyTheme {
        SurveyTheme(
            background_color: background_color ?? baseline.background_color,
            text_color: text_color ?? baseline.text_color,
            accent_color: accent_color ?? baseline.accent_color,
            button_color: button_color ?? baseline.button_color,
            button_text_color: button_text_color ?? baseline.button_text_color,
            font_family: font_family ?? baseline.font_family,
            intro_lottie_url: intro_lottie_url ?? baseline.intro_lottie_url,
            thankyou_lottie_url: thankyou_lottie_url ?? baseline.thankyou_lottie_url,
            thankyou_particle_effect: thankyou_particle_effect ?? baseline.thankyou_particle_effect,
            blur_backdrop: blur_backdrop ?? baseline.blur_backdrop,
            haptic: haptic ?? baseline.haptic,
            thank_you_text: thank_you_text ?? baseline.thank_you_text,
            gradient: gradient ?? baseline.gradient,
            button_gradient: button_gradient ?? baseline.button_gradient,
            text_align: text_align ?? baseline.text_align,
            question_font_size: question_font_size ?? baseline.question_font_size,
            font_weight: font_weight ?? baseline.font_weight
        )
    }
}

/// Follow-up actions based on survey sentiment.
public struct SurveyFollowUpActions: Codable {
    public let on_positive: FollowUpAction?
    public let on_negative: FollowUpAction?
    public let on_neutral: FollowUpAction?
}

public struct FollowUpAction: Codable {
    public let action: String? // "prompt_review", "show_feedback_form", "dismiss"
    public let message: String?
}

/// A single survey answer.
public struct SurveyAnswer {
    public let question_id: String
    public let answer: Any

    var asDictionary: [String: Any] {
        return ["question_id": question_id, "answer": answer]
    }
}

/// Survey completion result.
public enum SurveyResult {
    case completed(answers: [SurveyAnswer])
    case dismissed(answeredCount: Int)
}

/// Sentiment determination.
enum SurveySentiment {
    case positive
    case negative
    case neutral

    /// The `sentiment` property value on every `survey_followup_*` event. Android sends
    /// `sentiment.name.lowercase()` (`feedback/SurveyManager.kt:314`) — same three strings.
    var analyticsName: String {
        switch self {
        case .positive: return "positive"
        case .negative: return "negative"
        case .neutral: return "neutral"
        }
    }
}
