import Foundation

/// SPEC-070-B — the onboarding flow-completion seam.
///
/// WHY THIS FILE EXISTS: "the flow finished" is the single most important thing onboarding emits — it
/// is the denominator of the whole funnel and the only moment the host is handed the user's answers.
/// On iOS it was reachable ONLY through `OnboardingFlowManager.present(from:flow:delegate:)`: the
/// event track, the SPEC-088 response persistence and `onOnboardingCompleted` all lived inside the
/// `onFlowCompleted` closure that `present()` closes over, so nothing without a `UIViewController` —
/// no unit test, no cross-platform fixture, no future host-driven presentation path — could reach the
/// completion decision or prove it fired. ``OnboardingAdvance`` had already been extracted for exactly
/// this reason and returns `Navigation.completeFlow`; this is the other half of that seam: what the
/// SDK must DO when it gets one.
///
/// Mirrors Android `OnboardingCompletion.kt` (`internal object OnboardingCompletion`) — same event
/// name, same props, same ordering (track → persist → delegate), so the two platforms read side by
/// side and a divergence has to break a fixture rather than quietly rot.
///
/// NOT `flow_completed`: that name belongs to the SCREENS module (`ScreenManager`), which emits
/// `flow_completed` / `flow_abandoned` for screen flows. Neither platform has ever emitted it for
/// onboarding, and reusing it would silently merge two different funnels in the warehouse.
enum OnboardingCompletion {

    /// The event the SDK MUST emit when an onboarding flow completes. A constant, not a literal at the
    /// call site: the shared cross-platform fixtures assert this exact spelling, so a rename has to
    /// break them rather than quietly retire the funnel's denominator.
    static let onboardingFlowCompletedEvent = "onboarding_flow_completed"

    /// Pure: the completion event, so its shape can be asserted without a tracker or a view controller.
    static func completionEvent(
        flowId: String,
        totalSteps: Int,
        durationMs: Int,
        responses: [String: Any]
    ) -> OnboardingAdvance.TrackedEvent {
        OnboardingAdvance.TrackedEvent(
            name: onboardingFlowCompletedEvent,
            props: [
                "flow_id": flowId,
                "total_steps": totalSteps,
                "total_duration_ms": durationMs,
                "responses": responses,
            ]
        )
    }

    /// The whole completion action, UIKit-free: emit the event, persist the responses, notify the
    /// delegate — in that order, so a host that reads the session store from inside
    /// `onOnboardingCompleted` already sees the answers, and so the analytic exists even if the host's
    /// delegate misbehaves.
    ///
    /// `track` is the caller's `EventTracker.track` (or any sink — that is what makes the seam
    /// testable). `delegate` is the flow's listener; nil is legal.
    static func complete(
        flowId: String,
        totalSteps: Int,
        durationMs: Int,
        responses: [String: Any],
        track: (String, [String: Any]) -> Void,
        delegate: AppDNAOnboardingDelegate?
    ) {
        let event = completionEvent(
            flowId: flowId,
            totalSteps: totalSteps,
            durationMs: durationMs,
            responses: responses
        )
        track(event.name, event.props)
        // SPEC-088: persist onboarding responses for cross-module access.
        SessionDataStore.shared.setOnboardingResponses(responses)
        delegate?.onOnboardingCompleted(flowId: flowId, responses: responses)
        // A `link_on_complete` CTA asked to go somewhere once the flow finished. Opened AFTER the
        // delegate, so the host's own completion work — dismissing the flow, persisting, its own
        // navigation — runs first; opening before it would race our navigation against theirs.
        //
        // Through `URLSafety`, like every other config-driven open: the string comes from remote
        // config, and a tested guard nothing calls is not a guard.
        if let route = PendingCompletionRoute.shared.take() {
            if !URLSafety.open(route) {
                Log.warning("A CTA's after-onboarding link was refused: '\(route)'")
            }
        }
    }
}
