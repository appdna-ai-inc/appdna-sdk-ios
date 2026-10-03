import Foundation
import SwiftUI

// MARK: - Firestore schema types for in-app messages

/// Root config from Firestore `/config/messages`.
struct MessageRoot: Codable {
    let version: Int?
    let messages: [String: MessageConfig]?
}

/// A single in-app message definition.
public struct MessageConfig: Codable {
    public let name: String?
    public let message_type: MessageType?
    public let content: MessageContent?
    public let trigger_rules: TriggerRules?
    public let priority: Int?
    public let start_date: String?
    public let end_date: String?
}

public enum MessageType: String, Codable {
    case banner
    case modal
    case fullscreen
    case tooltip
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MessageType(rawValue: rawValue) ?? .unknown
    }
}

/// Message display content.
public struct MessageContent: Codable {
    public let title: String?
    public let body: String?
    public let image_url: String?
    public let cta_text: String?
    public let cta_action: CTAAction?
    public let dismiss_text: String?
    public let background_color: String?
    public let banner_position: BannerPosition?
    public let auto_dismiss_seconds: Int?
    // Styling fields
    public let text_color: String?
    public let button_color: String?
    public let button_text_color: String?
    public let button_corner_radius: Int?
    public let corner_radius: Int?
    public let secondary_cta_text: String?
    // Typography — previously accepted by the console + Zod but
    // silently dropped by iOS. Now decoded so font choices authored in the
    // editor actually render on device.
    public let font_family: String?
    public let title_font_size: Double?
    public let body_font_size: Double?
    // Rich media fields
    public let lottie_url: String?
    public let rive_url: String?
    public let rive_state_machine: String?
    public let video_url: String?
    public let video_thumbnail_url: String?
    public let cta_icon: IconReference?
    public let secondary_cta_icon: IconReference?
    public let haptic: HapticConfig?
    public let particle_effect: ParticleEffect?
    public let blur_backdrop: BlurConfig?
    // Dark-mode overrides (sparse). When rendering in dark
    // appearance any field set here wins over the matching light field
    // above; unset fields fall back to the light value. Callers should
    // invoke `content.resolved(for: colorScheme)` at render time.
    public let dark: MessageContentDark?

    public init(
        title: String? = nil, body: String? = nil, image_url: String? = nil,
        cta_text: String? = nil, cta_action: CTAAction? = nil, dismiss_text: String? = nil,
        background_color: String? = nil, banner_position: BannerPosition? = nil,
        auto_dismiss_seconds: Int? = nil,
        text_color: String? = nil, button_color: String? = nil, button_text_color: String? = nil,
        button_corner_radius: Int? = nil, corner_radius: Int? = nil, secondary_cta_text: String? = nil,
        font_family: String? = nil, title_font_size: Double? = nil, body_font_size: Double? = nil,
        lottie_url: String? = nil, rive_url: String? = nil, rive_state_machine: String? = nil,
        video_url: String? = nil, video_thumbnail_url: String? = nil,
        cta_icon: IconReference? = nil, secondary_cta_icon: IconReference? = nil,
        haptic: HapticConfig? = nil, particle_effect: ParticleEffect? = nil,
        blur_backdrop: BlurConfig? = nil, dark: MessageContentDark? = nil
    ) {
        self.title = title; self.body = body; self.image_url = image_url
        self.cta_text = cta_text; self.cta_action = cta_action; self.dismiss_text = dismiss_text
        self.background_color = background_color; self.banner_position = banner_position
        self.auto_dismiss_seconds = auto_dismiss_seconds
        self.text_color = text_color; self.button_color = button_color; self.button_text_color = button_text_color
        self.button_corner_radius = button_corner_radius; self.corner_radius = corner_radius
        self.secondary_cta_text = secondary_cta_text
        self.font_family = font_family; self.title_font_size = title_font_size; self.body_font_size = body_font_size
        self.lottie_url = lottie_url; self.rive_url = rive_url; self.rive_state_machine = rive_state_machine
        self.video_url = video_url; self.video_thumbnail_url = video_thumbnail_url
        self.cta_icon = cta_icon; self.secondary_cta_icon = secondary_cta_icon
        self.haptic = haptic; self.particle_effect = particle_effect; self.blur_backdrop = blur_backdrop
        self.dark = dark
    }
}

