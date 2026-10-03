import XCTest
@testable import AppDNASDK

/// The onboarding step-advance state machine, extracted out of the SwiftUI host
/// (`OnboardingFlowHost`) into the pure `OnboardingAdvance` so it can be asserted at all. Mirrors
/// Android `OnboardingAdvanceTest` / `OnboardingAdvance.kt`.
///
/// Also pins: a `skip_to` step advance now emits `step_skipped` — it used to be
/// analytically invisible, so a jumped-over step and a never-reached step looked identical in the
/// funnel on every platform.
final class OnboardingAdvanceTests: XCTestCase {

    // MARK: - Fixtures

    private func decodeFlow(_ json: String) -> OnboardingFlowConfig {
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    /// Three linear steps, no rules.
    private var linearFlow: OnboardingFlowConfig {
        decodeFlow("""
        {
          "id": "flow_1",
          "steps": [
            { "id": "s1", "type": "welcome", "config": {} },
            { "id": "s2", "type": "question", "config": {} },
            { "id": "s3", "type": "question", "config": {} }
          ]
        }
        """)
    }

    /// s1 routes conditionally: answer=a → s3, otherwise fall through to sequential.
    private var ruleFlow: OnboardingFlowConfig {
        decodeFlow("""
        {
          "id": "flow_2",
          "graph_nodes": {
            "paywall1": { "type": "paywall_trigger", "paywall_id": "pw_a" },
            "end1": { "type": "end" },
            "analytics1": {
              "type": "analytics_event",
              "event_name": "custom_milestone",
              "next_target": "s3"
            }
          },
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
    }

    private func targeting(_ target: String) -> OnboardingFlowConfig {
        decodeFlow("""
        {
          "id": "flow_3",
          "graph_nodes": {
            "paywall1": { "type": "paywall_trigger", "paywall_id": "pw_a" },
            "end1": { "type": "end" },
            "analytics1": {
              "type": "analytics_event",
              "event_name": "custom_milestone",
              "next_target": "s3"
            }
          },
          "steps": [
            {
              "id": "s1",
              "type": "question",
              "config": {},
              "next_step_rules": [{ "target_step_id": "\(target)" }]
            },
            { "id": "s2", "type": "question", "config": {} },
            { "id": "s3", "type": "question", "config": {} }
          ]
        }
        """)
    }

    // MARK: - B4: skip_to emits an event

    /// THE BUG: `skipTo` navigated and emitted NOTHING. A flow that skips steps was invisible in the
    /// funnel. Name + props are pinned to Android's `STEP_SKIPPED_EVENT` (`OnboardingAdvance.kt:325`).
    func testSkipToEmitsStepSkippedWithFromAndTo() {
        let outcome = OnboardingAdvance.skipTo(
            flow: linearFlow,
            currentIndex: 0,
            targetStepId: "s3",
            responses: [:]
        )

        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected .goToIndex, got \(outcome.navigation)")
        }
        XCTAssertEqual(index, 2)

        XCTAssertEqual(outcome.events.count, 1)
        let event = outcome.events[0]
        XCTAssertEqual(event.name, "step_skipped")
        XCTAssertEqual(event.name, OnboardingAdvance.stepSkippedEvent)
        XCTAssertEqual(event.props["flow_id"] as? String, "flow_1")
        XCTAssertEqual(event.props["from_step_id"] as? String, "s1")
        XCTAssertEqual(event.props["to_step_id"] as? String, "s3")
    }

    /// The `.skipTo` hook result routes through the same machine — so the event fires on the real
    /// production path (delegate/webhook returns `.skipTo`), not only when `skipTo` is called directly.
    func testSkipToHookResultEmitsTheEvent() {
        let outcome = OnboardingAdvance.apply(
            result: .skipTo(stepId: "s3"),
            flow: linearFlow,
            currentIndex: 0,
            responses: [:]
        )
        XCTAssertEqual(outcome.events.map { $0.name }, ["step_skipped"])
        XCTAssertEqual(outcome.events.first?.props["to_step_id"] as? String, "s3")
    }

    /// `.skipToWithData` merges the data AND emits — merging must not swallow the event.
    func testSkipToWithDataMergesAndEmits() {
        let outcome = OnboardingAdvance.apply(
            result: .skipToWithData(stepId: "s3", data: ["plan": "pro"]),
            flow: linearFlow,
            currentIndex: 0,
            responses: ["s1": ["existing": true]]
        )
        XCTAssertEqual(outcome.events.map { $0.name }, ["step_skipped"])
        XCTAssertTrue(outcome.responsesChanged)
        let s1 = outcome.responses["s1"] as? [String: Any]
        XCTAssertEqual(s1?["plan"] as? String, "pro")
        XCTAssertEqual(s1?["existing"] as? Bool, true) // deep-merged, not replaced
        XCTAssertEqual(outcome.computedData?["plan"] as? String, "pro")
    }

    /// An UNKNOWN skip target is not a jump — it falls back to the normal advance and must NOT claim
    /// a skip happened, or the funnel would count a step that was never left.
    func testUnknownSkipTargetFallsThroughWithNoEvent() {
        let outcome = OnboardingAdvance.skipTo(
            flow: linearFlow,
            currentIndex: 0,
            targetStepId: "does_not_exist",
            responses: [:]
        )
        XCTAssertTrue(outcome.events.isEmpty)
        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected sequential fallback")
        }
        XCTAssertEqual(index, 1)
    }

    // MARK: - S1: hook-result folding (behaviour preserved from the host)

    func testProceedAdvancesSequentially() {
        let outcome = OnboardingAdvance.apply(
            result: .proceed, flow: linearFlow, currentIndex: 0, responses: [:]
        )
        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(index, 1)
        XCTAssertFalse(outcome.responsesChanged)
        XCTAssertNil(outcome.computedData)
    }

    func testProceedOnLastStepCompletesTheFlow() {
        let outcome = OnboardingAdvance.apply(
            result: .proceed, flow: linearFlow, currentIndex: 2, responses: ["s1": ["a": 1]]
        )
        guard case .completeFlow(let responses) = outcome.navigation else {
            return XCTFail("expected .completeFlow")
        }
        XCTAssertNotNil(responses["s1"])
    }

    func testProceedWithDataMergesIntoTheStepsOwnBag() {
        let outcome = OnboardingAdvance.apply(
            result: .proceedWithData(["score": 42]),
            flow: linearFlow,
            currentIndex: 0,
            responses: ["s1": ["name": "ada"]]
        )
        let s1 = outcome.responses["s1"] as? [String: Any]
        XCTAssertEqual(s1?["score"] as? Int, 42)
        XCTAssertEqual(s1?["name"] as? String, "ada")
        XCTAssertTrue(outcome.responsesChanged)
        XCTAssertEqual(outcome.computedData?["score"] as? Int, 42)
    }

    func testBlockStaysAndRaisesAnErrorBanner() {
        let outcome = OnboardingAdvance.apply(
            result: .block(message: "Invalid code"), flow: linearFlow, currentIndex: 1, responses: [:]
        )
        guard case .stay = outcome.navigation else { return XCTFail("expected .stay") }
        guard case .error(let message)? = outcome.banner else {
            return XCTFail("expected error banner")
        }
        XCTAssertEqual(message, "Invalid code")
        XCTAssertFalse(outcome.responsesChanged)
    }

    func testStayWithMessageRaisesSuccessBannerAndStayWithoutIsSilent() {
        let withMessage = OnboardingAdvance.apply(
            result: .stay(message: "Email sent"), flow: linearFlow, currentIndex: 1, responses: [:]
        )
        guard case .success(let message)? = withMessage.banner else {
            return XCTFail("expected success banner")
        }
        XCTAssertEqual(message, "Email sent")

        let silent = OnboardingAdvance.apply(
            result: .stay(message: nil), flow: linearFlow, currentIndex: 1, responses: [:]
        )
        XCTAssertNil(silent.banner)
        guard case .stay = silent.navigation else { return XCTFail("expected .stay") }

        // An EMPTY message is silent too — the host said "I handled the UI".
        let empty = OnboardingAdvance.apply(
            result: .stay(message: ""), flow: linearFlow, currentIndex: 1, responses: [:]
        )
        XCTAssertNil(empty.banner)
    }

    // MARK: - S1: rule routing

    func testMatchingRuleJumpsToItsTarget() {
        let outcome = OnboardingAdvance.advance(
            flow: ruleFlow, currentIndex: 0, responses: ["s1": ["pick": "a"]]
        )
        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(index, 2, "answer=a routes to s3")
    }

    func testUnmatchedRuleFallsThroughToSequentialAdvance() {
        let outcome = OnboardingAdvance.advance(
            flow: ruleFlow, currentIndex: 0, responses: ["s1": ["pick": "b"]]
        )
        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(index, 1, "no rule matched → next step")
    }

    func testPaywallTriggerNodeIsHandedBackToTheHost() {
        let outcome = OnboardingAdvance.advance(
            flow: targeting("paywall1"), currentIndex: 0, responses: [:]
        )
        guard case .presentPaywallTrigger(let nodeId) = outcome.navigation else {
            return XCTFail("expected .presentPaywallTrigger")
        }
        XCTAssertEqual(nodeId, "paywall1")
    }

    func testEndNodeCompletesTheFlow() {
        let outcome = OnboardingAdvance.advance(
            flow: targeting("end1"), currentIndex: 0, responses: [:]
        )
        guard case .completeFlow = outcome.navigation else {
            return XCTFail("expected .completeFlow")
        }
    }

    /// The analytics_event graph node fires its event and then follows `next_target`.
    func testAnalyticsEventNodeEmitsThenFollowsItsEdge() {
        let outcome = OnboardingAdvance.advance(
            flow: targeting("analytics1"), currentIndex: 0, responses: [:]
        )
        XCTAssertEqual(outcome.events.count, 1)
        XCTAssertEqual(outcome.events[0].name, "custom_milestone")
        XCTAssertEqual(outcome.events[0].props["node_id"] as? String, "analytics1")
        XCTAssertEqual(outcome.events[0].props["step_id"] as? String, "s1")
        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(index, 2)
    }

    // MARK: - S1: previous_step conditions

    func testPreviousStepEqualsUsesTheSuppliedPreviousStepId() {
        let flow = decodeFlow("""
        {
          "id": "flow_4",
          "steps": [
            { "id": "s1", "type": "question", "config": {} },
            {
              "id": "s2",
              "type": "question",
              "config": {},
              "next_step_rules": [
                {
                  "target_step_id": "s3",
                  "conditions": [{ "type": "previous_step_equals", "value": "s1" }]
                }
              ]
            },
            { "id": "s3", "type": "question", "config": {} },
            { "id": "s4", "type": "question", "config": {} }
          ]
        }
        """)

        let matched = OnboardingAdvance.advance(
            flow: flow, currentIndex: 1, responses: [:], previousStepId: "s1"
        )
        guard case .goToIndex(let matchedIndex) = matched.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(matchedIndex, 2)

        let unmatched = OnboardingAdvance.advance(
            flow: flow, currentIndex: 1, responses: [:], previousStepId: "s9"
        )
        guard case .goToIndex(let unmatchedIndex) = unmatched.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(unmatchedIndex, 2, "sequential advance from index 1 is also s3")
        XCTAssertTrue(unmatched.events.isEmpty)
    }

    // MARK: - S1: option id↔value aliasing (a rule authored on option.id, a response holding option.value)

    func testRuleOnOptionIdMatchesAResponseHoldingOptionValue() {
        let flow = decodeFlow("""
        {
          "id": "flow_5",
          "steps": [
            {
              "id": "s1",
              "type": "question",
              "config": {
                "content_blocks": [
                  {
                    "id": "b1",
                    "type": "input_select",
                    "field_id": "goal",
                    "field_options": [
                      { "id": "opt_1", "value": "by_learning" },
                      { "id": "opt_2", "value": "by_doing" }
                    ]
                  }
                ]
              },
              "next_step_rules": [
                {
                  "target_step_id": "s3",
                  "conditions": [{ "type": "answer_equals", "answer_key": "goal", "value": "opt_1" }]
                }
              ]
            },
            { "id": "s2", "type": "question", "config": {} },
            { "id": "s3", "type": "question", "config": {} }
          ]
        }
        """)

        let outcome = OnboardingAdvance.advance(
            flow: flow, currentIndex: 0, responses: ["s1": ["goal": "by_learning"]]
        )
        guard case .goToIndex(let index) = outcome.navigation else {
            return XCTFail("expected .goToIndex")
        }
        XCTAssertEqual(index, 2, "opt_1 ↔ by_learning must alias, or every rule misses")
    }
}
