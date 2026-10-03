import Foundation

// MARK: - Multi-type trigger model (SDUI engine prerequisite)
// Extends the existing TriggerRules (MessageConfig) with session, time, screen,
// and trait-based triggers for server-driven UI screens.

public struct UnifiedTriggerRules: Codable {
    public let events: [EventTrigger]?
    public let session_count: SessionTrigger?
    public let days_since_install: TimeTrigger?
    public let on_screen: String?
    public let user_traits: [TraitCondition]?
    public let frequency: FrequencyConfig?
    public let priority: Int?
}

public struct EventTrigger: Codable {
    public let event_name: String?
    public let conditions: [UnifiedTriggerCondition]?
}

/// Trigger condition for unified rules. Named `UnifiedTriggerCondition` to avoid
/// collision with the existing `TriggerCondition` in MessageConfig.swift.
public struct UnifiedTriggerCondition: Codable {
    public let field: String?
    public let `operator`: String?
    public let value: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case field
        case `operator` = "operator"
        case value
    }
}

public struct SessionTrigger: Codable {
    public let min: Int?
    public let max: Int?
    public let exact: Int?
}

public struct TimeTrigger: Codable {
    public let min: Int?  // Days
    public let max: Int?  // Days
}

public struct TraitCondition: Codable {
    public let trait: String?
    public let `operator`: String?
    public let value: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case trait
        case `operator` = "operator"
        case value
    }
}

public struct FrequencyConfig: Codable {
    public let max_impressions: Int?
    public let cooldown_hours: Int?
    public let once_per_session: Bool?
}
