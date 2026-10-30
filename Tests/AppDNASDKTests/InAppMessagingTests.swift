import XCTest
@testable import AppDNASDK

final class InAppMessagingTests: XCTestCase {

    // MARK: - MessageConfig types

    func testMessageTypeEnum() {
        XCTAssertEqual(MessageType.banner.rawValue, "banner")
        XCTAssertEqual(MessageType.modal.rawValue, "modal")
        XCTAssertEqual(MessageType.fullscreen.rawValue, "fullscreen")
        XCTAssertEqual(MessageType.tooltip.rawValue, "tooltip")
    }

    func testMessageFrequencyEnum() {
        XCTAssertEqual(MessageFrequency.once.rawValue, "once")
        XCTAssertEqual(MessageFrequency.once_per_session.rawValue, "once_per_session")
        XCTAssertEqual(MessageFrequency.every_time.rawValue, "every_time")
        XCTAssertEqual(MessageFrequency.max_times.rawValue, "max_times")
    }

    func testCTAActionTypes() {
        XCTAssertEqual(CTAAction.CTAActionType.dismiss.rawValue, "dismiss")
        XCTAssertEqual(CTAAction.CTAActionType.deep_link.rawValue, "deep_link")
        XCTAssertEqual(CTAAction.CTAActionType.open_url.rawValue, "open_url")
    }

    // MARK: - Trigger condition evaluation

    func testConditionOperatorEq() {
        let result = evaluateCondition(
            field: "plan", op: .eq, value: "premium",
            properties: ["plan": "premium"]
        )
        XCTAssertTrue(result)
    }

    func testConditionOperatorEqMismatch() {
        let result = evaluateCondition(
            field: "plan", op: .eq, value: "premium",
            properties: ["plan": "free"]
        )
        XCTAssertFalse(result)
    }

    func testConditionOperatorGte() {
        XCTAssertTrue(evaluateCondition(field: "streak", op: .gte, value: 7, properties: ["streak": 10]))
        XCTAssertTrue(evaluateCondition(field: "streak", op: .gte, value: 7, properties: ["streak": 7]))
        XCTAssertFalse(evaluateCondition(field: "streak", op: .gte, value: 7, properties: ["streak": 5]))
    }

    func testConditionOperatorLte() {
        XCTAssertTrue(evaluateCondition(field: "age", op: .lte, value: 30, properties: ["age": 25]))
        XCTAssertTrue(evaluateCondition(field: "age", op: .lte, value: 30, properties: ["age": 30]))
        XCTAssertFalse(evaluateCondition(field: "age", op: .lte, value: 30, properties: ["age": 35]))
    }

    func testConditionOperatorGt() {
        XCTAssertTrue(evaluateCondition(field: "score", op: .gt, value: 100, properties: ["score": 101]))
        XCTAssertFalse(evaluateCondition(field: "score", op: .gt, value: 100, properties: ["score": 100]))
    }

    func testConditionOperatorLt() {
        XCTAssertTrue(evaluateCondition(field: "score", op: .lt, value: 100, properties: ["score": 99]))
        XCTAssertFalse(evaluateCondition(field: "score", op: .lt, value: 100, properties: ["score": 100]))
    }

    func testConditionOperatorContains() {
        XCTAssertTrue(evaluateCondition(field: "tags", op: .contains, value: "vip", properties: ["tags": "vip_user"]))
        XCTAssertFalse(evaluateCondition(field: "tags", op: .contains, value: "vip", properties: ["tags": "regular"]))
    }

    func testConditionMissingField() {
        XCTAssertFalse(evaluateCondition(field: "missing", op: .eq, value: "x", properties: [:]))
    }

    // MARK: - MessageFrequencyTracker

    func testFrequencyTrackerOncePerSession() {
        let tracker = MessageFrequencyTracker()

        XCTAssertTrue(tracker.canShow(messageId: "msg_1", frequency: .once_per_session, maxDisplays: nil))
        tracker.recordShown(messageId: "msg_1", frequency: .once_per_session)
        XCTAssertFalse(tracker.canShow(messageId: "msg_1", frequency: .once_per_session, maxDisplays: nil))

        // Different message should still be allowed
        XCTAssertTrue(tracker.canShow(messageId: "msg_2", frequency: .once_per_session, maxDisplays: nil))
    }

    func testFrequencyTrackerEveryTime() {
        let tracker = MessageFrequencyTracker()

        for _ in 0..<10 {
            XCTAssertTrue(tracker.canShow(messageId: "msg_1", frequency: .every_time, maxDisplays: nil))
            tracker.recordShown(messageId: "msg_1", frequency: .every_time)
        }
    }

    func testFrequencyTrackerResetSession() {
        let tracker = MessageFrequencyTracker()

        tracker.recordShown(messageId: "msg_1", frequency: .once_per_session)
        XCTAssertFalse(tracker.canShow(messageId: "msg_1", frequency: .once_per_session, maxDisplays: nil))

        tracker.resetSession()
        XCTAssertTrue(tracker.canShow(messageId: "msg_1", frequency: .once_per_session, maxDisplays: nil))
    }

    // MARK: - MessageConfig construction

    func testMessageConfigConstruction() {
        let config = MessageConfig(
            name: "Streak Reward",
            message_type: .modal,
            content: MessageContent(
                title: "🔥 7-Day Streak!",
                body: "Keep it up!",
                image_url: nil,
                cta_text: "Keep Going",
                cta_action: CTAAction(type: .dismiss, url: nil),
                dismiss_text: "Later",
                background_color: "#FFFFFF",
                banner_position: nil,
                auto_dismiss_seconds: nil,
                text_color: nil,
                button_color: nil,
                button_text_color: nil,
                button_corner_radius: nil,
                corner_radius: nil,
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
                event: "session_start",
                conditions: nil,
                frequency: .once,
                max_displays: 1,
                delay_seconds: 2
            ),
            priority: 10,
            start_date: "2026-02-01",
            end_date: "2026-03-01"
        )

        XCTAssertEqual(config.name, "Streak Reward")
        XCTAssertEqual(config.message_type, .modal)
        XCTAssertEqual(config.content?.title, "🔥 7-Day Streak!")
        XCTAssertEqual(config.trigger_rules?.event, "session_start")
        XCTAssertEqual(config.trigger_rules?.frequency, .once)
        XCTAssertEqual(config.trigger_rules?.delay_seconds, 2)
        XCTAssertEqual(config.priority, 10)
    }

    // MARK: - Helper

    /// Evaluate a condition the way the SDK does.
    ///
    /// 🔴 CALLS THE PRODUCTION RULE. This used to be a hand-written copy of `MessageManager`'s
    /// switch, headed "mirrors MessageManager's condition evaluation" — a test that re-implements
    /// the thing under test can only ever agree with it, and this one did: it reproduced the old
    /// six-operator set, so neither the `neq` inversion nor the missing `in` / `not_in` could ever
    /// have failed here. The evaluation now lives on the operator itself and both managers
    /// call it, so this calls it too.
    private func evaluateCondition(
        field: String,
        op: TriggerCondition.ConditionOperator,
        value: Any,
        properties: [String: Any]
    ) -> Bool {
        guard let propValue = properties[field] else { return false }
        return op.matches(propValue, value)
    }
}
