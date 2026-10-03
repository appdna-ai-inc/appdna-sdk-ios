import XCTest
@testable import AppDNASDK

/// paywall_trigger skip gate + skip-target resolver chain.
///
/// This file used to MIRROR the resolver as a private helper, because the real one lived inside a
/// Task closure in `presentPaywallTrigger` with no seam to call. It now drives the production
/// `PaywallTriggerSkipResolver` that `OnboardingFlowHost` calls.
///
/// End-to-end behavior (resolver → routeOutcome → flowCompleted vs. edge follow vs. specific target)
/// is covered by the shared behavioral fixtures at `packages/sdk-shared-fixtures/billing/`.
final class PaywallTriggerSkipTargetTests: XCTestCase {

    private func skipTarget(onSubscribedSkipTarget: String?, onSuccessTarget: String?) -> String? {
        var triggerData: [String: Any] = [:]
        if let onSubscribedSkipTarget { triggerData["on_subscribed_skip_target"] = onSubscribedSkipTarget }
        if let onSuccessTarget { triggerData["on_success_target"] = onSuccessTarget }
        return PaywallTriggerSkipResolver.decision(
            triggerData: triggerData,
            hasActiveSubscription: true
        ).skipTarget
    }

    // MARK: - Resolver chain

    /// Case 1 — explicit on_subscribed_skip_target wins.
    func testResolverPicksOnSubscribedSkipTargetWhenSet() {
        XCTAssertEqual(
            skipTarget(onSubscribedSkipTarget: "complete_flow", onSuccessTarget: "step_some_other"),
            "complete_flow"
        )
    }

    /// Case 2 — back-compat: empty on_subscribed_skip_target falls back to on_success_target
    /// (1.0.61 workaround behavior preserved).
    func testResolverFallsBackToOnSuccessTargetWhenSkipTargetEmpty() {
        XCTAssertEqual(
            skipTarget(onSubscribedSkipTarget: "", onSuccessTarget: "complete_flow"),
            "complete_flow"
        )
    }

    func testResolverFallsBackToOnSuccessTargetWhenSkipTargetNil() {
        XCTAssertEqual(
            skipTarget(onSubscribedSkipTarget: nil, onSuccessTarget: "step_welcome_back"),
            "step_welcome_back"
        )
    }

    /// Case 3 — legacy: both empty → nil → routeOutcome falls through to its `defaultBehavior`
    /// argument ("continue") and follows the edge. The earlier behavior, preserved.
    func testResolverReturnsNilWhenBothEmptyOrNil() {
        XCTAssertNil(skipTarget(onSubscribedSkipTarget: nil, onSuccessTarget: nil))
        XCTAssertNil(skipTarget(onSubscribedSkipTarget: "", onSuccessTarget: ""))
        XCTAssertNil(skipTarget(onSubscribedSkipTarget: "", onSuccessTarget: nil))
        XCTAssertNil(skipTarget(onSubscribedSkipTarget: nil, onSuccessTarget: ""))
    }

    /// Case 4 — author opts into chain-of-paywalls via explicit "continue".
    func testResolverPicksExplicitContinue() {
        XCTAssertEqual(skipTarget(onSubscribedSkipTarget: "continue", onSuccessTarget: nil), "continue")
    }

    /// Case 5 — author picks a specific node id.
    func testResolverPicksSpecificNodeId() {
        XCTAssertEqual(
            skipTarget(onSubscribedSkipTarget: "step_welcome_back", onSuccessTarget: "step_thank_you"),
            "step_welcome_back"
        )
    }

    // MARK: - Skip gate

    /// Default `true`: a flow authored before the field existed still auto-skips for subscribers.
    func testSubscribedUserSkipsByDefault() {
        let decision = PaywallTriggerSkipResolver.decision(
            triggerData: ["on_subscribed_skip_target": "step_welcome_back"],
            hasActiveSubscription: true
        )
        XCTAssertFalse(decision.present)
        XCTAssertEqual(decision.skipTarget, "step_welcome_back")
        XCTAssertEqual(decision.reason, "user_already_subscribed")
    }

    /// Upsell paywalls opt out — a subscriber must still SEE them.
    func testSubscribedUserStillSeesPaywallWhenSkipDisabled() {
        let decision = PaywallTriggerSkipResolver.decision(
            triggerData: ["skip_if_subscribed": false, "on_subscribed_skip_target": "step_welcome_back"],
            hasActiveSubscription: true
        )
        XCTAssertTrue(decision.present)
        XCTAssertNil(decision.reason)
        // The chain is still resolved: the runtime-lock skip routes through it without
        // consulting the subscription state.
        XCTAssertEqual(decision.skipTarget, "step_welcome_back")
    }

    func testNonSubscribedUserAlwaysSeesPaywall() {
        let decision = PaywallTriggerSkipResolver.decision(
            triggerData: ["on_subscribed_skip_target": "step_welcome_back"],
            hasActiveSubscription: false
        )
        XCTAssertTrue(decision.present)
        XCTAssertNil(decision.reason)
    }

    // MARK: - Legacy on_dismiss default

    func testLegacyDismissDefaults() {
        XCTAssertEqual(PaywallTriggerSkipResolver.legacyDismissDefault("block"), "complete_flow")
        XCTAssertEqual(PaywallTriggerSkipResolver.legacyDismissDefault("skip_to_end"), "complete_flow")
        XCTAssertEqual(PaywallTriggerSkipResolver.legacyDismissDefault("continue"), "continue")
        XCTAssertEqual(PaywallTriggerSkipResolver.legacyDismissDefault(nil), "continue")
        XCTAssertEqual(PaywallTriggerSkipResolver.legacyDismissDefault("garbage"), "continue")
    }
}
