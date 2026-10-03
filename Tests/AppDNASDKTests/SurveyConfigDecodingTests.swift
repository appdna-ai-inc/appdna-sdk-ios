import XCTest
@testable import AppDNASDK

final class SurveyConfigDecodingTests: XCTestCase {

    // MARK: - Full config decoding

    func testDecodeFullSurveyConfig() throws {
        let json = """
        {
            "name": "Post-Purchase NPS",
            "survey_type": "nps",
            "questions": [
                {
                    "id": "q1",
                    "type": "nps",
                    "text": "How likely are you to recommend us?",
                    "required": true,
                    "nps_config": {
                        "low_label": "Not likely",
                        "high_label": "Very likely"
                    }
                },
                {
                    "id": "q2",
                    "type": "free_text",
                    "text": "Tell us more",
                    "required": false,
                    "free_text_config": {
                        "placeholder": "Your feedback...",
                        "max_length": 300
                    }
                }
            ],
            "trigger_rules": {
                "event": "purchase_completed",
                "conditions": [
                    {
                        "field": "order_total",
                        "operator": "gte",
                        "value": 50
                    }
                ],
                "love_score_range": {
                    "min": 0,
                    "max": 100
                },
                "frequency": "once",
                "max_displays": 3,
                "delay_seconds": 5,
                "min_sessions": 2
            },
            "appearance": {
                "presentation": "bottom_sheet",
                "theme": {
                    "background_color": "#FFFFFF",
                    "text_color": "#1A1A1A",
                    "accent_color": "#007AFF",
                    "button_color": "#007AFF",
                    "font_family": "System"
                },
                "dismiss_allowed": true,
                "show_progress": true,
                "corner_radius": 16
            },
            "follow_up_actions": {
                "on_positive": {
                    "action": "prompt_review",
                    "message": "Thank you! Would you mind leaving a review?"
                },
                "on_negative": {
                    "action": "show_feedback_form",
                    "message": "We're sorry. How can we improve?"
                },
                "on_neutral": {
                    "action": "dismiss",
                    "message": "Thanks for your feedback!"
                }
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(SurveyConfig.self, from: json)

        XCTAssertEqual(config.name, "Post-Purchase NPS")
        XCTAssertEqual(config.survey_type, "nps")
        XCTAssertEqual(config.questions?.count, 2)
        XCTAssertEqual(config.trigger_rules?.event, "purchase_completed")
        XCTAssertEqual(config.appearance?.presentation, "bottom_sheet")
        XCTAssertNotNil(config.follow_up_actions)
    }

    // MARK: - SurveyRoot decoding

    func testDecodeSurveyRoot() throws {
        let json = """
        {
            "version": 2,
            "surveys": {
                "survey_nps_1": {
                    "name": "NPS Survey",
                    "survey_type": "nps",
                    "questions": [
                        {
                            "id": "q1",
                            "type": "nps",
                            "text": "Rate us",
                            "required": true
                        }
                    ],
                    "trigger_rules": {
                        "event": "app_open",
                        "frequency": "once_per_session"
                    },
                    "appearance": {
                        "presentation": "modal",
                        "dismiss_allowed": true,
                        "show_progress": false
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let root = try JSONDecoder().decode(SurveyRoot.self, from: json)

        XCTAssertEqual(root.version, 2)
        XCTAssertEqual(root.surveys?.count, 1)
        XCTAssertNotNil(root.surveys?["survey_nps_1"])
        XCTAssertEqual(root.surveys?["survey_nps_1"]?.name, "NPS Survey")
    }

    // MARK: - Question type: NPS

    func testDecodeNPSQuestion() throws {
        let json = """
        {
            "id": "nps_q",
            "type": "nps",
            "text": "How likely are you to recommend us to a friend?",
            "required": true,
            "nps_config": {
                "low_label": "Not at all likely",
                "high_label": "Extremely likely"
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "nps_q")
        XCTAssertEqual(question.type, "nps")
        XCTAssertEqual(question.text, "How likely are you to recommend us to a friend?")
        XCTAssertTrue(question.required ?? false)
        XCTAssertNotNil(question.nps_config)
        XCTAssertEqual(question.nps_config?.low_label, "Not at all likely")
        XCTAssertEqual(question.nps_config?.high_label, "Extremely likely")
        XCTAssertNil(question.csat_config)
        XCTAssertNil(question.rating_config)
        XCTAssertNil(question.options)
        XCTAssertNil(question.emoji_config)
        XCTAssertNil(question.free_text_config)
        XCTAssertNil(question.show_if)
        XCTAssertNil(question.image_url)
    }

    func testDecodeNPSConfigWithNilLabels() throws {
        let json = """
        {
            "id": "nps_default",
            "type": "nps",
            "text": "Rate us",
            "required": true,
            "nps_config": {}
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertNotNil(question.nps_config)
        XCTAssertNil(question.nps_config?.low_label)
        XCTAssertNil(question.nps_config?.high_label)
    }

    // MARK: - Question type: CSAT

    func testDecodeCSATQuestion() throws {
        let json = """
        {
            "id": "csat_q",
            "type": "csat",
            "text": "How satisfied are you with our service?",
            "required": true,
            "csat_config": {
                "max_rating": 5,
                "style": "star"
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "csat_q")
        XCTAssertEqual(question.type, "csat")
        XCTAssertEqual(question.text, "How satisfied are you with our service?")
        XCTAssertTrue(question.required ?? false)
        XCTAssertNotNil(question.csat_config)
        XCTAssertEqual(question.csat_config?.resolvedMax, 5)
        XCTAssertEqual(question.csat_config?.style, "star")
        XCTAssertNil(question.nps_config)
    }

    func testDecodeCSATQuestionEmojiStyle() throws {
        let json = """
        {
            "id": "csat_emoji",
            "type": "csat",
            "text": "Rate your experience",
            "required": false,
            "csat_config": {
                "max_rating": 3,
                "style": "emoji"
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.csat_config?.style, "emoji")
        XCTAssertEqual(question.csat_config?.resolvedMax, 3)
        XCTAssertFalse(question.required ?? true)
    }

    func testDecodeCSATConfigWithNilFields() throws {
        let json = """
        {
            "id": "csat_default",
            "type": "csat",
            "text": "Rate us",
            "required": true,
            "csat_config": {}
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertNotNil(question.csat_config)
        XCTAssertEqual(question.csat_config?.resolvedMax, 5) // defaults to 5 when empty
        XCTAssertNil(question.csat_config?.style)
    }

    // MARK: - Question type: Rating

    func testDecodeRatingQuestion() throws {
        let json = """
        {
            "id": "rating_q",
            "type": "rating",
            "text": "How would you rate our app?",
            "required": true,
            "rating_config": {
                "max_rating": 5,
                "style": "star"
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "rating_q")
        XCTAssertEqual(question.type, "rating")
        XCTAssertNotNil(question.rating_config)
        XCTAssertEqual(question.rating_config?.resolvedMax, 5)
        XCTAssertEqual(question.rating_config?.style, "star")
        XCTAssertNil(question.csat_config)
        XCTAssertNil(question.nps_config)
    }

    func testDecodeRatingQuestionHeartStyle() throws {
        let json = """
        {
            "id": "rating_heart",
            "type": "rating",
            "text": "How much do you love this feature?",
            "required": false,
            "rating_config": {
                "max_rating": 3,
                "style": "heart"
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.rating_config?.style, "heart")
        XCTAssertEqual(question.rating_config?.resolvedMax, 3)
    }

    func testDecodeRatingQuestionThumbStyle() throws {
        let json = """
        {
            "id": "rating_thumb",
            "type": "rating",
            "text": "Thumbs up or down?",
            "required": true,
            "rating_config": {
                "style": "thumb"
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.rating_config?.resolvedIcon, "thumb")
        XCTAssertEqual(question.rating_config?.resolvedMax, 5) // defaults to 5 when not set
    }

    // MARK: - Question type: Single choice

    func testDecodeSingleChoiceQuestion() throws {
        let json = """
        {
            "id": "sc_q",
            "type": "single_choice",
            "text": "What feature do you use most?",
            "required": true,
            "options": [
                { "id": "opt_1", "text": "Dashboard" },
                { "id": "opt_2", "text": "Reports", "icon": "chart" },
                { "id": "opt_3", "text": "Settings" }
            ]
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "sc_q")
        XCTAssertEqual(question.type, "single_choice")
        XCTAssertEqual(question.text, "What feature do you use most?")
        XCTAssertTrue(question.required ?? false)
        XCTAssertEqual(question.options?.count, 3)
        XCTAssertEqual(question.options?[0].id, "opt_1")
        XCTAssertEqual(question.options?[0].text, "Dashboard")
        XCTAssertNil(question.options?[0].icon)
        XCTAssertEqual(question.options?[1].icon, "chart")
    }

    // MARK: - Question type: Multi choice

    func testDecodeMultiChoiceQuestion() throws {
        let json = """
        {
            "id": "mc_q",
            "type": "multi_choice",
            "text": "Which features would you like to see improved?",
            "required": false,
            "options": [
                { "id": "opt_a", "text": "Performance", "icon": "zap" },
                { "id": "opt_b", "text": "Design", "icon": "palette" },
                { "id": "opt_c", "text": "Stability" },
                { "id": "opt_d", "text": "New features" }
            ]
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "mc_q")
        XCTAssertEqual(question.type, "multi_choice")
        XCTAssertFalse(question.required ?? true)
        XCTAssertEqual(question.options?.count, 4)
        XCTAssertEqual(question.options?[0].id, "opt_a")
        XCTAssertEqual(question.options?[0].text, "Performance")
        XCTAssertEqual(question.options?[0].icon, "zap")
        XCTAssertNil(question.options?[2].icon)
    }

    // MARK: - Question type: Free text

    func testDecodeFreeTextQuestion() throws {
        let json = """
        {
            "id": "ft_q",
            "type": "free_text",
            "text": "Any additional comments?",
            "required": false,
            "free_text_config": {
                "placeholder": "Type your feedback here...",
                "max_length": 500
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "ft_q")
        XCTAssertEqual(question.type, "free_text")
        XCTAssertEqual(question.text, "Any additional comments?")
        XCTAssertFalse(question.required ?? true)
        XCTAssertNotNil(question.free_text_config)
        XCTAssertEqual(question.free_text_config?.placeholder, "Type your feedback here...")
        XCTAssertEqual(question.free_text_config?.max_length, 500)
        XCTAssertNil(question.options)
    }

    func testDecodeFreeTextConfigWithNilFields() throws {
        let json = """
        {
            "id": "ft_default",
            "type": "free_text",
            "text": "Comments?",
            "required": false,
            "free_text_config": {}
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertNotNil(question.free_text_config)
        XCTAssertNil(question.free_text_config?.placeholder)
        XCTAssertNil(question.free_text_config?.max_length)
    }

    // MARK: - Question type: Yes/No

    func testDecodeYesNoQuestion() throws {
        let json = """
        {
            "id": "yn_q",
            "type": "yes_no",
            "text": "Would you recommend us to a friend?",
            "required": true
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "yn_q")
        XCTAssertEqual(question.type, "yes_no")
        XCTAssertEqual(question.text, "Would you recommend us to a friend?")
        XCTAssertTrue(question.required ?? false)
        XCTAssertNil(question.nps_config)
        XCTAssertNil(question.csat_config)
        XCTAssertNil(question.rating_config)
        XCTAssertNil(question.options)
        XCTAssertNil(question.emoji_config)
        XCTAssertNil(question.free_text_config)
    }

    // MARK: - Question type: Emoji scale

    func testDecodeEmojiScaleQuestion() throws {
        let json = """
        {
            "id": "emoji_q",
            "type": "emoji_scale",
            "text": "How are you feeling today?",
            "required": true,
            "emoji_config": {
                "emojis": ["\u{1F621}", "\u{1F615}", "\u{1F610}", "\u{1F60A}", "\u{1F60D}"]
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "emoji_q")
        XCTAssertEqual(question.type, "emoji_scale")
        XCTAssertNotNil(question.emoji_config)
        XCTAssertEqual(question.emoji_config?.emojis?.count, 5)
        XCTAssertNil(question.nps_config)
        XCTAssertNil(question.options)
    }

    func testDecodeEmojiConfigWithNilEmojis() throws {
        let json = """
        {
            "id": "emoji_default",
            "type": "emoji_scale",
            "text": "How do you feel?",
            "required": false,
            "emoji_config": {}
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertNotNil(question.emoji_config)
        XCTAssertNil(question.emoji_config?.emojis)
    }

    // MARK: - Question with image_url

    func testDecodeQuestionWithImageUrl() throws {
        let json = """
        {
            "id": "img_q",
            "type": "single_choice",
            "text": "Which design do you prefer?",
            "required": true,
            "image_url": "https://cdn.example.com/design_comparison.png",
            "options": [
                { "id": "opt_a", "text": "Design A" },
                { "id": "opt_b", "text": "Design B" }
            ]
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.image_url, "https://cdn.example.com/design_comparison.png")
        XCTAssertEqual(question.options?.count, 2)
    }

    // MARK: - Show-if conditions

    func testDecodeShowIfCondition() throws {
        let json = """
        {
            "id": "conditional_q",
            "type": "free_text",
            "text": "What could we improve?",
            "required": false,
            "show_if": {
                "question_id": "nps_q",
                "answer_in": [0, 1, 2, 3, 4, 5, 6]
            },
            "free_text_config": {
                "placeholder": "Please tell us...",
                "max_length": 1000
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertNotNil(question.show_if)
        XCTAssertEqual(question.show_if?.question_id, "nps_q")
        XCTAssertEqual(question.show_if?.answer_in?.count, 7)
    }

    func testDecodeShowIfConditionWithStringAnswers() throws {
        let json = """
        {
            "id": "followup_q",
            "type": "free_text",
            "text": "Tell us more about your choice",
            "required": false,
            "show_if": {
                "question_id": "sc_q",
                "answer_in": ["opt_2", "opt_3"]
            }
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertNotNil(question.show_if)
        XCTAssertEqual(question.show_if?.question_id, "sc_q")
        XCTAssertEqual(question.show_if?.answer_in?.count, 2)
    }

    func testDecodeShowIfConditionWithMixedAnswerTypes() throws {
        let json = """
        {
            "question_id": "rating_q",
            "answer_in": [1, 2, "low"]
        }
        """.data(using: .utf8)!

        let condition = try JSONDecoder().decode(ShowIfCondition.self, from: json)

        XCTAssertEqual(condition.question_id, "rating_q")
        XCTAssertEqual(condition.answer_in?.count, 3)
    }

    // MARK: - Trigger rules

    func testDecodeTriggerRulesFullConfig() throws {
        let json = """
        {
            "event": "screen_view",
            "conditions": [
                {
                    "field": "screen_name",
                    "operator": "eq",
                    "value": "home"
                },
                {
                    "field": "session_count",
                    "operator": "gte",
                    "value": 5
                }
            ],
            "love_score_range": {
                "min": 60,
                "max": 100
            },
            "frequency": "once",
            "max_displays": 1,
            "delay_seconds": 10,
            "min_sessions": 3
        }
        """.data(using: .utf8)!

        let rules = try JSONDecoder().decode(SurveyTriggerRules.self, from: json)

        XCTAssertEqual(rules.event, "screen_view")
        XCTAssertEqual(rules.conditions?.count, 2)
        XCTAssertEqual(rules.conditions?[0].field, "screen_name")
        XCTAssertEqual(rules.love_score_range?.min, 60)
        XCTAssertEqual(rules.love_score_range?.max, 100)
        XCTAssertEqual(rules.max_displays, 1)
        XCTAssertEqual(rules.delay_seconds, 10)
        XCTAssertEqual(rules.min_sessions, 3)
    }

    func testDecodeTriggerRulesMinimalConfig() throws {
        let json = """
        {
            "event": "app_open",
            "frequency": "every_time"
        }
        """.data(using: .utf8)!

        let rules = try JSONDecoder().decode(SurveyTriggerRules.self, from: json)

        XCTAssertEqual(rules.event, "app_open")
        XCTAssertNil(rules.conditions)
        XCTAssertNil(rules.love_score_range)
        XCTAssertNil(rules.max_displays)
        XCTAssertNil(rules.delay_seconds)
        XCTAssertNil(rules.min_sessions)
    }

    func testDecodeTriggerRulesAllFrequencies() throws {
        let frequencies: [(String, MessageFrequency)] = [
            ("once", .once),
            ("once_per_session", .once_per_session),
            ("every_time", .every_time),
            ("max_times", .max_times),
        ]

        for (jsonValue, expected) in frequencies {
            let json = """
            {
                "event": "test_event",
                "frequency": "\(jsonValue)"
            }
            """.data(using: .utf8)!

            let rules = try JSONDecoder().decode(SurveyTriggerRules.self, from: json)
            XCTAssertEqual(rules.frequency, expected, "Failed for frequency: \(jsonValue)")
        }
    }

    func testDecodeTriggerConditionOperators() throws {
        let operators: [(String, TriggerCondition.ConditionOperator)] = [
            ("eq", .eq),
            ("gte", .gte),
            ("lte", .lte),
            ("gt", .gt),
            ("lt", .lt),
            ("contains", .contains),
        ]

        for (jsonValue, expected) in operators {
            let json = """
            {
                "field": "test_field",
                "operator": "\(jsonValue)",
                "value": "test"
            }
            """.data(using: .utf8)!

            let condition = try JSONDecoder().decode(TriggerCondition.self, from: json)
            XCTAssertEqual(condition.operator, expected, "Failed for operator: \(jsonValue)")
        }
    }

    func testDecodeScoreRange() throws {
        let json = """
        {
            "min": 0,
            "max": 50
        }
        """.data(using: .utf8)!

        let range = try JSONDecoder().decode(ScoreRange.self, from: json)

        XCTAssertEqual(range.min, 0)
        XCTAssertEqual(range.max, 50)
    }

    // MARK: - Appearance

    func testDecodeAppearanceFullConfig() throws {
        let json = """
        {
            "presentation": "modal",
            "theme": {
                "background_color": "#FAFAFA",
                "text_color": "#333333",
                "accent_color": "#FF6600",
                "button_color": "#FF6600",
                "font_family": "Helvetica Neue"
            },
            "dismiss_allowed": false,
            "show_progress": true,
            "corner_radius": 20,
            "question_text_style": {
                "font_family": "Georgia",
                "font_size": 18.0,
                "font_weight": 600,
                "color": "#222222",
                "alignment": "center",
                "line_height": 1.4,
                "letter_spacing": 0.5,
                "opacity": 1.0
            },
            "option_style": {
                "background": {
                    "type": "color",
                    "color": "#F0F0F0"
                },
                "border": {
                    "color": "#CCCCCC",
                    "width": 1.0,
                    "radius": 8.0
                },
                "corner_radius": 12.0,
                "opacity": 0.95
            }
        }
        """.data(using: .utf8)!

        let appearance = try JSONDecoder().decode(SurveyAppearance.self, from: json)

        XCTAssertEqual(appearance.presentation, "modal")
        XCTAssertEqual(appearance.dismiss_allowed, false)
        XCTAssertEqual(appearance.show_progress, true)
        XCTAssertEqual(appearance.corner_radius, 20)

        // Theme: legacy flat theme now decodes through `ThemeSet<SurveyTheme>`;
        // the flat payload is stored as the `light` variant with no `dark`.
        XCTAssertNotNil(appearance.theme)
        XCTAssertEqual(appearance.theme?.light.background_color, "#FAFAFA")
        XCTAssertEqual(appearance.theme?.light.text_color, "#333333")
        XCTAssertEqual(appearance.theme?.light.accent_color, "#FF6600")
        XCTAssertEqual(appearance.theme?.light.button_color, "#FF6600")
        XCTAssertEqual(appearance.theme?.light.font_family, "Helvetica Neue")
        XCTAssertNil(appearance.theme?.dark)

        // Style engine
        XCTAssertNotNil(appearance.question_text_style)
        XCTAssertEqual(appearance.question_text_style?.font_family, "Georgia")
        XCTAssertEqual(appearance.question_text_style?.font_size, 18.0)
        XCTAssertEqual(appearance.question_text_style?.font_weight, 600)
        XCTAssertEqual(appearance.question_text_style?.color, "#222222")
        XCTAssertEqual(appearance.question_text_style?.alignment, "center")
        XCTAssertEqual(appearance.question_text_style?.line_height, 1.4)
        XCTAssertEqual(appearance.question_text_style?.letter_spacing, 0.5)
        XCTAssertEqual(appearance.question_text_style?.opacity, 1.0)

        XCTAssertNotNil(appearance.option_style)
        XCTAssertEqual(appearance.option_style?.corner_radius, 12.0)
        XCTAssertEqual(appearance.option_style?.opacity, 0.95)
    }

    func testDecodeAppearanceDefaultValues() throws {
        let json = """
        {
            "presentation": "bottom_sheet"
        }
        """.data(using: .utf8)!

        let appearance = try JSONDecoder().decode(SurveyAppearance.self, from: json)

        XCTAssertEqual(appearance.presentation, "bottom_sheet")
        XCTAssertEqual(appearance.dismiss_allowed, true, "dismiss_allowed should default to true")
        XCTAssertEqual(appearance.show_progress, false, "show_progress should default to false")
        XCTAssertNil(appearance.theme)
        XCTAssertNil(appearance.question_text_style)
        XCTAssertNil(appearance.option_style)
        XCTAssertNil(appearance.corner_radius)
    }

    func testDecodeAppearancePresentationTypes() throws {
        let types = ["bottom_sheet", "modal", "fullscreen"]

        for presentationType in types {
            let json = """
            {
                "presentation": "\(presentationType)"
            }
            """.data(using: .utf8)!

            let appearance = try JSONDecoder().decode(SurveyAppearance.self, from: json)
            XCTAssertEqual(appearance.presentation, presentationType)
        }
    }

    // MARK: - Appearance: Rich media

    func testDecodeThemeWithRichMedia() throws {
        let json = """
        {
            "background_color": "#FFFFFF",
            "text_color": "#000000",
            "accent_color": "#007AFF",
            "button_color": "#007AFF",
            "font_family": "System",
            "intro_lottie_url": "https://cdn.example.com/intro_anim.json",
            "thankyou_lottie_url": "https://cdn.example.com/thankyou_anim.json",
            "thankyou_particle_effect": {
                "type": "confetti",
                "trigger": "on_flow_complete",
                "duration_ms": 3000,
                "intensity": "heavy",
                "colors": ["#FF0000", "#00FF00", "#0000FF", "#FFD700"]
            },
            "blur_backdrop": {
                "radius": 10.0,
                "tint": "#00000040",
                "saturation": 1.5
            },
            "haptic": {
                "enabled": true,
                "triggers": {
                    "on_step_advance": "medium",
                    "on_button_tap": "light",
                    "on_option_select": "selection"
                }
            },
            "thank_you_text": "Thanks, {{user_name}}! Your feedback means a lot."
        }
        """.data(using: .utf8)!

        let theme = try JSONDecoder().decode(SurveyTheme.self, from: json)

        XCTAssertEqual(theme.background_color, "#FFFFFF")
        XCTAssertEqual(theme.text_color, "#000000")
        XCTAssertEqual(theme.accent_color, "#007AFF")
        XCTAssertEqual(theme.button_color, "#007AFF")
        XCTAssertEqual(theme.font_family, "System")

        // Lottie
        XCTAssertEqual(theme.intro_lottie_url, "https://cdn.example.com/intro_anim.json")
        XCTAssertEqual(theme.thankyou_lottie_url, "https://cdn.example.com/thankyou_anim.json")

        // Particle effect
        XCTAssertNotNil(theme.thankyou_particle_effect)
        XCTAssertEqual(theme.thankyou_particle_effect?.type, "confetti")
        XCTAssertEqual(theme.thankyou_particle_effect?.trigger, "on_flow_complete")
        XCTAssertEqual(theme.thankyou_particle_effect?.duration_ms, 3000)
        XCTAssertEqual(theme.thankyou_particle_effect?.intensity, "heavy")
        XCTAssertEqual(theme.thankyou_particle_effect?.colors?.count, 4)

        // Blur
        XCTAssertNotNil(theme.blur_backdrop)
        XCTAssertEqual(theme.blur_backdrop?.radius, 10.0)
        XCTAssertEqual(theme.blur_backdrop?.tint, "#00000040")
        XCTAssertEqual(theme.blur_backdrop?.saturation, 1.5)

        // Haptic
        XCTAssertNotNil(theme.haptic)
        XCTAssertEqual(theme.haptic?.enabled, true)
        XCTAssertEqual(theme.haptic?.triggers?.on_step_advance, .medium)
        XCTAssertEqual(theme.haptic?.triggers?.on_button_tap, .light)
        XCTAssertEqual(theme.haptic?.triggers?.on_option_select, .selection)
        XCTAssertNil(theme.haptic?.triggers?.on_plan_select)
        XCTAssertNil(theme.haptic?.triggers?.on_toggle)

        // Thank-you text
        XCTAssertEqual(theme.thank_you_text, "Thanks, {{user_name}}! Your feedback means a lot.")
    }

    func testDecodeThemeMinimal() throws {
        let json = """
        {}
        """.data(using: .utf8)!

        let theme = try JSONDecoder().decode(SurveyTheme.self, from: json)

        XCTAssertNil(theme.background_color)
        XCTAssertNil(theme.text_color)
        XCTAssertNil(theme.accent_color)
        XCTAssertNil(theme.button_color)
        XCTAssertNil(theme.font_family)
        XCTAssertNil(theme.intro_lottie_url)
        XCTAssertNil(theme.thankyou_lottie_url)
        XCTAssertNil(theme.thankyou_particle_effect)
        XCTAssertNil(theme.blur_backdrop)
        XCTAssertNil(theme.haptic)
        XCTAssertNil(theme.thank_you_text)
    }

    func testDecodeParticleEffectAllTypes() throws {
        let types = ["confetti", "sparkle", "fireworks", "snow", "hearts"]

        for effectType in types {
            let json = """
            {
                "type": "\(effectType)",
                "trigger": "on_appear",
                "duration_ms": 2000,
                "intensity": "medium"
            }
            """.data(using: .utf8)!

            let effect = try JSONDecoder().decode(ParticleEffect.self, from: json)
            XCTAssertEqual(effect.type, effectType)
            XCTAssertEqual(effect.trigger, "on_appear")
            XCTAssertEqual(effect.duration_ms, 2000)
            XCTAssertEqual(effect.intensity, "medium")
            XCTAssertNil(effect.colors)
        }
    }

    func testDecodeBlurConfigMinimal() throws {
        let json = """
        {
            "radius": 5.0
        }
        """.data(using: .utf8)!

        let blur = try JSONDecoder().decode(BlurConfig.self, from: json)

        XCTAssertEqual(blur.radius, 5.0)
        XCTAssertNil(blur.tint)
        XCTAssertNil(blur.saturation)
    }

    // MARK: - Follow-up actions

    func testDecodeFollowUpActions() throws {
        let json = """
        {
            "on_positive": {
                "action": "prompt_review",
                "message": "Glad you love it! Would you leave a review?"
            },
            "on_negative": {
                "action": "show_feedback_form",
                "message": "Sorry to hear that. Can you tell us more?"
            },
            "on_neutral": {
                "action": "dismiss",
                "message": "Thank you for your time."
            }
        }
        """.data(using: .utf8)!

        let actions = try JSONDecoder().decode(SurveyFollowUpActions.self, from: json)

        XCTAssertNotNil(actions.on_positive)
        XCTAssertEqual(actions.on_positive?.action, "prompt_review")
        XCTAssertEqual(actions.on_positive?.message, "Glad you love it! Would you leave a review?")

        XCTAssertNotNil(actions.on_negative)
        XCTAssertEqual(actions.on_negative?.action, "show_feedback_form")
        XCTAssertEqual(actions.on_negative?.message, "Sorry to hear that. Can you tell us more?")

        XCTAssertNotNil(actions.on_neutral)
        XCTAssertEqual(actions.on_neutral?.action, "dismiss")
        XCTAssertEqual(actions.on_neutral?.message, "Thank you for your time.")
    }

    func testDecodeFollowUpActionsPartial() throws {
        let json = """
        {
            "on_positive": {
                "action": "prompt_review"
            }
        }
        """.data(using: .utf8)!

        let actions = try JSONDecoder().decode(SurveyFollowUpActions.self, from: json)

        XCTAssertNotNil(actions.on_positive)
        XCTAssertEqual(actions.on_positive?.action, "prompt_review")
        XCTAssertNil(actions.on_positive?.message)
        XCTAssertNil(actions.on_negative)
        XCTAssertNil(actions.on_neutral)
    }

    func testDecodeFollowUpActionsEmpty() throws {
        let json = """
        {}
        """.data(using: .utf8)!

        let actions = try JSONDecoder().decode(SurveyFollowUpActions.self, from: json)

        XCTAssertNil(actions.on_positive)
        XCTAssertNil(actions.on_negative)
        XCTAssertNil(actions.on_neutral)
    }

    // MARK: - Edge cases

    func testDecodeMinimalSurveyConfig() throws {
        let json = """
        {
            "name": "Quick Poll",
            "survey_type": "custom",
            "questions": [],
            "trigger_rules": {
                "event": "app_open",
                "frequency": "once"
            },
            "appearance": {
                "presentation": "bottom_sheet"
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(SurveyConfig.self, from: json)

        XCTAssertEqual(config.name, "Quick Poll")
        XCTAssertEqual(config.survey_type, "custom")
        XCTAssertEqual(config.questions?.isEmpty, true)
        XCTAssertEqual(config.trigger_rules?.event, "app_open")
        XCTAssertEqual(config.appearance?.presentation, "bottom_sheet")
        XCTAssertEqual(config.appearance?.dismiss_allowed, true)
        XCTAssertEqual(config.appearance?.show_progress, false)
        XCTAssertNil(config.follow_up_actions)
    }

    func testDecodeUnknownQuestionType() throws {
        let json = """
        {
            "id": "unknown_q",
            "type": "matrix_grid",
            "text": "Some unknown question type",
            "required": false
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "unknown_q")
        XCTAssertEqual(question.type, "matrix_grid")
        XCTAssertEqual(question.text, "Some unknown question type")
        XCTAssertFalse(question.required ?? true)
        XCTAssertNil(question.nps_config)
        XCTAssertNil(question.csat_config)
        XCTAssertNil(question.rating_config)
        XCTAssertNil(question.options)
        XCTAssertNil(question.emoji_config)
        XCTAssertNil(question.free_text_config)
        XCTAssertNil(question.show_if)
        XCTAssertNil(question.image_url)
    }

    func testDecodeEmptyQuestionsList() throws {
        let json = """
        {
            "name": "Empty Survey",
            "survey_type": "custom",
            "questions": [],
            "trigger_rules": {
                "event": "test",
                "frequency": "once"
            },
            "appearance": {
                "presentation": "fullscreen"
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(SurveyConfig.self, from: json)

        XCTAssertEqual(config.questions?.isEmpty, true)
    }

    func testDecodeQuestionWithAllNullOptionals() throws {
        let json = """
        {
            "id": "bare_q",
            "type": "nps",
            "text": "Rate us",
            "required": true,
            "nps_config": null,
            "csat_config": null,
            "rating_config": null,
            "options": null,
            "emoji_config": null,
            "free_text_config": null,
            "show_if": null,
            "image_url": null
        }
        """.data(using: .utf8)!

        let question = try JSONDecoder().decode(SurveyQuestion.self, from: json)

        XCTAssertEqual(question.id, "bare_q")
        XCTAssertEqual(question.type, "nps")
        XCTAssertNil(question.nps_config)
        XCTAssertNil(question.csat_config)
        XCTAssertNil(question.rating_config)
        XCTAssertNil(question.options)
        XCTAssertNil(question.emoji_config)
        XCTAssertNil(question.free_text_config)
        XCTAssertNil(question.show_if)
        XCTAssertNil(question.image_url)
    }

    func testDecodeSurveyRootWithMultipleSurveys() throws {
        let json = """
        {
            "version": 1,
            "surveys": {
                "nps_v1": {
                    "name": "NPS Survey",
                    "survey_type": "nps",
                    "questions": [
                        {
                            "id": "q1",
                            "type": "nps",
                            "text": "How likely?",
                            "required": true
                        }
                    ],
                    "trigger_rules": {
                        "event": "purchase_completed",
                        "frequency": "once"
                    },
                    "appearance": {
                        "presentation": "bottom_sheet"
                    }
                },
                "csat_v1": {
                    "name": "CSAT Survey",
                    "survey_type": "csat",
                    "questions": [
                        {
                            "id": "q1",
                            "type": "csat",
                            "text": "How satisfied?",
                            "required": true,
                            "csat_config": {
                                "max_rating": 5,
                                "style": "star"
                            }
                        }
                    ],
                    "trigger_rules": {
                        "event": "support_resolved",
                        "frequency": "once_per_session"
                    },
                    "appearance": {
                        "presentation": "modal"
                    }
                },
                "feedback_v1": {
                    "name": "General Feedback",
                    "survey_type": "custom",
                    "questions": [
                        {
                            "id": "q1",
                            "type": "single_choice",
                            "text": "What brought you here?",
                            "required": true,
                            "options": [
                                { "id": "o1", "text": "App Store" },
                                { "id": "o2", "text": "Friend" },
                                { "id": "o3", "text": "Social media" }
                            ]
                        },
                        {
                            "id": "q2",
                            "type": "free_text",
                            "text": "Anything else?",
                            "required": false,
                            "free_text_config": {
                                "placeholder": "Optional...",
                                "max_length": 250
                            }
                        }
                    ],
                    "trigger_rules": {
                        "event": "app_open",
                        "conditions": [
                            {
                                "field": "session_count",
                                "operator": "eq",
                                "value": 10
                            }
                        ],
                        "frequency": "once",
                        "min_sessions": 10
                    },
                    "appearance": {
                        "presentation": "fullscreen",
                        "theme": {
                            "background_color": "#1A1A2E",
                            "text_color": "#FFFFFF",
                            "accent_color": "#E94560",
                            "button_color": "#E94560"
                        },
                        "dismiss_allowed": false,
                        "show_progress": true
                    },
                    "follow_up_actions": {
                        "on_positive": {
                            "action": "prompt_review",
                            "message": "Would you leave us a review?"
                        }
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let root = try JSONDecoder().decode(SurveyRoot.self, from: json)

        XCTAssertEqual(root.version, 1)
        XCTAssertEqual(root.surveys?.count, 3)

        // NPS survey
        let nps = root.surveys?["nps_v1"]
        XCTAssertNotNil(nps)
        XCTAssertEqual(nps?.survey_type, "nps")
        XCTAssertEqual(nps?.questions?.count, 1)

        // CSAT survey
        let csat = root.surveys?["csat_v1"]
        XCTAssertNotNil(csat)
        XCTAssertEqual(csat?.survey_type, "csat")
        XCTAssertEqual(csat?.questions?.first?.csat_config?.resolvedMax, 5)

        // Feedback survey
        let feedback = root.surveys?["feedback_v1"]
        XCTAssertNotNil(feedback)
        XCTAssertEqual(feedback?.survey_type, "custom")
        XCTAssertEqual(feedback?.questions?.count, 2)
        XCTAssertEqual(feedback?.appearance?.dismiss_allowed, false)
        XCTAssertEqual(feedback?.appearance?.show_progress, true)
        XCTAssertNotNil(feedback?.follow_up_actions?.on_positive)
        XCTAssertNil(feedback?.follow_up_actions?.on_negative)
    }

    func testDecodeSurveyConfigWithNullFollowUpActions() throws {
        let json = """
        {
            "name": "No Actions",
            "survey_type": "nps",
            "questions": [
                {
                    "id": "q1",
                    "type": "nps",
                    "text": "Rate us",
                    "required": true
                }
            ],
            "trigger_rules": {
                "event": "app_open",
                "frequency": "once"
            },
            "appearance": {
                "presentation": "bottom_sheet"
            },
            "follow_up_actions": null
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(SurveyConfig.self, from: json)

        XCTAssertNil(config.follow_up_actions)
    }

    func testDecodeSurveyWithMultipleQuestionTypes() throws {
        let json = """
        {
            "name": "Comprehensive Feedback",
            "survey_type": "custom",
            "questions": [
                {
                    "id": "q_nps",
                    "type": "nps",
                    "text": "How likely to recommend?",
                    "required": true,
                    "nps_config": {
                        "low_label": "Not likely",
                        "high_label": "Very likely"
                    }
                },
                {
                    "id": "q_csat",
                    "type": "csat",
                    "text": "Satisfaction?",
                    "required": true,
                    "csat_config": { "max_rating": 5, "style": "star" }
                },
                {
                    "id": "q_rating",
                    "type": "rating",
                    "text": "Rate the experience",
                    "required": true,
                    "rating_config": { "max_rating": 5, "style": "heart" }
                },
                {
                    "id": "q_sc",
                    "type": "single_choice",
                    "text": "Favorite feature?",
                    "required": true,
                    "options": [
                        { "id": "o1", "text": "Speed" },
                        { "id": "o2", "text": "Design" }
                    ]
                },
                {
                    "id": "q_mc",
                    "type": "multi_choice",
                    "text": "Improve areas?",
                    "required": false,
                    "options": [
                        { "id": "o1", "text": "Performance" },
                        { "id": "o2", "text": "UI" },
                        { "id": "o3", "text": "Features" }
                    ]
                },
                {
                    "id": "q_ft",
                    "type": "free_text",
                    "text": "Comments?",
                    "required": false,
                    "show_if": {
                        "question_id": "q_nps",
                        "answer_in": [0, 1, 2, 3, 4, 5, 6]
                    },
                    "free_text_config": {
                        "placeholder": "Tell us more...",
                        "max_length": 500
                    }
                },
                {
                    "id": "q_yn",
                    "type": "yes_no",
                    "text": "Would you use again?",
                    "required": true
                },
                {
                    "id": "q_emoji",
                    "type": "emoji_scale",
                    "text": "Mood?",
                    "required": false,
                    "emoji_config": {
                        "emojis": ["\u{1F44E}", "\u{1F44D}"]
                    }
                }
            ],
            "trigger_rules": {
                "event": "session_end",
                "frequency": "once",
                "max_displays": 1
            },
            "appearance": {
                "presentation": "fullscreen",
                "theme": {
                    "background_color": "#FFFFFF",
                    "text_color": "#000000",
                    "accent_color": "#5856D6",
                    "button_color": "#5856D6"
                },
                "dismiss_allowed": true,
                "show_progress": true,
                "corner_radius": 12
            },
            "follow_up_actions": {
                "on_positive": {
                    "action": "prompt_review",
                    "message": "Thanks!"
                },
                "on_negative": {
                    "action": "show_feedback_form"
                }
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(SurveyConfig.self, from: json)

        XCTAssertEqual(config.name, "Comprehensive Feedback")
        XCTAssertEqual(config.survey_type, "custom")
        XCTAssertEqual(config.questions?.count, 8)

        // Verify each question type decoded correctly
        XCTAssertEqual(config.questions?[0].type, "nps")
        XCTAssertNotNil(config.questions?[0].nps_config)

        XCTAssertEqual(config.questions?[1].type, "csat")
        XCTAssertNotNil(config.questions?[1].csat_config)

        XCTAssertEqual(config.questions?[2].type, "rating")
        XCTAssertNotNil(config.questions?[2].rating_config)

        XCTAssertEqual(config.questions?[3].type, "single_choice")
        XCTAssertEqual(config.questions?[3].options?.count, 2)

        XCTAssertEqual(config.questions?[4].type, "multi_choice")
        XCTAssertEqual(config.questions?[4].options?.count, 3)

        XCTAssertEqual(config.questions?[5].type, "free_text")
        XCTAssertNotNil(config.questions?[5].show_if)
        XCTAssertNotNil(config.questions?[5].free_text_config)

        XCTAssertEqual(config.questions?[6].type, "yes_no")

        XCTAssertEqual(config.questions?[7].type, "emoji_scale")
        XCTAssertNotNil(config.questions?[7].emoji_config)

        // Appearance
        XCTAssertEqual(config.appearance?.corner_radius, 12)

        // Follow-up actions
        XCTAssertNotNil(config.follow_up_actions?.on_positive)
        XCTAssertNotNil(config.follow_up_actions?.on_negative)
        XCTAssertNil(config.follow_up_actions?.on_neutral)
        XCTAssertNil(config.follow_up_actions?.on_negative?.message)
    }

    func testDecodeSurveyRootEmptySurveys() throws {
        let json = """
        {
            "version": 1,
            "surveys": {}
        }
        """.data(using: .utf8)!

        let root = try JSONDecoder().decode(SurveyRoot.self, from: json)

        XCTAssertEqual(root.version, 1)
        XCTAssertEqual(root.surveys?.isEmpty, true)
    }

    func testDecodeOptionWithAllFields() throws {
        let json = """
        {
            "id": "opt_special",
            "text": "Premium Support",
            "icon": "star.fill"
        }
        """.data(using: .utf8)!

        let option = try JSONDecoder().decode(SurveyQuestionOption.self, from: json)

        XCTAssertEqual(option.id, "opt_special")
        XCTAssertEqual(option.text, "Premium Support")
        XCTAssertEqual(option.icon, "star.fill")
    }

    func testDecodeOptionWithoutIcon() throws {
        let json = """
        {
            "id": "opt_plain",
            "text": "Basic"
        }
        """.data(using: .utf8)!

        let option = try JSONDecoder().decode(SurveyQuestionOption.self, from: json)

        XCTAssertEqual(option.id, "opt_plain")
        XCTAssertEqual(option.text, "Basic")
        XCTAssertNil(option.icon)
    }

    func testDecodeFollowUpAction() throws {
        let json = """
        {
            "action": "prompt_review",
            "message": "Please leave a review!"
        }
        """.data(using: .utf8)!

        let action = try JSONDecoder().decode(FollowUpAction.self, from: json)

        XCTAssertEqual(action.action, "prompt_review")
        XCTAssertEqual(action.message, "Please leave a review!")
    }

    func testDecodeFollowUpActionWithoutMessage() throws {
        let json = """
        {
            "action": "dismiss"
        }
        """.data(using: .utf8)!

        let action = try JSONDecoder().decode(FollowUpAction.self, from: json)

        XCTAssertEqual(action.action, "dismiss")
        XCTAssertNil(action.message)
    }

    func testDecodeTriggerRulesWithLoveScoreRange() throws {
        let json = """
        {
            "event": "feature_used",
            "love_score_range": {
                "min": 70,
                "max": 100
            },
            "frequency": "max_times",
            "max_displays": 5,
            "delay_seconds": 30,
            "min_sessions": 5
        }
        """.data(using: .utf8)!

        let rules = try JSONDecoder().decode(SurveyTriggerRules.self, from: json)

        XCTAssertEqual(rules.event, "feature_used")
        XCTAssertNil(rules.conditions)
        XCTAssertNotNil(rules.love_score_range)
        XCTAssertEqual(rules.love_score_range?.min, 70)
        XCTAssertEqual(rules.love_score_range?.max, 100)
        XCTAssertEqual(rules.max_displays, 5)
        XCTAssertEqual(rules.delay_seconds, 30)
        XCTAssertEqual(rules.min_sessions, 5)
    }
}
