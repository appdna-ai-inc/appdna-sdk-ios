import Foundation

/**
 How much of the screen the pinned group may take before it stops being a pinned group.

 Any section may carry `zone: "bottom"`, which pins it above the CTA. Pin the plans and the
 CTA — the case it exists for — and the paywall reads better. Pin the header, the features, a
 testimonial and a comparison table as well and the scrolling body becomes a sliver: the same
 defect the bottom zone fixed, arriving from the other direction.

 Two guards existed and both were advice — the console's Zone control warns, and the generator's
 prompt says "plans + cta and nothing more". Neither is enforcement and neither can see a phone's
 screen height.

 🔴 DEGRADE, NEVER CLIP. Past the fraction, every pinned section except the CTA returns to the body
 in its authored position. The CTA stays pinned whatever happens: reaching it is the entire point
 of the zone, and a clipped group that hides the button is the one outcome worse than a scrolling
 one.

 The fraction is measured against the VIEWPORT, because the schema cannot know how tall a section
 renders — a two-line testimonial and a comparison table are the same `zone: "bottom"`.
 */
enum PaywallBottomZone {
    /**
     The share of the viewport the pinned group may occupy.

     0.55 leaves a body taller than the pinned group on every phone this renders on, and was chosen
     by pinning four sections on a device and looking at the result rather than by arithmetic.
     */
    static let maxFraction: Double = 0.55

    /**
     Whether the pinned group is too tall to stay pinned.

     An unknown viewport (0 or less) keeps everything pinned: a measurement that has not happened
     yet is not evidence of overflow, and un-pinning on a guess would move the page under the user
     for one frame.
     */
    static func overflows(pinned: Double, viewport: Double) -> Bool {
        guard viewport > 0, pinned > 0 else { return false }
        return pinned > viewport * maxFraction
    }
}
