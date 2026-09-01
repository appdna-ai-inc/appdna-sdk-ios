import Foundation

/// A CTA that records the user's choice without leaving the flow.
///
/// WHY THIS EXISTS: a summary or upsell step offers something the app must act on *later* — "book a
/// tasting", "start the trial", "talk to a human". Routing there the moment the button is tapped
/// abandons an onboarding the user is halfway through, and the host then has to rebuild the flow's
/// position by hand to bring them back. A flag CTA instead writes one key, advances exactly like
/// `next`, and lets the host route once, at `onOnboardingCompleted`, when the flow is genuinely
/// finished.
///
/// AUTHORING: the console writes the pair into the button's existing `action_value` — the same
/// single-parameter slot `link` uses for its URL and `permission` for its type. One flag per CTA;
/// a step with three offers uses three CTAs.
///
/// Cross-platform: Android `OnboardingCTAFlag.kt` parses the identical strings, and the shared
/// fixture `onboarding/cta_flag_*.fixture.json` asserts both produce the same pair, so a divergence
/// in the split rule has to break a test rather than reach a device.
enum OnboardingCTAFlag {

    /// The `action` value the console writes and every SDK switches on. A constant rather than a
    /// literal at the call site so the fixtures pin the spelling.
    static let actionName = "flag"

    /// Where an aggregated copy of every flag set during the flow is placed in the completion
    /// `responses` map.
    ///
    /// Step answers are namespaced by step id (`responses["step9"]["wants_upsell"]`), which is right
    /// for answers and wrong for flags: a host routing after completion would have to walk every
    /// step of every flow to discover whether any CTA was flagged. Flags are therefore ALSO
    /// collected flat under this one well-known key. The per-step copy is still written — nothing is
    /// moved — so `next_step_rules` and `{{responses.*}}` templates see the flag exactly where they
    /// see every other answer.
    static let responsesKey = "flags"

    struct Flag: Equatable {
        let key: String
        let value: String
    }

    /// Parse the authored `action_value`.
    ///
    /// - `"wants_upsell"` → key `wants_upsell`, value `"true"`
    /// - `"upsell_choice=booking"` → key `upsell_choice`, value `"booking"`
    ///
    /// Splits on the FIRST `=` only, so a value may itself contain one (`utm=a=b` → value `a=b`).
    /// Returns nil for a missing or key-less string; the caller advances anyway rather than leaving
    /// the user on a button that appears to do nothing.
    static func parse(_ actionValue: String?) -> Flag? {
        guard let raw = actionValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let sep = raw.firstIndex(of: "=") else {
            // No value authored. `"true"` and not a Bool: the value crosses to Android, Flutter and
            // React Native through JSON and lands in analytics props, and a String is the one
            // representation all four agree on. A host reads `== "true"`.
            return Flag(key: raw, value: "true")
        }
        let key = String(raw[raw.startIndex..<sep]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        // `"key="` — an author who cleared the value field means the plain flag, not an empty string
        // that every `if flags["k"] != nil` check would still treat as set while `== "true"` fails.
        return Flag(key: key, value: value.isEmpty ? "true" : value)
    }

    /// THE fold: given the flow-level responses, the step that just completed and the data it
    /// produced, return the responses with any flag that step's CTAs set collected flat under
    /// `flags`.
    ///
    /// One function rather than "scan here, merge there" because both the live flow host and the
    /// shared-fixture runner must exercise the SAME logic — a fixture that reimplemented the scan
    /// would assert its own wiring and stay green with the SDK's copy deleted.
    ///
    /// Which keys count as flags comes from the step's CTA CONFIG, not from the data map. Reading
    /// the map would let a form field named `flags` — or one whose id happened to match a flag key —
    /// write into the bucket the host makes routing decisions on.
    static func applyTo(
        responses: [String: Any],
        step: OnboardingStep,
        stepData: [String: Any]
    ) -> [String: Any] {
        let flagKeys = Set((step.config.content_blocks ?? []).compactMap { block -> String? in
            guard block.action == actionName else { return nil }
            return parse(block.action_value)?.key
        })
        guard !flagKeys.isEmpty else { return responses }
        return merge(into: responses, flags: stepData.filter { flagKeys.contains($0.key) })
    }

    /// Fold flag keys into the flat `flags` bucket. Internal to ``applyTo``; exposed only because
    /// the Android mirror is, and the fixtures pin both.
    static func merge(into responses: [String: Any], flags: [String: Any]) -> [String: Any] {
        guard !flags.isEmpty else { return responses }
        var out = responses
        var bucket = (out[responsesKey] as? [String: Any]) ?? [:]
        bucket.merge(flags) { _, new in new }
        out[responsesKey] = bucket
        return out
    }
}
