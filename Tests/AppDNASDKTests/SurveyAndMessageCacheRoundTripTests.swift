// SurveyAndMessageCacheRoundTripTests.swift — #944
//
// `RemoteConfigManager.cacheAllFetchedConfigs()` does not only encode paywalls and onboarding
// flows. It encodes SURVEYS and IN-APP MESSAGES through the same typed `JSONEncoder`, and those two
// had no round-trip test either — so the same hole #928 found in `OnboardingStep` was open in two
// more surfaces, unexamined.
//
// 🔴 A SURVEY IS THE WORST CASE OF THE THREE. It carries three `@LenientArray` properties, nested
// one inside another — `questions`, `choice_config.options` and the legacy flat `options` — plus a
// `ThemeSet` whose decoder accepts a FLAT theme and whose encoder always writes `{ light, dark }`.
// That is a shape CHANGE across the cache, which is exactly the class of thing the #928 syntax gate
// is blind to: every key is encoded, and the question is whether the value survives the trip.
//
// Same disciplines as the paywall half: the production writer, a marker key the typed encode cannot
// carry so the async write is detected instead of slept through, and a control asserting the result
// is not an empty object that would satisfy every comparison.
import XCTest
@testable import AppDNASDK

final class SurveyAndMessageCacheRoundTripTests: XCTestCase {

    private func makeManager(_ cache: ConfigCache) -> RemoteConfigManager {
        RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
    }

    /// Wait for the production re-cache to land, detected by the marker key disappearing.
    private func awaitRecache(_ load: () -> Data?) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let d = load(), !String(decoding: d, as: UTF8.self).contains("__cache_marker") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    // MARK: - Surveys

    /// A survey using BOTH option shapes at once: `choice_config.options` on one question and the
    /// legacy flat `options` on another, so the round trip cannot pass by collapsing them together.
    /// The theme is authored FLAT, which is the shape the encoder does not write back.
    private func surveyDocument() -> [String: Any] {
        [
            "__cache_marker": "raw",
            "name": "Round trip survey",
            "survey_type": "csat",
            "questions": [
                [
                    "id": "q_csat", "type": "csat", "text": "How was it?", "required": true,
                    "csat_config": ["scale": 7, "labels": ["Bad", "Fine", "Great"], "style": "star"],
                ],
                [
                    "id": "q_choice", "type": "single_choice", "text": "Which one?",
                    "required": false,
                    "choice_config": ["options": [
                        ["id": "o1", "label": "First", "icon": "star"],
                        ["id": "o2", "label": "Second", "emoji": "🎯"],
                    ]],
                ],
                [
                    // Legacy flat `options`, the OTHER rung of the same accessor.
                    "id": "q_legacy", "type": "multi_choice", "text": "Any of these?",
                    "options": [["id": "l1", "text": "Legacy text"]],
                    "show_if": ["question_id": "q_choice", "answer_in": ["o1"]],
                ],
                [
                    "id": "q_text", "type": "free_text", "text": "Anything else?",
                    "free_text_config": ["placeholder": "Tell us", "max_length": 240],
                ],
            ],
            // Authored FLAT — `ThemeSet` reads it as the light variant and re-writes it as
            // `{ "light": … }`, so the stored SHAPE differs from the authored one.
            "appearance": [
                "presentation": "bottom_sheet", "dismiss_allowed": false, "show_progress": true,
                "corner_radius": 18,
                "theme": ["background_color": "#101010", "accent_color": "#FF3366",
                          "text_color": "#FAFAFA", "thank_you_text": "Thanks!"],
            ],
            "trigger_rules": ["event": "session_start", "max_displays": 2, "delay_seconds": 4,
                              "min_sessions": 3, "love_score_range": ["min": 60, "max": 100]],
            "follow_up_actions": [
                "on_positive": ["action": "prompt_review", "message": "Mind leaving a review?"],
                "on_negative": ["action": "show_feedback_form", "message": "What went wrong?"],
            ],
        ]
    }

    func testASurveySurvivesTheProductionCacheWithBothOptionShapes() throws {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        cache.storeSurveys(try JSONSerialization.data(
            withJSONObject: ["surveys": ["s1": surveyDocument()]]))

        let first = makeManager(cache)
        let before = try XCTUnwrap(first.getSurveyConfigs()["s1"], "the seeded survey did not parse")
        // The fixture really is populated — otherwise the comparisons below are nil vs nil.
        XCTAssertEqual(before.questions?.count, 4, "all four questions parsed")
        XCTAssertEqual(before.questions?[1].options?.count, 2, "choice_config.options")
        XCTAssertEqual(before.questions?[2].options?.first?.text, "Legacy text", "the legacy flat options")

        first.cacheAllFetchedConfigs()
        XCTAssertTrue(awaitRecache { cache.loadSurveys() },
                      "the production re-cache never wrote — nothing below is a round trip")

        let after = try XCTUnwrap(makeManager(cache).getSurveyConfigs()["s1"],
                                  "the re-cached survey did not parse back")

        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.survey_type, before.survey_type)