/// Dark-mode overrides for MessageContent. Every field is
/// optional and sparse — only specify the fields that differ from the
/// light (default) values on the parent MessageContent.
public struct MessageContentDark: Codable {
    // Colors
    public let background_color: String?
    public let text_color: String?
    public let button_color: String?
    public let button_text_color: String?
    // Corner radii
    public let button_corner_radius: Int?
    public let corner_radius: Int?
    // Themed assets
    public let image_url: String?
    public let lottie_url: String?
    public let rive_url: String?
    public let video_url: String?
    public let video_thumbnail_url: String?
    public let cta_icon: IconReference?
    public let secondary_cta_icon: IconReference?
    // Rich effects
    public let particle_effect: ParticleEffect?
    public let blur_backdrop: BlurConfig?
}

extension MessageContent {
    /// Resolve a SwiftUI Font for the message title. Prefers the
    /// authored font_family + title_font_size; falls back to the supplied
    /// default when the content leaves typography unset. The `defaultWeight`
    /// lets each renderer keep its visual hierarchy (title bolder than body).
    public func titleFont(default defaultFont: Font, defaultSize: CGFloat) -> Font {
        if font_family == nil && title_font_size == nil { return defaultFont }
        return FontResolver.font(family: font_family, size: title_font_size ?? Double(defaultSize), weight: 700)
    }

    /// Resolve a SwiftUI Font for the message body. Same fallback
    /// semantics as `titleFont`.
    public func bodyFont(default defaultFont: Font, defaultSize: CGFloat) -> Font {
        if font_family == nil && body_font_size == nil { return defaultFont }
        return FontResolver.font(family: font_family, size: body_font_size ?? Double(defaultSize), weight: 400)
    }

    /// Render-time resolver. In dark mode, any field set on
    /// `dark` overrides the matching field above; everything else falls
    /// back to the light (default) value. In light mode or when no
    /// `dark` overrides exist, returns `self` unchanged.
    public func resolved(for scheme: ColorScheme) -> MessageContent {
        guard scheme == .dark, let d = dark else { return self }
        return MessageContent(
            title: title,
            body: body,
            image_url: d.image_url ?? image_url,
            cta_text: cta_text,
            cta_action: cta_action,
            dismiss_text: dismiss_text,
            background_color: d.background_color ?? background_color,
            banner_position: banner_position,
            auto_dismiss_seconds: auto_dismiss_seconds,
            text_color: d.text_color ?? text_color,
            button_color: d.button_color ?? button_color,
            button_text_color: d.button_text_color ?? button_text_color,
            button_corner_radius: d.button_corner_radius ?? button_corner_radius,
            corner_radius: d.corner_radius ?? corner_radius,
            secondary_cta_text: secondary_cta_text,
            // Typography stays light-only by design — messages don't vary
            // fonts or sizes between modes. Pass through unchanged.
            font_family: font_family,
            title_font_size: title_font_size,
            body_font_size: body_font_size,
            lottie_url: d.lottie_url ?? lottie_url,
            rive_url: d.rive_url ?? rive_url,
            rive_state_machine: rive_state_machine,
            video_url: d.video_url ?? video_url,
            video_thumbnail_url: d.video_thumbnail_url ?? video_thumbnail_url,
            cta_icon: d.cta_icon ?? cta_icon,
            secondary_cta_icon: d.secondary_cta_icon ?? secondary_cta_icon,
            haptic: haptic,
            particle_effect: d.particle_effect ?? particle_effect,
            blur_backdrop: d.blur_backdrop ?? blur_backdrop,
            dark: nil
        )
    }
}

public struct CTAAction: Codable {
    public let type: CTAActionType?
    public let url: String?

    public enum CTAActionType: String, Codable {
        case dismiss
        case deep_link
        case open_url
        case unknown

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = CTAActionType(rawValue: rawValue) ?? .unknown
        }
    }
}

public enum BannerPosition: String, Codable {
    case top
    case bottom

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = BannerPosition(rawValue: rawValue) ?? .bottom
    }
}

/// Rules that determine when a message triggers.
public struct TriggerRules: Codable {
    public let event: String?
    public let conditions: [TriggerCondition]?
    public let frequency: MessageFrequency?
    public let max_displays: Int?
    public let delay_seconds: Int?
}

public enum MessageFrequency: String, Codable {
    case once
    case once_per_session
    case every_time
    case max_times

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MessageFrequency(rawValue: rawValue) ?? .once
    }
}

/// A condition that must be met for a message to trigger.
public struct TriggerCondition: Codable {
    public let field: String?
    public let `operator`: ConditionOperator?
    public let value: AnyCodable?

    public enum ConditionOperator: String, Codable {
        case eq
        case gte
        case lte
        case gt
        case lt
        case contains

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = ConditionOperator(rawValue: rawValue) ?? .eq
        }
    }
}
