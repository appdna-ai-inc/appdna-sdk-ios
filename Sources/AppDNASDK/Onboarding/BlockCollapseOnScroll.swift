import Foundation

/**
 HOW FAR a block authored `collapse_on_scroll` has collapsed, given how far the step has scrolled.

 🔴 #993 — iOS applied this and Android decoded it and stopped there. `collapse_on_scroll` and
 `collapse_threshold` are two declarations in the Kotlin and no use: every application of the key
 in the Android SDK is in `PaywallActivity`, which is a different surface. So one authored
 document produced a block that faded away on one platform and sat still on the other.

 It is the third defect of exactly this shape in one sweep — `label_bg_color` (Android drew it, iOS
 did not) and `blur_background` (iOS drew it, Android did not) were the first two. No gate can see
 any of them, because "does the platform READ the key" is true on both sides and only "does it ACT
 on it" differs.

 So the rule is a shared function, driven by `block_collapse_on_scroll`: 0 is fully shown, 1 is
 fully collapsed, and the renderer maps it to opacity and height. The threshold is how many points
 of scroll it takes to get there, defaulting to the 50 that shipped on iOS.
 */
public enum BlockCollapseOnScroll {

    /// The threshold that shipped hardcoded on iOS. A zero or negative authored threshold would
    /// divide by zero, so it falls back to this rather than collapsing instantly.
    public static let defaultThreshold: Double = 50

    /// `0` → fully visible, `1` → fully collapsed.
    public static func progress(enabled: Bool, scrollOffset: Double, threshold: Double?) -> Double {
        guard enabled else { return 0 }
        let t = (threshold.map { $0 > 0 ? $0 : defaultThreshold }) ?? defaultThreshold
        return min(max(scrollOffset / t, 0), 1)
    }
}
