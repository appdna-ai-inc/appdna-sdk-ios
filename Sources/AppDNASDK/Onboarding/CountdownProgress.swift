import Foundation

/// How far a countdown has run, as a fraction of its own starting value.
///
/// 🔴 BOTH PLATFORMS HAD THIS FROZEN AT 0.75. The `circular` variant's ring was a hardcoded
/// `trim(to: 0.75)` on iOS and `sweepAngle = 270f` on Android — the console preview's static mock,
/// ported into two renderers. The digits counted down while the ring never moved, and it was still
/// at 75% when the timer expired. A preview is allowed a frozen value because it has no clock; a
/// renderer is not.
///
/// 🔴 THE DENOMINATOR IS THE CAPTURED INITIAL VALUE, not `duration_seconds`. A `fixed_datetime`
/// countdown starts partway through its own duration — a sale ending in 3 hours whose
/// `duration_seconds` says 24 — so dividing by the authored duration pins the indicator near 100%
/// for the whole countdown. That trap is why both renderers capture `initialSeconds` once.
enum CountdownProgress {

    /// The fraction of the countdown still REMAINING, clamped to 0…1.
    ///
    /// Remaining rather than elapsed, because that is what both indicators draw: a ring and a bar
    /// that empty as time runs out. An initial value of zero or less answers 0 — a countdown that
    /// never had any time has none left, and it is also the guard against dividing by zero.
    static func remainingFraction(remainingSeconds: Int, initialSeconds: Int) -> Double {
        guard initialSeconds > 0 else { return 0 }
        let raw = Double(remainingSeconds) / Double(initialSeconds)
        return min(max(raw, 0), 1)
    }
}
