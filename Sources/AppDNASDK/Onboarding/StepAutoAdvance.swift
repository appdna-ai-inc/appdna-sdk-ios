import Foundation

/// Whether a step advances by itself, and after how long.
///
/// A splash screen and a step whose button was forgotten are the SAME SHAPE on the wire — content
/// blocks, nothing to tap. One is deliberate (held while the app loads, then advanced by the host
/// through ``AppDNA/advanceOnboardingStep()``) and the other strands every user on it. Two
/// step-level fields make the intent explicit:
///
///   `auto_advance_seconds`  the SDK advances by itself after this many seconds
///   `wait_for_host: true`   the step is DECLARED host-driven and must never time out
///
/// 🔴 `wait_for_host` WINS over a seconds value. An author who says the app drives this step has
/// said it must hold; a leftover timer from an earlier edit must not yank the screen out from under
/// the app's own loading. The reverse precedence is unrecoverable from the author's side — they
/// would have to clear a field to make a toggle mean what it says.
///
/// Mirrors `src/modules/onboarding/validators/step-auto-advance.ts` (console + publish validator)
/// and Android `StepAutoAdvance.kt`. Pinned on all three by the shared fixture
/// `step_advance/step_auto_advance_delay`.
enum StepAutoAdvance {

    /// Below this, "advance after N seconds" draws a screen nobody can read, which looks exactly
    /// like the step being skipped — so it is treated as NOT SET rather than as "advance instantly".
    static let minSeconds: Double = 0.1

    /// A splash that outlives a minute is a bug. A hand-written config never passed through the
    /// console's schema, so the ceiling is enforced here too: `99999` holds for a minute, not forever.
    static let maxSeconds: Double = 60

    /// The delay after which the SDK advances this step by itself, or `nil` when it never does.
    static func delaySeconds(autoAdvanceSeconds: Double?, waitForHost: Bool?) -> Double? {
        if waitForHost == true { return nil }
        guard let raw = autoAdvanceSeconds, raw.isFinite, raw >= minSeconds else { return nil }
        return min(raw, maxSeconds)
    }

    /// The delay for a step as published.
    static func delaySeconds(for step: OnboardingStep) -> Double? {
        delaySeconds(autoAdvanceSeconds: step.auto_advance_seconds, waitForHost: step.wait_for_host)
    }
}

/// A single pending auto-advance, cancellable.
///
/// Held in the renderer's `@State` so leaving the step — by tapping, by the host advancing it, or by
/// the flow being dismissed — cancels the timer rather than advancing a screen the user is no longer
/// looking at. Android gets this for free: its timer is a `delay()` inside `LaunchedEffect(currentIndex)`,
/// which the Compose runtime cancels on both.
final class StepAutoAdvanceTimer {
    private var work: DispatchWorkItem?

    /// Replaces any pending advance. `after` is in seconds.
    func schedule(after seconds: Double, _ fire: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: fire)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    /// True while an advance is pending (for tests — the renderer never asks).
    var isPending: Bool { work.map { !$0.isCancelled } ?? false }

    deinit { cancel() }
}
