import XCTest
@testable import AppDNASDK

/// Next-step-rule targets that name a `permission_*` / `screen_*` / `flow_*` graph node,
/// and the last-step rule-failure bailout event.
///
/// THE BUGS:
///   1. `OnboardingAdvance.advance` routed `analytics_event_*`, `paywall_trigger_*`, `end_*` and a
///      literal step id — nothing else. A rule targeting a permission / screen / sub-flow graph node
///      fell through to the next rule and then to plain sequential advance: the node was SKIPPED, with
///      no log, no event and no error. Android hands it to the host as a completion marker
///      (`onboarding/OnboardingAdvance.kt:231-236`, classified at `NextStepRuleEvaluator.kt:299-302`).
///   2. When the LAST step carries rules and none match, Android emits `flow_completed_via_fallback`
///      (`NextStepRuleEvaluator.kt:293`) so ETL can tell an authored completion from a misconfigured
///      one. iOS emitted nothing.
final class OnboardingGraphNodeRoutingTests: XCTestCase {

    private func decodeFlow(_ json: String) -> OnboardingFlowConfig {
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    /// s1 routes unconditionally to `target`; s2 is the sequential fallback the bug used to take.
    private func targeting(_ target: String) -> OnboardingFlowConfig {
        decodeFlow("""
        {
          "id": "flow_1",
          "steps": [
            {
              "id": "s1",
              "type": "question",
              "config": {},
              "next_step_rules": [{ "target_step_id": "\(target)" }]
            },
            { "id": "s2", "type": "question", "config": {} }
          ]
        }
        """)
    }

    private func advanceFromFirstStep(_ flow: OnboardingFlowConfig) -> OnboardingAdvance.Outcome {
        OnboardingAdvance.advance(flow: flow, currentIndex: 0, responses: ["s1": ["a": 1]])
    }

    // MARK: - Marker routing (BUG 2)

    func testPermissionTargetCompletesWithThePermissionMarker() {
        let outcome = advanceFromFirstStep(targeting("permission_camera"))

        guard case .completeFlow(let responses) = outcome.navigation else {
            return XCTFail("expected .completeFlow, got \(outcome.navigation) — the node was skipped")
        }
        XCTAssertEqual(responses["__permission_request"] as? String, "camera")
        XCTAssertEqual(OnboardingAdvance.permissionRequestMarker, "__permission_request")
        // The step's own responses ride along untouched.
        XCTAssertNotNil(responses["s1"])
        // The marker is a COMPLETION payload only — it must not be written back into flow state
        // (Android: `AdvanceOutcome.responses` "never carries completion markers").
        XCTAssertNil(outcome.responses["__permission_request"])
    }

    func testScreenTargetCompletesWithTheScreenMarker() {
        let outcome = advanceFromFirstStep(targeting("screen_paywall_intro"))

        guard case .completeFlow(let responses) = outcome.navigation else {
            return XCTFail("expected .completeFlow, got \(outcome.navigation)")
        }
        XCTAssertEqual(responses["__screen_present"] as? String, "paywall_intro")
        XCTAssertEqual(OnboardingAdvance.screenPresentMarker, "__screen_present")
    }

    func testSubFlowTargetCompletesWithTheSubFlowMarker() {
        let outcome = advanceFromFirstStep(targeting("flow_upsell"))

        guard case .completeFlow(let responses) = outcome.navigation else {
            return XCTFail("expected .completeFlow, got \(outcome.navigation)")
        }
        XCTAssertEqual(responses["__sub_flow"] as? String, "upsell")
        XCTAssertEqual(OnboardingAdvance.subFlowMarker, "__sub_flow")
    }

    /// A plain step target is still a plain step target — the prefix routes must not swallow it.
    func testPlainStepTargetStillNavigates() {
        let outcome = advanceFromFirstStep(targeting("s2"))
        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(index, 1)
        XCTAssertTrue(outcome.events.isEmpty)
    }

    // MARK: - Fallback completion event (BUG 3)

    /// Last step, rules present, none match → completion via rule-failure. Name + props pinned to
    /// Android (`OnboardingAdvance.kt:274-283`): `{flow_id, step_id, step_index}`.
    func testLastStepWithNoMatchingRuleEmitsTheFallbackEvent() {
        let flow = decodeFlow("""
        {
          "id": "flow_2",
          "steps": [
            { "id": "s1", "type": "question", "config": {} },
            {
              "id": "s2",
              "type": "question",
              "config": {},
              "next_step_rules": [
                {
                  "target_step_id": "s1",
                  "conditions": [{ "type": "answer_equals", "answer_key": "pick", "value": "a" }]
                }
              ]
            }
          ]
        }
        """)

        let outcome = OnboardingAdvance.advance(flow: flow, currentIndex: 1, responses: [:])

        guard case .completeFlow = outcome.navigation else {
            return XCTFail("expected .completeFlow")
        }
        XCTAssertEqual(outcome.events.map(\.name), ["flow_completed_via_fallback"])
        XCTAssertEqual(OnboardingAdvance.flowCompletedViaFallbackEvent, "flow_completed_via_fallback")
        let props = outcome.events[0].props
        XCTAssertEqual(props["flow_id"] as? String, "flow_2")
        XCTAssertEqual(props["step_id"] as? String, "s2")
        XCTAssertEqual(props["step_index"] as? Int, 1)
    }

    /// A NON-last step whose rules all miss is a normal sequential advance — the fallback event must
    /// not fire there, or every unmatched rule would look like a misconfiguration.
    func testNonLastStepWithNoMatchingRuleEmitsNothing() {
        let flow = decodeFlow("""
        {
          "id": "flow_3",
          "steps": [
            {
              "id": "s1",
              "type": "question",
              "config": {},
              "next_step_rules": [
                {
                  "target_step_id": "s3",
                  "conditions": [{ "type": "answer_equals", "answer_key": "pick", "value": "a" }]
                }
              ]
            },
            { "id": "s2", "type": "question", "config": {} },
            { "id": "s3", "type": "question", "config": {} }
          ]
        }
        """)

        let outcome = OnboardingAdvance.advance(flow: flow, currentIndex: 0, responses: [:])

        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected sequential advance")
        }
        XCTAssertEqual(index, 1)
        XCTAssertTrue(outcome.events.isEmpty)
    }

    /// A last step with NO rules at all is a natural end — still no fallback event (Android only emits
    /// it inside the `rules.isNotEmpty()` branch).
    func testLastStepWithNoRulesEmitsNothing() {
        let flow = decodeFlow("""
        {
          "id": "flow_4",
          "steps": [
            { "id": "s1", "type": "question", "config": {} },
            { "id": "s2", "type": "question", "config": {} }
          ]
        }
        """)

        let outcome = OnboardingAdvance.advance(flow: flow, currentIndex: 1, responses: [:])

        guard case .completeFlow = outcome.navigation else {
            return XCTFail("expected .completeFlow")
        }
        XCTAssertTrue(outcome.events.isEmpty)
    }
}
