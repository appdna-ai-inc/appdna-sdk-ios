import Foundation

/*
 #998 — THE LIKERT SCALE'S BOUNDS, AS ONE RULE BOTH PLATFORMS CALL.

 Android had rendered a likert scale for releases while iOS drew nothing, and the clamp that keeps
 a malformed config from crashing lived INSIDE each view. That is the shape #1037 was: a rule
 written twice, in two languages, agreeing until one of them was edited — there, a Kotlin
 `?: return` where Swift had an `if let` inside the condition, and a survey's follow-up silently
 never ran.

 So the rule is a function, in one file per platform, called by the renderer AND by the shared
 behavioural fixture. A fixture that re-implemented it could only ever agree with itself.
*/

/// The resolved bounds and anchor visibility of a likert scale.
public struct LikertScaleRule {
    /// Both platforms draw 1...5 when the config says nothing.
    public static let defaultMin = 1
    public static let defaultMax = 5

    /**
     The scale's inclusive bounds.

     🔴 A malformed `min > max` is SWAPPED, not trusted. `min...max` traps at runtime when the
     range is reversed, so a config that arrives the wrong way round would crash the survey rather
     than draw an odd scale — and a config arriving the wrong way round is exactly what a free-text
     number field in a console produces.
     */
    public static func bounds(min: Int?, max: Int?) -> (lo: Int, hi: Int) {
        let lo = min ?? defaultMin
        let hi = max ?? defaultMax
        return lo <= hi ? (lo, hi) : (hi, lo)
    }

    /// How many buttons the scale draws.
    public static func count(min: Int?, max: Int?) -> Int {
        let b = bounds(min: min, max: max)
        return b.hi - b.lo + 1
    }

    /// Anchors are hidden when NEITHER is set, so a bare numeric scale reserves no empty space.
    public static func showsAnchors(low: String?, high: String?) -> Bool {
        low != nil || high != nil
    }
}
