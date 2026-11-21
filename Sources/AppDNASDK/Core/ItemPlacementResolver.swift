import Foundation

/// A placement is a name an app can ask for instead of an item's ID. Several items may share one.
/// They are tried in a fixed order, the same on every launch and on both platforms.
enum ItemPlacementResolver {
    /// Higher audience priority, then a flow with audience conditions before a catch-all, then lowest
    /// `id`. The first whose rules match wins; a flow with no rules matches everyone.
    static func pickFlow(
        from flows: [OnboardingFlowConfig],
        placement: String,
        traits: [String: Any]
    ) -> OnboardingFlowConfig? {
        flows
            .filter { $0.placement == placement }
            .sorted { a, b in
                let (pa, pb) = (AudienceRuleEvaluator.priority(rules: a.audience_rules), AudienceRuleEvaluator.priority(rules: b.audience_rules))
                if pa != pb { return pa > pb }
                let (ca, cb) = (AudienceRuleEvaluator.hasConditions(rules: a.audience_rules), AudienceRuleEvaluator.hasConditions(rules: b.audience_rules))
                if ca != cb { return ca }
                return a.id < b.id
            }
            .first { flow in
                guard flow.audience_rules != nil else { return true }
                return AudienceRuleEvaluator.evaluate(rules: flow.audience_rules, traits: traits)
            }
    }

    /// The same order as `pickFlow`: higher audience priority, then a survey with audience conditions before a
    /// catch-all, then lowest `id`. The first whose `audience_rules` admit the user wins (the survey trigger's own
    /// audience gate, `SurveyManager.audienceAllows`); a survey with no rules matches everyone.
    static func pickSurveyId(from surveys: [String: SurveyConfig], placement: String, traits: [String: Any]) -> String? {
        surveys
            .filter { $0.value.placement == placement }
            .sorted { a, b in
                let (pa, pb) = (AudienceRuleEvaluator.priority(rules: a.value.audience_rules), AudienceRuleEvaluator.priority(rules: b.value.audience_rules))
                if pa != pb { return pa > pb }
                let (ca, cb) = (AudienceRuleEvaluator.hasConditions(rules: a.value.audience_rules), AudienceRuleEvaluator.hasConditions(rules: b.value.audience_rules))
                if ca != cb { return ca }
                return a.key < b.key
            }
            .first { SurveyManager.audienceAllows($0.value, traits: traits) }?.key
    }
}