        // 🔴 Three nested `@LenientArray`s. A wrapper that flattened what it wraps loses all of this.
        XCTAssertEqual(after.questions?.count, before.questions?.count, "questions")
        XCTAssertEqual(after.questions?.map { $0.id }, before.questions?.map { $0.id }, "question ids")
        XCTAssertEqual(after.questions?.map { $0.type }, before.questions?.map { $0.type })
        XCTAssertEqual(after.questions?.map { $0.required }, before.questions?.map { $0.required })
        XCTAssertEqual(after.questions?[0].csat_config?.scale, 7, "csat scale")
        XCTAssertEqual(after.questions?[0].csat_config?.labels, ["Bad", "Fine", "Great"])
        XCTAssertEqual(after.questions?[0].csat_config?.resolvedMax, 7)
        XCTAssertEqual(after.questions?[1].options?.count, 2, "choice_config.options after the cache")
        XCTAssertEqual(after.questions?[1].options?.map { $0.text }, ["First", "Second"])
        XCTAssertEqual(after.questions?[1].options?[1].emoji, "🎯")
        XCTAssertEqual(after.questions?[2].options?.first?.text, "Legacy text",
                       "the LEGACY flat options array, which is a different key on the same accessor")
        XCTAssertEqual(after.questions?[2].show_if?.question_id, "q_choice", "the branch condition")
        XCTAssertEqual(after.questions?[3].free_text_config?.max_length, 240)

