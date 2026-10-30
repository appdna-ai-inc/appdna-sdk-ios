import Foundation

/**
 WHEN an onboarding flow's authored celebration fires.

 🔴 The console has offered a "Celebration Effect" in the flow settings panel since it
 shipped. Android parsed it into its config object and no composable read it; iOS did not parse it
 at all. `ConfettiOverlay` existed on both platforms the whole time — onboarding was simply never
 one of its callers, so the control did nothing, on both platforms, for every flow.

 An onboarding flow has exactly TWO moments it can celebrate:

 - `on_appear` — the flow's first step appears;
 - `on_step_complete` — the author finished a step and the next one arrived.

 `on_flow_complete` is deliberately NOT one of them. The host tears the flow down the moment
 `onFlowCompleted` fires (the Activity finishes on Android), so a celebration there would be
 dismissed in the same frame it started — making it work means HOLDING the completion for the
 effect's duration, which changes every flow's completion timing and needs its own proof.
 `on_purchase` has no meaning inside onboarding at all; the paywall has its own effect.

 It is a shared FUNCTION, driven by `onboarding_celebration_moment`, because the thing that went
 wrong with the last two particle defects was two platforms disagreeing about when an effect fires
 (a double gate, and `PaywallConfig.kt` defaulting to a trigger that could not fire). A rule
 each platform states for itself is a rule they can state differently.
 */
public enum OnboardingCelebration {

    /// The moment a step arrival represents: the first step is the flow APPEARING, any later one is
    /// the previous step having been COMPLETED.
    public static func moment(stepIndex: Int) -> String {
        stepIndex <= 0 ? "on_appear" : "on_step_complete"
    }

    /**
     The moment that fires for an authored `trigger` at `stepIndex`, or `nil` when this arrival is
     not the authored moment.

     An unset trigger means `on_appear`, matching both decoders' own default — Android's
     `OnboardingConfig.kt` reads `trigger ?: "on_appear"` and iOS's `ParticleEffect.trigger` is
     optional. A trigger the flow cannot honour (`on_purchase`, `on_flow_complete`) returns `nil`
     at every index rather than firing at the nearest moment: silently relocating an author's
     choice is how a celebration ends up in the wrong place with nobody able to explain why.
     */
    public static func celebratedMoment(trigger: String?, stepIndex: Int) -> String? {
        let authored = (trigger?.isEmpty == false) ? trigger! : "on_appear"
        let moment = self.moment(stepIndex: stepIndex)
        return authored == moment ? moment : nil
    }
}
