import SwiftUI

/**
 The countdown a step that advances by itself can draw while it waits.

 Authored as `auto_advance_indicator` beside `auto_advance_seconds`; off unless `show: true`, so every
 flow already published draws nothing, as before. `{seconds}` in the text is the whole seconds LEFT,
 rounded up, and the bar is the share of the wait REMAINING. Nothing is drawn for a step that does not
 advance by itself (no timer, or `wait_for_host`).

 Mirrors `src/lib/onboarding/auto-advance-indicator.ts` and Android `AutoAdvanceIndicator`. Pinned on
 both platforms by the shared fixture `step_advance/auto_advance_indicator`.
 */
public enum AutoAdvanceIndicator {
    public struct Frame: Equatable {
        public let style: String
        public let label: String?
        public let fraction: Double
        public let position: String
        public let textColor: String
        public let fontSize: Double
        public let barColor: String
        public let trackColor: String
        public let barHeight: Double
    }

    static let defaultText = "Continuing in {seconds}"

    /// The authored hex colour, or nil when it is absent or not a colour.
    private static func colour(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces),
              s.range(of: "^#[0-9a-fA-F]{3,8}$", options: .regularExpression) != nil else { return nil }
        return s
    }

    private static func number(_ raw: Any?, _ fallback: Double, _ lo: Double, _ hi: Double) -> Double {
        var n = Double.nan
        if raw is Bool { n = .nan }
        else if let d = raw as? Double { n = d }
        else if let i = raw as? Int { n = Double(i) }
        else if let s = raw as? String { n = Double(s.trimmingCharacters(in: .whitespaces)) ?? .nan }
        guard n.isFinite else { return fallback }
        return min(hi, max(lo, n))
    }

    /// What is drawn `elapsed` seconds into a wait of `delay`, or nil when nothing is.
    public static func resolve(_ raw: [String: Any]?, delay: Double?, elapsed: Double) -> Frame? {
        guard let raw, (raw["show"] as? Bool) == true, let delay, delay > 0 else { return nil }
        let styleRaw = raw["style"] as? String
        let style = ["text", "bar", "both"].contains(styleRaw ?? "") ? styleRaw! : "both"
        let t = max(0, elapsed.isFinite ? elapsed : 0)
        let left = max(0, delay - t)
        let seconds = max(0, Int((left - 1e-9).rounded(.up)))
        let text = (raw["text"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? defaultText
        return Frame(
            style: style,
            label: style == "bar" ? nil : text.replacingOccurrences(of: "{seconds}", with: String(seconds)),
            fraction: (min(1, max(0, left / delay)) * 1000).rounded() / 1000,
            position: (raw["position"] as? String) == "top" ? "top" : "bottom",
            textColor: colour(raw["text_color"]) ?? "#6B7280",
            fontSize: number(raw["font_size"], 13, 8, 40),
            barColor: colour(raw["bar_color"]) ?? "#6366F1",
            trackColor: colour(raw["track_color"]) ?? "#E5E7EB",
            barHeight: number(raw["bar_height"], 4, 1, 16)
        )
    }

    /// The indicator for a step as published, `elapsed` seconds after it appeared.
    public static func resolve(step: OnboardingStep, elapsed: Double) -> Frame? {
        resolve(step.auto_advance_indicator?.mapValues { $0.value }, delay: StepAutoAdvance.delaySeconds(for: step), elapsed: elapsed)
    }
}

/// Draws one resolved moment of the countdown. Pure, so a test can render a given instant.
///
/// `inline: true` is how the step host draws it: the drawing takes only its own height, because the
/// step gives it that space above or below the content (`safeAreaInset`) rather than painting it over
/// the heading or the pinned button. `inline: false` fills its container and aligns to the edge.
struct AutoAdvanceIndicatorDrawing: View {
    let view: AutoAdvanceIndicator.Frame
    var inline: Bool = false

    var body: some View {
        let drawing = VStack(spacing: 6) {
            if let label = view.label {
                Text(label)
                    .font(.system(size: CGFloat(view.fontSize)))
                    .foregroundColor(Color(hex: view.textColor))
                    .accessibilityIdentifier("auto_advance_indicator_label")
            }
            if view.style != "text" {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: view.trackColor))
                        Capsule().fill(Color(hex: view.barColor))
                            .frame(width: geo.size.width * CGFloat(view.fraction))
                    }
                }
                .frame(height: CGFloat(view.barHeight))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .allowsHitTesting(false)

        if inline {
            drawing.frame(maxWidth: .infinity)
        } else {
            drawing.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: view.position == "top" ? .top : .bottom)
        }
    }
}

/// The live countdown for one placement. The step host draws `"top"` and `"bottom"` each in a
/// `safeAreaInset`, so the countdown reserves its own space and never covers the first block or the
/// pinned button; each draws only when the author's `position` is its own. Ticks from the moment the
/// step's timer was scheduled.
struct AutoAdvanceIndicatorOverlay: View {
    let step: OnboardingStep
    let startedAt: Date
    var placement: String = "bottom"

    var body: some View {
        if let first = AutoAdvanceIndicator.resolve(step: step, elapsed: 0), first.position == placement {
            TimelineView(.periodic(from: startedAt, by: 0.05)) { ctx in
                if let v = AutoAdvanceIndicator.resolve(step: step, elapsed: ctx.date.timeIntervalSince(startedAt)) {
                    AutoAdvanceIndicatorDrawing(view: v, inline: true)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
