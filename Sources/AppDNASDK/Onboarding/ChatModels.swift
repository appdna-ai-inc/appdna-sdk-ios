import Foundation
import SwiftUI

// MARK: - Interactive Chat Config Models

/// Chat-specific configuration for interactive_chat step type.
public struct ChatConfig: Codable {
    public let max_user_turns: Int?
    public let min_user_turns: Int?
    public let turn_limit_behavior: String?  // "hard" | "soft"
    public let persona: ChatPersona?
    public let auto_messages: [ChatAutoMessage]?
    public let completion_message: ChatCompletionMessage?
    public let completion_cta_text: String?
    public let completion_button: ChatCompletionButton?
    public let quick_replies: [ChatQuickReply]?
    public let turn_actions: [ChatTurnAction]?
    public let input_placeholder: String?
    public let input_max_length: Int?
    public let webhook: StepHookConfig?
    public let style: ChatStyleConfig?

    var resolvedMaxTurns: Int { max_user_turns ?? 5 }
    var resolvedMinTurns: Int { min_user_turns ?? 1 }
    var isHardLimit: Bool { turn_limit_behavior != "soft" }
}

/// Completion CTA button styling overrides. Mirrors the regular `button`
/// content block shape so product users get the same controls on the
/// chat's end-of-conversation button as they do elsewhere. Any field
/// left nil falls back to the chat theme (user bubble colors) or
/// sensible defaults.
public struct ChatCompletionButton: Codable {
    public let variant: String?          // "primary" | "secondary" | "outline" | "text"
    public let bg_color: String?
    public let text_color: String?
    public let button_corner_radius: Double?
    public let button_height: Double?
    public let style: ChatCompletionButtonStyle?
}

public struct ChatCompletionButtonStyle: Codable {
    public let font_size: Double?
    public let font_weight: Double?
}

/// AI persona configuration.
public struct ChatPersona: Codable {
    public let name: String?
    public let role: String?
    public let avatar_url: String?
}

/// Auto-message shown without user input (e.g., welcome messages).
public struct ChatAutoMessage: Codable, Identifiable {
    public let id: String
    public let turn: Int
    public let delay_ms: Int?
    public let content: String
    public let media: ChatMedia?
}

/// Completion message shown when chat ends.
public struct ChatCompletionMessage: Codable {
    public let content: String
    public let delay_ms: Int?
}

/// Quick reply chip.
public struct ChatQuickReply: Codable, Identifiable {
    public let id: String
    public let text: String
    public let show_at_turn: Int?
}

/// Turn-triggered action (rating prompt, auto message, etc.).
public struct ChatTurnAction: Codable {
    public let turn: Int
    public let type: String   // "rating_prompt", "quick_reply_inject", "auto_message"
    public let config: AnyCodable?
}

/// Media attachment in a chat message.
public struct ChatMedia: Codable {
    public let type: String   // "image", "lottie", "link"
    public let url: String?
    public let alt_text: String?
}

/// Chat styling configuration (14 color tokens).
public struct ChatStyleConfig: Codable {
    public let background_color: String?
    public let ai_bubble_bg: String?
    public let ai_bubble_text: String?
    public let user_bubble_bg: String?
    public let user_bubble_text: String?
    public let input_bg: String?
    public let input_text: String?
    public let input_border: String?
    public let input_font_size: Int?
    public let typing_indicator_color: String?
    public let timestamp_color: String?
    public let quick_reply_bg: String?
    public let quick_reply_text: String?
    public let quick_reply_border: String?
    public let rating_star_color: String?
    public let send_button_color: String?
}

// MARK: - Runtime Chat State (not Codable — used by ChatStepView)

/// A single message in the chat conversation.
struct ChatMessage: Identifiable {
    let id: String
    let role: ChatRole
    let content: String
    let media: ChatMedia?
    let timestamp: Date
    var rating: Int?

    enum ChatRole: String {
        case ai
        case user
        case system
    }
}

/// Chat webhook request payload.
struct ChatWebhookRequest: Codable {
    let event: String       // "chat_message", "chat_started", "chat_completed", "chat_rating"
    let flow_id: String
    let step_id: String
    let app_id: String
    let user_id: String
    let conversation: ChatConversationContext
    let responses: [String: AnyCodable]?
    let rating: Int?
    // Opaque session state round-tripped from prior responses' `data` field.
    // Accumulated across turns; omitted from the wire payload when empty.
    let context: [String: AnyCodable]?
}

struct ChatConversationContext: Codable {
    let turn: Int
    let messages: [ChatMessagePayload]
    let user_message: String?
    let max_turns: Int
    let remaining_turns: Int
}

struct ChatMessagePayload: Codable {
    let role: String
    let content: String
    let id: String
    let timestamp: String
}

/// Chat webhook response payload.
struct ChatWebhookResponse: Codable {
    let action: String?     // "reply", "reply_and_complete", "error"
    let messages: [ChatWebhookMessage]?
    let quick_replies: [ChatQuickReply]?
    let data: [String: AnyCodable]?
    let force_complete: Bool?
    let completion_message: String?
}

struct ChatWebhookMessage: Codable {
    let content: String?
    let media: ChatMedia?
    let delay_ms: Int?
}

// MARK: - Chat Transcript (stored in responses dictionary)

struct ChatTranscript: Codable {
    let transcript: [ChatMessagePayload]
    let user_turn_count: Int
    let total_message_count: Int
    let rating: Int?
    let completion_reason: String  // "max_turns", "user_completed", "ai_completed", "skipped"
    let webhook_data: [String: AnyCodable]?
    let duration_ms: Int
}
