import Foundation

/// Where the progress bar's "Skip" link goes.
///
/// 🔴 `OnboardingSettings.skip_to_step` WAS DECODED BY BOTH PLATFORMS AND READ BY NEITHER. It sits
/// one field away from `progress_skip_label`, and this link was the only thing it could have meant:
/// Skip advanced ONE step, which is indistinguishable from pressing the CTA, so a flow that offered
/// "Skip" walked the user through the rest of it anyway.
///
/// 🔴 A SHARED RULE RATHER THAN THREE LINES IN EACH RENDERER, because three lines in each renderer
/// is exactly how a shared rule diverges: an `?:` that returns early on one platform and an
/// `if let` that falls through on the other look identical in review and behave differently. Both
/// renderers call this.
enum ProgressSkipTarget {

    /// The step id Skip should jump to, or `nil` when it should advance one step as before.
    ///
    /// `nil` for three reasons, all of which must behave the same on both platforms:
    ///   * no target authored — the link keeps the behaviour it has always had;
    ///   * an empty or whitespace target — what a cleared text field leaves behind;
    ///   * a target naming a step that is not in this flow — a stale id after a step was renamed
    ///     or deleted, which must degrade to advancing rather than trapping the user on a screen
    ///     whose Skip does nothing.
    static func resolve(_ skipToStep: String?, stepIds: [String]) -> String? {
        guard let raw = skipToStep else { return nil }
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, stepIds.contains(target) else { return nil }
        return target
    }
}
