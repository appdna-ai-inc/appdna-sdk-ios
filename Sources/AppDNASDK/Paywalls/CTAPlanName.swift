import Foundation

/// How a multi-plan CTA names the plan it will buy.
///
/// One rule on every surface: iOS (`CTAButton`, `PaywallRenderer`), Android `CtaPlanName`, and the
/// console preview's `composeCtaPlanName`; the shared fixture `dto_parsing/cta_plan_name_compose` holds
/// all three to the same output.
///
/// - `base` is the CTA text ALREADY localised; `plan` the plan's name, already localised, or nil when
///   there is nothing to name (a single plan, a plan with its own `cta_text`, or naming switched off).
/// - `format` places the two: `{cta}` and `{plan}`, default `{cta} — {plan}`. It is itself localised
///   (`cta.plan_format`), so a locale can change the separator OR the order — which a separator key
///   alone could not express.
/// - A label that already contains the plan's name is left alone, so "Start Annual" never becomes
///   "Start Annual — Annual", whichever string localisation produced.
enum CTAPlanName {
    static let defaultFormat = "{cta} — {plan}"

    static func compose(base: String, plan: String?, format: String?) -> String {
        guard let plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty,
              !base.localizedCaseInsensitiveContains(plan) else { return base }
        let f = (format?.isEmpty == false) ? format! : defaultFormat
        return f.replacingOccurrences(of: "{cta}", with: base).replacingOccurrences(of: "{plan}", with: plan)
    }
}