        XCTAssertEqual(after.trigger_rules?.event, before.trigger_rules?.event)
        XCTAssertEqual(after.trigger_rules?.max_displays, 2)
        XCTAssertEqual(after.trigger_rules?.love_score_range?.min, 60, "the love-score window")
        XCTAssertEqual(after.follow_up_actions?.on_positive?.action, "prompt_review")
        XCTAssertEqual(after.follow_up_actions?.on_negative?.message, "What went wrong?")
    }

    /**
     🔴 A FLAT THEME IS RE-WRITTEN AS `{ light, dark }`, AND MUST STILL READ BACK.

     `ThemeSet.init(from:)` accepts either shape and the encoder only ever writes the keyed one, so
     the cache stores a DIFFERENT shape than the document it came from. That is a transform across
     the round trip — the thing the #928 syntax gate cannot see at all, because both halves name
     every key they touch.
     */
    func testAFlatThemeComesBackThroughTheKeyedShapeTheEncoderWrites() throws {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        cache.storeSurveys(try JSONSerialization.data(
            withJSONObject: ["surveys": ["s1": surveyDocument()]]))

        let first = makeManager(cache)
        let before = try XCTUnwrap(first.getSurveyConfigs()["s1"]?.appearance)
        XCTAssertEqual(before.theme?.light.background_color, "#101010", "the flat theme was read as `light`")
        XCTAssertNil(before.theme?.dark, "the fixture authors no dark variant")

        first.cacheAllFetchedConfigs()
        XCTAssertTrue(awaitRecache { cache.loadSurveys() }, "the production re-cache never wrote")

        // The SHAPE really did change — the assertion below is about a keyed theme, not the flat one.
        let stored = String(decoding: try XCTUnwrap(cache.loadSurveys()), as: UTF8.self)
        XCTAssertTrue(stored.contains("\"light\""), "the encoder writes the keyed shape")

        let after = try XCTUnwrap(makeManager(cache).getSurveyConfigs()["s1"]?.appearance)
        XCTAssertEqual(after.theme?.light.background_color, before.theme?.light.background_color)
        XCTAssertEqual(after.theme?.light.accent_color, before.theme?.light.accent_color)
        XCTAssertEqual(after.theme?.light.text_color, before.theme?.light.text_color)
        XCTAssertEqual(after.theme?.light.thank_you_text, before.theme?.light.thank_you_text)
        XCTAssertEqual(after.presentation, "bottom_sheet")
        XCTAssertEqual(after.dismiss_allowed, false, "an explicit false must not become the `?? true` default")
        XCTAssertEqual(after.show_progress, true)
        XCTAssertEqual(after.corner_radius, 18)
    }

    /// 🔴 The control: an EMPTY survey would satisfy most of the comparisons above.
    func testTheRoundTrippedSurveyIsNotJustAnEmptySurvey() throws {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        cache.storeSurveys(try JSONSerialization.data(
            withJSONObject: ["surveys": ["s1": surveyDocument()]]))
        let first = makeManager(cache)
        _ = first.getSurveyConfigs()["s1"]
        first.cacheAllFetchedConfigs()
        XCTAssertTrue(awaitRecache { cache.loadSurveys() }, "the production re-cache never wrote")
        let after = try XCTUnwrap(makeManager(cache).getSurveyConfigs()["s1"])

        let bare = try JSONDecoder().decode(SurveyConfig.self, from: Data(#"{ "name": "bare" }"#.utf8))
        XCTAssertNil(bare.questions)
        XCTAssertFalse(after.questions?.isEmpty ?? true)
        XCTAssertNil(bare.appearance)
        XCTAssertNotNil(after.appearance)
        XCTAssertNil(bare.trigger_rules)
        XCTAssertNotNil(after.trigger_rules)
        XCTAssertNil(bare.follow_up_actions)
        XCTAssertNotNil(after.follow_up_actions)
    }

    // MARK: - In-app messages

    /// An in-app message with every content branch set, and an UNKNOWN `message_type`.
    ///
    /// 🔴 The unknown case is the interesting one: `MessageType.init(from:)` maps an unrecognised
    /// string to `.unknown`, and the encoder then writes the literal `"unknown"`. So the cached
    /// document says something the server never said, and the test pins what the SDK will read back
    /// — `.unknown`, consistently, rather than a value that drifts with each cold start.
    func testAMessageSurvivesTheProductionCache() throws {
        let doc: [String: Any] = [
            "__cache_marker": "raw",
            "messages": ["m1": [
                "name": "Round trip message",
                "message_type": "modal",
                "priority": 5,
                "start_date": "2026-01-01",
                "end_date": "2026-12-31",
                "content": [
                    "title": "Hello", "body": "Body copy",
                    "image_url": "https://example.invalid/i.png",
                    "cta_text": "Go", "dismiss_text": "Later",
                    "background_color": "#202020", "text_color": "#F0F0F0",
                    "button_color": "#3366FF", "button_text_color": "#FFFFFF",
                    "button_corner_radius": 10, "corner_radius": 14,
                    "secondary_cta_text": "Maybe", "font_family": "Inter",
                    "auto_dismiss_seconds": 9,
                ],
                "trigger_rules": ["event": "app_open", "max_displays": 3],
            ], "m2": [
                "name": "Unknown type",
                "message_type": "carousel_that_does_not_exist",
                "content": ["title": "Second"],
            ]],
        ]

        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        cache.storeMessages(try JSONSerialization.data(withJSONObject: doc))

        let first = makeManager(cache)
        let before = try XCTUnwrap(first._getMessagesForTesting()["m1"], "the seeded message did not parse")
        XCTAssertEqual(before.content?.title, "Hello", "the fixture really is populated")
        XCTAssertEqual(first._getMessagesForTesting()["m2"]?.message_type, .unknown,
                       "an unrecognised type is read as .unknown")

        first.cacheAllFetchedConfigs()
        XCTAssertTrue(awaitRecache { cache.loadMessages() },
                      "the production re-cache never wrote — nothing below is a round trip")

        let second = makeManager(cache)
        let after = try XCTUnwrap(second._getMessagesForTesting()["m1"], "the re-cached message did not parse back")

        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.message_type, before.message_type, "message_type")
        XCTAssertEqual(after.priority, before.priority)
        XCTAssertEqual(after.start_date, before.start_date)
        XCTAssertEqual(after.end_date, before.end_date)
        XCTAssertEqual(after.content?.title, before.content?.title)
        XCTAssertEqual(after.content?.body, before.content?.body)
        XCTAssertEqual(after.content?.image_url, before.content?.image_url)
        XCTAssertEqual(after.content?.cta_text, before.content?.cta_text)
        XCTAssertEqual(after.content?.dismiss_text, before.content?.dismiss_text)
        XCTAssertEqual(after.content?.background_color, before.content?.background_color)
        XCTAssertEqual(after.content?.text_color, before.content?.text_color)
        XCTAssertEqual(after.content?.button_color, before.content?.button_color)
        XCTAssertEqual(after.content?.button_corner_radius, before.content?.button_corner_radius)
        XCTAssertEqual(after.content?.corner_radius, before.content?.corner_radius)
        XCTAssertEqual(after.content?.secondary_cta_text, before.content?.secondary_cta_text)
        XCTAssertEqual(after.content?.font_family, before.content?.font_family, "#the typography fields")
        XCTAssertEqual(after.content?.auto_dismiss_seconds, before.content?.auto_dismiss_seconds)
        XCTAssertEqual(after.trigger_rules?.event, before.trigger_rules?.event)
        XCTAssertEqual(after.trigger_rules?.max_displays, 3)

        // The unknown type is stable rather than drifting, and the message is still there.
        XCTAssertEqual(second._getMessagesForTesting()["m2"]?.message_type, .unknown)
        XCTAssertEqual(second._getMessagesForTesting()["m2"]?.content?.title, "Second")

        // 🔴 The control: an empty message would satisfy most of the comparisons above.
        let bare = try JSONDecoder().decode(MessageConfig.self, from: Data(#"{ "name": "bare" }"#.utf8))
        XCTAssertNil(bare.content)
        XCTAssertNotNil(after.content)
        XCTAssertNil(bare.priority)
        XCTAssertNotNil(after.priority)
    }
}
