import XCTest
@testable import AppDNASDK

/// Comprehensive JSON decoding tests for MessageConfig and related types.
/// Ensures the SDK correctly parses Firestore in-app message configs —
/// the #1 production risk is field-name mismatches between backend and SDK.
final class MessageConfigDecodingTests: XCTestCase {

    // MARK: - Full MessageConfig decoding

    func testDecodeFullMessageConfig() throws {
        let json = """
        {
            "name": "Streak Reward",
            "message_type": "modal",
            "content": {
                "title": "7-Day Streak!",
                "body": "Keep it up!",
                "image_url": "https://cdn.example.com/streak.png",
                "cta_text": "Claim Reward",
                "cta_action": { "type": "deep_link", "url": "myapp://rewards" },
                "dismiss_text": "Later",
                "background_color": "#1A1A2E",
                "banner_position": "top",
                "auto_dismiss_seconds": 5,
                "text_color": "#FFFFFF",
                "button_color": "#6366F1",
                "corner_radius": 16,
                "secondary_cta_text": "Learn More"
            },
            "trigger_rules": {
                "event": "session_start",
                "conditions": [
                    { "field": "streak_days", "operator": "gte", "value": 7 }
                ],
                "frequency": "once",
                "max_displays": 1,
                "delay_seconds": 2
            },
            "priority": 10,
            "start_date": "2026-02-01",
            "end_date": "2026-03-01"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(MessageConfig.self, from: json)

        XCTAssertEqual(config.name, "Streak Reward")
        XCTAssertEqual(config.message_type, .modal)
        XCTAssertEqual(config.content?.title, "7-Day Streak!")
        XCTAssertEqual(config.content?.body, "Keep it up!")
        XCTAssertEqual(config.content?.image_url, "https://cdn.example.com/streak.png")
        XCTAssertEqual(config.content?.cta_text, "Claim Reward")
        XCTAssertEqual(config.content?.cta_action?.type, .deep_link)
        XCTAssertEqual(config.content?.cta_action?.url, "myapp://rewards")
        XCTAssertEqual(config.content?.dismiss_text, "Later")
        XCTAssertEqual(config.content?.background_color, "#1A1A2E")
        XCTAssertEqual(config.content?.banner_position, .top)
        XCTAssertEqual(config.content?.auto_dismiss_seconds, 5)
        XCTAssertEqual(config.content?.text_color, "#FFFFFF")
        XCTAssertEqual(config.content?.button_color, "#6366F1")
        XCTAssertEqual(config.content?.corner_radius, 16)
        XCTAssertEqual(config.content?.secondary_cta_text, "Learn More")
        XCTAssertEqual(config.trigger_rules?.event, "session_start")
        XCTAssertEqual(config.trigger_rules?.frequency, .once)
        XCTAssertEqual(config.trigger_rules?.max_displays, 1)
        XCTAssertEqual(config.trigger_rules?.delay_seconds, 2)
        XCTAssertEqual(config.trigger_rules?.conditions?.count, 1)
        XCTAssertEqual(config.priority, 10)
        XCTAssertEqual(config.start_date, "2026-02-01")
        XCTAssertEqual(config.end_date, "2026-03-01")
    }

    // MARK: - MessageType variants

    func testDecodeMessageTypeBanner() throws {
        let json = messageJSON(type: "banner")
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.message_type, .banner)
    }

    func testDecodeMessageTypeModal() throws {
        let json = messageJSON(type: "modal")
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.message_type, .modal)
    }

    func testDecodeMessageTypeFullscreen() throws {
        let json = messageJSON(type: "fullscreen")
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.message_type, .fullscreen)
    }

    func testDecodeMessageTypeTooltip() throws {
        let json = messageJSON(type: "tooltip")
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.message_type, .tooltip)
    }

    func testDecodeUnknownMessageTypeFallsBackToUnknown() throws {
        let json = messageJSON(type: "popup")
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.message_type, .unknown)
    }

    // MARK: - MessageContent fields

    func testDecodeMessageContentAllFields() throws {
        let json = """
        {
            "title": "Welcome!",
            "body": "Tap to continue",
            "image_url": "https://cdn.example.com/img.png",
            "cta_text": "Got it",
            "cta_action": { "type": "dismiss" },
            "dismiss_text": "Skip",
            "background_color": "#FFFFFF",
            "banner_position": "bottom",
            "auto_dismiss_seconds": 10,
            "text_color": "#000000",
            "button_color": "#FF5733",
            "corner_radius": 20,
            "secondary_cta_text": "Details"
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertEqual(content.title, "Welcome!")
        XCTAssertEqual(content.body, "Tap to continue")
        XCTAssertEqual(content.image_url, "https://cdn.example.com/img.png")
        XCTAssertEqual(content.cta_text, "Got it")
        XCTAssertEqual(content.cta_action?.type, .dismiss)
        XCTAssertNil(content.cta_action?.url)
        XCTAssertEqual(content.dismiss_text, "Skip")
        XCTAssertEqual(content.background_color, "#FFFFFF")
        XCTAssertEqual(content.banner_position, .bottom)
        XCTAssertEqual(content.auto_dismiss_seconds, 10)
        XCTAssertEqual(content.text_color, "#000000")
        XCTAssertEqual(content.button_color, "#FF5733")
        XCTAssertEqual(content.corner_radius, 20)
        XCTAssertEqual(content.secondary_cta_text, "Details")
    }

    func testDecodeMessageContentMinimal() throws {
        let json = """
        {}
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertNil(content.title)
        XCTAssertNil(content.body)
        XCTAssertNil(content.image_url)
        XCTAssertNil(content.cta_text)
        XCTAssertNil(content.cta_action)
        XCTAssertNil(content.dismiss_text)
        XCTAssertNil(content.background_color)
        XCTAssertNil(content.banner_position)
        XCTAssertNil(content.auto_dismiss_seconds)
        XCTAssertNil(content.text_color)
        XCTAssertNil(content.button_color)
        XCTAssertNil(content.corner_radius)
        XCTAssertNil(content.secondary_cta_text)
        XCTAssertNil(content.lottie_url)
        XCTAssertNil(content.rive_url)
        XCTAssertNil(content.video_url)
        XCTAssertNil(content.haptic)
        XCTAssertNil(content.particle_effect)
        XCTAssertNil(content.blur_backdrop)
    }

    // MARK: - Rich media fields

    func testDecodeRichMediaLottie() throws {
        let json = """
        {
            "lottie_url": "https://cdn.example.com/anim.lottie"
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertEqual(content.lottie_url, "https://cdn.example.com/anim.lottie")
    }

    func testDecodeRichMediaRive() throws {
        let json = """
        {
            "rive_url": "https://cdn.example.com/anim.riv",
            "rive_state_machine": "idle"
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertEqual(content.rive_url, "https://cdn.example.com/anim.riv")
        XCTAssertEqual(content.rive_state_machine, "idle")
    }

    func testDecodeRichMediaVideo() throws {
        let json = """
        {
            "video_url": "https://cdn.example.com/hero.mp4",
            "video_thumbnail_url": "https://cdn.example.com/thumb.jpg"
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertEqual(content.video_url, "https://cdn.example.com/hero.mp4")
        XCTAssertEqual(content.video_thumbnail_url, "https://cdn.example.com/thumb.jpg")
    }

    func testDecodeRichMediaCTAIcons() throws {
        let json = """
        {
            "cta_icon": { "library": "lucide", "name": "arrow-right", "color": "#FFFFFF", "size": 20 },
            "secondary_cta_icon": { "library": "sf-symbols", "name": "info.circle.fill" }
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertNotNil(content.cta_icon)
        XCTAssertEqual(content.cta_icon?.library, "lucide")
        XCTAssertEqual(content.cta_icon?.name, "arrow-right")
        XCTAssertEqual(content.cta_icon?.color, "#FFFFFF")
        XCTAssertEqual(content.cta_icon?.size, 20)
        XCTAssertNotNil(content.secondary_cta_icon)
        XCTAssertEqual(content.secondary_cta_icon?.library, "sf-symbols")
        XCTAssertEqual(content.secondary_cta_icon?.name, "info.circle.fill")
        XCTAssertNil(content.secondary_cta_icon?.color)
        XCTAssertNil(content.secondary_cta_icon?.size)
    }

    func testDecodeRichMediaHaptic() throws {
        let json = """
        {
            "haptic": {
                "enabled": true,
                "triggers": {
                    "on_step_advance": "medium",
                    "on_button_tap": "light",
                    "on_success": "success"
                }
            }
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertNotNil(content.haptic)
        XCTAssertEqual(content.haptic?.enabled, true)
        XCTAssertEqual(content.haptic?.triggers?.on_step_advance, .medium)
        XCTAssertEqual(content.haptic?.triggers?.on_button_tap, .light)
        XCTAssertEqual(content.haptic?.triggers?.on_success, .success)
        XCTAssertNil(content.haptic?.triggers?.on_plan_select)
        XCTAssertNil(content.haptic?.triggers?.on_option_select)
        XCTAssertNil(content.haptic?.triggers?.on_toggle)
        XCTAssertNil(content.haptic?.triggers?.on_form_submit)
        XCTAssertNil(content.haptic?.triggers?.on_error)
    }

    func testDecodeRichMediaParticleEffect() throws {
        let json = """
        {
            "particle_effect": {
                "type": "confetti",
                "trigger": "on_appear",
                "duration_ms": 3000,
                "intensity": "heavy",
                "colors": ["#FF0000", "#00FF00", "#0000FF"]
            }
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertNotNil(content.particle_effect)
        XCTAssertEqual(content.particle_effect?.type, "confetti")
        XCTAssertEqual(content.particle_effect?.trigger, "on_appear")
        XCTAssertEqual(content.particle_effect?.duration_ms, 3000)
        XCTAssertEqual(content.particle_effect?.intensity, "heavy")
        XCTAssertEqual(content.particle_effect?.colors, ["#FF0000", "#00FF00", "#0000FF"])
    }

    func testDecodeRichMediaParticleEffectNilColors() throws {
        let json = """
        {
            "particle_effect": {
                "type": "sparkle",
                "trigger": "on_step_complete",
                "duration_ms": 2000,
                "intensity": "light"
            }
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertNotNil(content.particle_effect)
        XCTAssertEqual(content.particle_effect?.type, "sparkle")
        XCTAssertEqual(content.particle_effect?.trigger, "on_step_complete")
        XCTAssertEqual(content.particle_effect?.intensity, "light")
        XCTAssertNil(content.particle_effect?.colors)
    }

    func testDecodeRichMediaBlurBackdrop() throws {
        let json = """
        {
            "blur_backdrop": {
                "radius": 20.0,
                "tint": "#00000066",
                "saturation": 1.5
            }
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertNotNil(content.blur_backdrop)
        XCTAssertEqual(content.blur_backdrop?.radius, 20.0)
        XCTAssertEqual(content.blur_backdrop?.tint, "#00000066")
        XCTAssertEqual(content.blur_backdrop?.saturation, 1.5)
    }

    func testDecodeRichMediaBlurBackdropMinimal() throws {
        let json = """
        {
            "blur_backdrop": {
                "radius": 10.0
            }
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertNotNil(content.blur_backdrop)
        XCTAssertEqual(content.blur_backdrop?.radius, 10.0)
        XCTAssertNil(content.blur_backdrop?.tint)
        XCTAssertNil(content.blur_backdrop?.saturation)
    }

    func testDecodeAllRichMediaFieldsTogether() throws {
        let json = """
        {
            "title": "Congrats!",
            "lottie_url": "https://cdn.example.com/confetti.lottie",
            "rive_url": "https://cdn.example.com/mascot.riv",
            "rive_state_machine": "celebrate",
            "video_url": "https://cdn.example.com/hero.mp4",
            "video_thumbnail_url": "https://cdn.example.com/thumb.jpg",
            "cta_icon": { "library": "emoji", "name": "\u{1F389}" },
            "secondary_cta_icon": { "library": "material", "name": "share", "size": 18 },
            "haptic": {
                "enabled": true,
                "triggers": { "on_button_tap": "heavy" }
            },
            "particle_effect": {
                "type": "fireworks",
                "trigger": "on_appear",
                "duration_ms": 5000,
                "intensity": "heavy",
                "colors": ["#FFD700", "#FF4500"]
            },
            "blur_backdrop": { "radius": 25.0, "tint": "#FFFFFF33", "saturation": 2.0 }
        }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertEqual(content.title, "Congrats!")
        XCTAssertEqual(content.lottie_url, "https://cdn.example.com/confetti.lottie")
        XCTAssertEqual(content.rive_url, "https://cdn.example.com/mascot.riv")
        XCTAssertEqual(content.rive_state_machine, "celebrate")
        XCTAssertEqual(content.video_url, "https://cdn.example.com/hero.mp4")
        XCTAssertEqual(content.video_thumbnail_url, "https://cdn.example.com/thumb.jpg")
        XCTAssertEqual(content.cta_icon?.library, "emoji")
        XCTAssertEqual(content.secondary_cta_icon?.library, "material")
        XCTAssertEqual(content.secondary_cta_icon?.size, 18)
        XCTAssertEqual(content.haptic?.enabled, true)
        XCTAssertEqual(content.haptic?.triggers?.on_button_tap, .heavy)
        XCTAssertEqual(content.particle_effect?.type, "fireworks")
        XCTAssertEqual(content.particle_effect?.colors, ["#FFD700", "#FF4500"])
        XCTAssertEqual(content.blur_backdrop?.radius, 25.0)
        XCTAssertEqual(content.blur_backdrop?.saturation, 2.0)
    }

    // MARK: - TriggerRules decoding

    func testDecodeTriggerRulesMinimal() throws {
        let json = """
        {
            "event": "app_open",
            "frequency": "every_time"
        }
        """.data(using: .utf8)!

        let rules = try JSONDecoder().decode(TriggerRules.self, from: json)
        XCTAssertEqual(rules.event, "app_open")
        XCTAssertEqual(rules.frequency, .every_time)
        XCTAssertNil(rules.conditions)
        XCTAssertNil(rules.max_displays)
        XCTAssertNil(rules.delay_seconds)
    }

    func testDecodeTriggerRulesWithAllFields() throws {
        let json = """
        {
            "event": "purchase_completed",
            "conditions": [
                { "field": "amount", "operator": "gte", "value": 99 },
                { "field": "currency", "operator": "eq", "value": "USD" }
            ],
            "frequency": "max_times",
            "max_displays": 3,
            "delay_seconds": 5
        }
        """.data(using: .utf8)!

        let rules = try JSONDecoder().decode(TriggerRules.self, from: json)
        XCTAssertEqual(rules.event, "purchase_completed")
        XCTAssertEqual(rules.conditions?.count, 2)
        XCTAssertEqual(rules.conditions?[0].field, "amount")
        XCTAssertEqual(rules.conditions?[0].operator, .gte)
        XCTAssertEqual(rules.conditions?[1].field, "currency")
        XCTAssertEqual(rules.conditions?[1].operator, .eq)
        XCTAssertEqual(rules.frequency, .max_times)
        XCTAssertEqual(rules.max_displays, 3)
        XCTAssertEqual(rules.delay_seconds, 5)
    }

    // MARK: - TriggerCondition operators

    func testDecodeTriggerConditionAllOperators() throws {
        let operators: [(String, TriggerCondition.ConditionOperator)] = [
            ("eq", .eq), ("gte", .gte), ("lte", .lte),
            ("gt", .gt), ("lt", .lt), ("contains", .contains),
        ]

        for (raw, expected) in operators {
            let json = """
            { "field": "x", "operator": "\(raw)", "value": 1 }
            """.data(using: .utf8)!

            let cond = try JSONDecoder().decode(TriggerCondition.self, from: json)
            XCTAssertEqual(cond.operator, expected, "Failed for operator \(raw)")
        }
    }

    func testDecodeTriggerConditionStringValue() throws {
        let json = """
        { "field": "plan", "operator": "eq", "value": "premium" }
        """.data(using: .utf8)!

        let cond = try JSONDecoder().decode(TriggerCondition.self, from: json)
        XCTAssertEqual(cond.field, "plan")
        XCTAssertEqual(cond.operator, .eq)
        // AnyCodable wraps the value
        XCTAssertEqual(cond.value?.value as? String, "premium")
    }

    func testDecodeTriggerConditionBoolValue() throws {
        let json = """
        { "field": "is_premium", "operator": "eq", "value": true }
        """.data(using: .utf8)!

        let cond = try JSONDecoder().decode(TriggerCondition.self, from: json)
        XCTAssertEqual(cond.field, "is_premium")
        XCTAssertEqual(cond.value?.value as? Bool, true)
    }

    func testDecodeTriggerConditionDoubleValue() throws {
        let json = """
        { "field": "score", "operator": "gte", "value": 4.5 }
        """.data(using: .utf8)!

        let cond = try JSONDecoder().decode(TriggerCondition.self, from: json)
        XCTAssertEqual(cond.field, "score")
        XCTAssertEqual(cond.value?.value as? Double, 4.5)
    }

    // MARK: - CTA Action types

    func testDecodeCTAActionDeepLink() throws {
        let json = """
        { "type": "deep_link", "url": "myapp://settings" }
        """.data(using: .utf8)!

        let action = try JSONDecoder().decode(CTAAction.self, from: json)
        XCTAssertEqual(action.type, .deep_link)
        XCTAssertEqual(action.url, "myapp://settings")
    }

    func testDecodeCTAActionOpenURL() throws {
        let json = """
        { "type": "open_url", "url": "https://example.com" }
        """.data(using: .utf8)!

        let action = try JSONDecoder().decode(CTAAction.self, from: json)
        XCTAssertEqual(action.type, .open_url)
        XCTAssertEqual(action.url, "https://example.com")
    }

    func testDecodeCTAActionDismiss() throws {
        let json = """
        { "type": "dismiss" }
        """.data(using: .utf8)!

        let action = try JSONDecoder().decode(CTAAction.self, from: json)
        XCTAssertEqual(action.type, .dismiss)
        XCTAssertNil(action.url)
    }

    func testDecodeUnknownCTAActionTypeFallsBackToUnknown() throws {
        let json = """
        { "type": "custom_action" }
        """.data(using: .utf8)!

        let action = try JSONDecoder().decode(CTAAction.self, from: json)
        XCTAssertEqual(action.type, .unknown)
    }

    // MARK: - MessageFrequency variants

    func testDecodeAllMessageFrequencies() throws {
        let variants: [(String, MessageFrequency)] = [
            ("once", .once),
            ("once_per_session", .once_per_session),
            ("every_time", .every_time),
            ("max_times", .max_times),
        ]

        for (raw, expected) in variants {
            let json = """
            {
                "event": "test",
                "frequency": "\(raw)"
            }
            """.data(using: .utf8)!

            let rules = try JSONDecoder().decode(TriggerRules.self, from: json)
            XCTAssertEqual(rules.frequency, expected, "Failed for frequency \(raw)")
        }
    }

    // MARK: - BannerPosition

    func testDecodeBannerPositionTop() throws {
        let json = """
        { "banner_position": "top" }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertEqual(content.banner_position, .top)
    }

    func testDecodeBannerPositionBottom() throws {
        let json = """
        { "banner_position": "bottom" }
        """.data(using: .utf8)!

        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        XCTAssertEqual(content.banner_position, .bottom)
    }

    // MARK: - Date constraints

    func testDecodeMessageWithDates() throws {
        let json = messageJSON(type: "modal", startDate: "2026-01-15", endDate: "2026-06-30")
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.start_date, "2026-01-15")
        XCTAssertEqual(config.end_date, "2026-06-30")
    }

    func testDecodeMessageWithNullDates() throws {
        let json = messageJSON(type: "banner", startDate: nil, endDate: nil)
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertNil(config.start_date)
        XCTAssertNil(config.end_date)
    }

    // MARK: - MessageRoot (Firestore wrapper)

    func testDecodeMessageRoot() throws {
        let json = """
        {
            "version": 3,
            "messages": {
                "msg_streak_reward": {
                    "name": "Streak Reward",
                    "message_type": "modal",
                    "content": { "title": "Nice!" },
                    "trigger_rules": { "event": "session_start", "frequency": "once" },
                    "priority": 5
                },
                "msg_welcome": {
                    "name": "Welcome Banner",
                    "message_type": "banner",
                    "content": { "title": "Welcome!", "banner_position": "top" },
                    "trigger_rules": { "event": "app_open", "frequency": "once_per_session" },
                    "priority": 1
                }
            }
        }
        """.data(using: .utf8)!

        let root = try JSONDecoder().decode(MessageRoot.self, from: json)
        XCTAssertEqual(root.version, 3)
        XCTAssertEqual(root.messages?.count, 2)
        XCTAssertEqual(root.messages?["msg_streak_reward"]?.message_type, .modal)
        XCTAssertEqual(root.messages?["msg_welcome"]?.message_type, .banner)
        XCTAssertEqual(root.messages?["msg_welcome"]?.content?.banner_position, .top)
    }

    func testDecodeMessageRootEmptyMessages() throws {
        let json = """
        { "version": 1, "messages": {} }
        """.data(using: .utf8)!

        let root = try JSONDecoder().decode(MessageRoot.self, from: json)
        XCTAssertEqual(root.version, 1)
        XCTAssertEqual(root.messages?.isEmpty, true)
    }

    // MARK: - Edge cases

    func testDecodeMinimalMessage() throws {
        let json = """
        {
            "name": "Minimal",
            "message_type": "banner",
            "content": {},
            "trigger_rules": { "event": "app_open", "frequency": "every_time" },
            "priority": 0
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.name, "Minimal")
        XCTAssertEqual(config.message_type, .banner)
        XCTAssertNil(config.content?.title)
        XCTAssertNil(config.content?.body)
        XCTAssertNil(config.start_date)
        XCTAssertNil(config.end_date)
        XCTAssertEqual(config.priority, 0)
    }

    func testDecodeMessageIgnoresExtraFields() throws {
        let json = """
        {
            "name": "Forward-Compat",
            "message_type": "modal",
            "content": { "title": "Hi", "future_field": "ignored" },
            "trigger_rules": { "event": "test", "frequency": "once" },
            "priority": 1,
            "some_new_backend_field": true
        }
        """.data(using: .utf8)!

        // Should decode without throwing -- unknown fields are ignored by default Codable
        let config = try JSONDecoder().decode(MessageConfig.self, from: json)
        XCTAssertEqual(config.name, "Forward-Compat")
        XCTAssertEqual(config.content?.title, "Hi")
    }

    func testDecodeMultipleConditions() throws {
        let json = """
        {
            "event": "level_up",
            "conditions": [
                { "field": "level", "operator": "gte", "value": 10 },
                { "field": "level", "operator": "lt", "value": 20 },
                { "field": "is_premium", "operator": "eq", "value": false },
                { "field": "country", "operator": "contains", "value": "US" }
            ],
            "frequency": "once"
        }
        """.data(using: .utf8)!

        let rules = try JSONDecoder().decode(TriggerRules.self, from: json)
        XCTAssertEqual(rules.conditions?.count, 4)
        XCTAssertEqual(rules.conditions?[0].operator, .gte)
        XCTAssertEqual(rules.conditions?[1].operator, .lt)
        XCTAssertEqual(rules.conditions?[2].operator, .eq)
        XCTAssertEqual(rules.conditions?[3].operator, .contains)
    }

    func testEncodeAndDecodeMessageConfigRoundTrip() throws {
        let original = MessageConfig(
            name: "Roundtrip",
            message_type: .fullscreen,
            content: MessageContent(
                title: "Full Screen",
                body: "Body text",
                image_url: "https://cdn.example.com/bg.jpg",
                cta_text: "OK",
                cta_action: CTAAction(type: .open_url, url: "https://example.com"),
                dismiss_text: nil,
                background_color: "#000000",
                banner_position: nil,
                auto_dismiss_seconds: nil,
                text_color: "#FFFFFF",
                button_color: "#6366F1",
                button_text_color: nil,
                button_corner_radius: nil,
                corner_radius: 8,
                secondary_cta_text: nil,
                lottie_url: nil,
                rive_url: nil,
                rive_state_machine: nil,
                video_url: nil,
                video_thumbnail_url: nil,
                cta_icon: nil,
                secondary_cta_icon: nil,
                haptic: nil,
                particle_effect: nil,
                blur_backdrop: nil
            ),
            trigger_rules: TriggerRules(
                event: "onboarding_complete",
                conditions: nil,
                frequency: .once,
                max_displays: nil,
                delay_seconds: nil
            ),
            priority: 5,
            start_date: nil,
            end_date: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(MessageConfig.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.message_type, original.message_type)
        XCTAssertEqual(decoded.content?.title, original.content?.title)
        XCTAssertEqual(decoded.content?.body, original.content?.body)
        XCTAssertEqual(decoded.content?.cta_action?.type, original.content?.cta_action?.type)
        XCTAssertEqual(decoded.content?.cta_action?.url, original.content?.cta_action?.url)
        XCTAssertEqual(decoded.trigger_rules?.event, original.trigger_rules?.event)
        XCTAssertEqual(decoded.trigger_rules?.frequency, original.trigger_rules?.frequency)
        XCTAssertEqual(decoded.priority, original.priority)
    }

    func testDecodeIconReferenceAllLibraries() throws {
        let libraries = ["lucide", "sf-symbols", "material", "emoji"]
        for lib in libraries {
            let json = """
            { "library": "\(lib)", "name": "star", "color": "#FFAA00", "size": 24 }
            """.data(using: .utf8)!

            let icon = try JSONDecoder().decode(IconReference.self, from: json)
            XCTAssertEqual(icon.library, lib, "Failed for library \(lib)")
            XCTAssertEqual(icon.name, "star")
            XCTAssertEqual(icon.color, "#FFAA00")
            XCTAssertEqual(icon.size, 24)
        }
    }

    func testDecodeIconReferenceMinimal() throws {
        let json = """
        { "library": "emoji", "name": "fire" }
        """.data(using: .utf8)!

        let icon = try JSONDecoder().decode(IconReference.self, from: json)
        XCTAssertEqual(icon.library, "emoji")
        XCTAssertEqual(icon.name, "fire")
        XCTAssertNil(icon.color)
        XCTAssertNil(icon.size)
    }

    // MARK: - HapticConfig decoding

    func testDecodeHapticConfigAllTriggers() throws {
        let json = """
        {
            "enabled": true,
            "triggers": {
                "on_step_advance": "medium",
                "on_button_tap": "light",
                "on_plan_select": "selection",
                "on_option_select": "selection",
                "on_toggle": "light",
                "on_form_submit": "success",
                "on_error": "error",
                "on_success": "success"
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(HapticConfig.self, from: json)
        XCTAssertEqual(config.enabled, true)
        XCTAssertEqual(config.triggers?.on_step_advance, .medium)
        XCTAssertEqual(config.triggers?.on_button_tap, .light)
        XCTAssertEqual(config.triggers?.on_plan_select, .selection)
        XCTAssertEqual(config.triggers?.on_option_select, .selection)
        XCTAssertEqual(config.triggers?.on_toggle, .light)
        XCTAssertEqual(config.triggers?.on_form_submit, .success)
        XCTAssertEqual(config.triggers?.on_error, .error)
        XCTAssertEqual(config.triggers?.on_success, .success)
    }

    func testDecodeHapticConfigDisabled() throws {
        let json = """
        {
            "enabled": false,
            "triggers": {}
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(HapticConfig.self, from: json)
        XCTAssertEqual(config.enabled, false)
        XCTAssertNil(config.triggers?.on_button_tap)
    }

    func testDecodeAllHapticTypes() throws {
        let types: [(String, HapticType)] = [
            ("light", .light), ("medium", .medium), ("heavy", .heavy),
            ("selection", .selection), ("success", .success),
            ("warning", .warning), ("error", .error),
        ]
        for (raw, expected) in types {
            let json = """
            {
                "enabled": true,
                "triggers": { "on_button_tap": "\(raw)" }
            }
            """.data(using: .utf8)!

            let config = try JSONDecoder().decode(HapticConfig.self, from: json)
            XCTAssertEqual(config.triggers?.on_button_tap, expected, "Failed for haptic type \(raw)")
        }
    }

    // MARK: - Helpers

    /// Builds a minimal valid MessageConfig JSON with the given message_type.
    private func messageJSON(type: String, startDate: String? = nil, endDate: String? = nil) -> Data {
        let start = startDate.map { "\"\($0)\"" } ?? "null"
        let end = endDate.map { "\"\($0)\"" } ?? "null"
        return """
        {
            "name": "Test \(type)",
            "message_type": "\(type)",
            "content": { "title": "Hello" },
            "trigger_rules": { "event": "test", "frequency": "once" },
            "priority": 1,
            "start_date": \(start),
            "end_date": \(end)
        }
        """.data(using: .utf8)!
    }
}
