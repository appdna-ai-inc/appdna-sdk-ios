import SwiftUI

/**
 What a plan badge is FILLED with: a solid colour, or a linear gradient.

 A plan badge took one solid colour (`badge_bg_color`), so a two-tone "Best offer" badge could not be
 authored. `badge_gradient` is the same shape as the CTA's `cta_gradient` — `{ type, angle, stops: [{ color,
 position }] }` — so the console reuses its gradient editor. It wins when it has at least two stops with a
 colour; otherwise the badge keeps `badge_bg_color`, then the brand accent, then `#6366F1`.

 `angle` is in CSS degrees (90 = left to right, the default; 180 = top to bottom), as the console preview
 draws it. A stop's `position` is 0–100; a stop without one is spread evenly.

 Every badge site in `PaywallRenderer` and `PlanCard` draws through `view(_:)`, and the shared fixture
 `paywall_badge_fill` pins `resolve` here and in Android's `PaywallBadgeFill`.
 */
enum PaywallBadgeFill {

    struct Resolved: Equatable {
        /// "solid" or "gradient".
        let kind: String
        let colors: [String]
        /// 0...1 per colour; one entry (0) for a solid fill.
        let locations: [Double]
        let angle: Double
    }

    static let fallback = "#6366F1"

    static func resolve(bgColor: String?, gradient: PaywallGradient?, accent: String?) -> Resolved {
        let stops = (gradient?.stops ?? []).filter { !($0.color ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if stops.count >= 2 {
            let n = Double(stops.count - 1)
            return Resolved(
                kind: "gradient",
                colors: stops.map { $0.color!.trimmingCharacters(in: .whitespaces) },
                locations: stops.enumerated().map { i, s in min(max((s.position ?? (Double(i) / n * 100)) / 100, 0), 1) },
                angle: gradient?.angle ?? 90
            )
        }
        let solid = [bgColor, accent].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? fallback
        return Resolved(kind: "solid", colors: [solid], locations: [0], angle: 0)
    }

    static func resolve(_ style: PlanCardStyle) -> Resolved {
        resolve(bgColor: style.badgeBgColor, gradient: style.badgeGradient, accent: AppDNA.brandAccentHex)
    }

    /// The badge's background, for `.background(...)` before its clip shape.
    static func view(_ style: PlanCardStyle) -> AnyView {
        let r = resolve(style)
        guard r.kind == "gradient" else { return AnyView(Color(hex: r.colors[0])) }
        let rads = r.angle * .pi / 180
        let dx = sin(rads), dy = -cos(rads)
        return AnyView(LinearGradient(
            stops: zip(r.colors, r.locations).map { Gradient.Stop(color: Color(hex: $0), location: $1) },
            startPoint: UnitPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2),
            endPoint: UnitPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2)
        ))
    }
}
