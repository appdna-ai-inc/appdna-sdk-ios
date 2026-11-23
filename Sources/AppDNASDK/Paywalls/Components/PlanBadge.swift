import SwiftUI

/**
 Whether, and where, a plan layout draws a plan's badge ("Best value", "Most popular").

 Three plan layouts used to disagree across the surfaces. `pill_selector` drew the badge on
 Android only, `segmented_toggle` in the console preview only, and `product_as_cta` nowhere — so
 an author saw a badge in the preview that no phone drew, or an Android user saw one an iPhone
 user did not. They now all draw it. Every renderer asks
 this one question, and the shared fixtures `paywall_plan_badge_*` pin the answers on iOS and
 Android; the console preview answers it with `resolvePlanBadgePlacement`.

 Placements:
 - `below_price`  — inside the pill, under the price (`pill_selector`).
 - `above_segment` — centred over its own segment, in a row above the control (`segmented_toggle`).
   A segmented control cannot hold a view inside a segment, so the row is how a badge belongs to one.
 - `top_left` / `top_center` / `top_right` — straddling the button's top edge, as on a card
   (`product_as_cta`, which honours the authored `badge_position`).
 - `inline` — in the button's label, under the plan name (`product_as_cta` with `badge_position: inline`).
 - `card` — any other layout: the plan card decides, as it always has.
 */
enum PaywallPlanBadge {

    /// The text a plan's badge draws, or nil when there is nothing to draw. A blank badge draws nothing.
    static func text(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return raw
    }

    static func placement(layout: String?, badgePosition: String?) -> String {
        switch layout {
        case "pill_selector":
            return "below_price"
        case "segmented_toggle", "segmented":
            return "above_segment"
        case "product_as_cta":
            let p = (badgePosition ?? "top_right").replacingOccurrences(of: "-", with: "_").lowercased()
            switch p {
            case "top_left", "top_center", "inline": return p
            default: return "top_right"
            }
        default:
            return "card"
        }
    }

    /// How far a straddling badge rises above the edge it sits on: half its estimated height
    /// (font + 4 + 4 vertical padding), the same figure `PlanCard` uses.
    static func overhang(_ style: PlanCardStyle) -> CGFloat {
        ((style.badgeFontSize ?? 11) + 8) / 2
    }

    /// The room a straddling badge needs above its row, so the row above it does not cover it.
    static func reservedTop(_ style: PlanCardStyle) -> CGFloat {
        max(12, overhang(style) + 2)
    }

    static func alignment(_ placement: String) -> Alignment {
        switch placement {
        case "top_left": return .topLeading
        case "top_center": return .top
        default: return .topTrailing
        }
    }
}

/// A plan's badge, drawn with everything the section authors for it: the fill (solid or gradient),
/// the text colour and size, the `badge` element's text and container styles, the shape, the
/// border and the leading icon. One view for the plan card and for every layout that is not a card,
/// so a badge looks the same whichever layout draws it.
struct PlanBadgeView: View {
    let text: String
    let cardStyle: PlanCardStyle
    var sectionStyle: SectionStyleConfig? = nil

    private var badgeFg: Color { Color(hex: cardStyle.badgeTextColor ?? "#FFFFFF") }
    private var badgeTextStyle: TextStyleConfig? { sectionStyle?.elements?["badge"]?.textStyle }
    private func elementStyle(_ key: String) -> ElementStyleConfig? { sectionStyle?.elements?[key]?.container }

    var body: some View {
        let shape = cardStyle.badgeStyle ?? "capsule"
        let borderW = cardStyle.badgeBorderWidth ?? 0
        let borderCol = cardStyle.badgeBorderColor.map { Color(hex: $0) } ?? .clear

        if !text.isEmpty {
            HStack(spacing: 4) {
                // Badge icon (SF Symbol or emoji)
                if let icon = cardStyle.badgeIcon, !icon.isEmpty {
                    if UIImage(systemName: icon) != nil {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .bold))
                    } else {
                        Text(icon).font(.system(size: 10))
                    }
                }
                if let ts = badgeTextStyle {
                    // Merged over whichever unstyled badge font applies below.
                    Text(text).applyTextStyle(ts, defaults: TextStyleDefaults(
                        font: cardStyle.badgeFontSize.map { Font.system(size: $0, weight: .bold) } ?? .caption2.bold(),
                        size: Double(cardStyle.badgeFontSize ?? 11), weight: 700, color: badgeFg))
                } else if let size = cardStyle.badgeFontSize {
                    // Flat badge_font_size authored in the console. Falls back
                    // to .caption2 (11pt) when unset.
                    Text(text)
                        .font(.system(size: size, weight: .bold))
                        .foregroundColor(badgeFg)
                } else {
                    Text(text)
                        .font(.caption2.bold())
                        .foregroundColor(badgeFg)
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(PaywallBadgeFill.view(cardStyle))
            .clipShape(badgeShape(shape))
            .overlay(
                badgeShape(shape)
                    .stroke(borderCol, lineWidth: borderW)
            )
            // The badge's authored container style, applied OUTSIDE its own chrome so an
            // authored border or padding surrounds the badge rather than replacing it.
            .applyElementStyle(elementStyle("badge"))
            .accessibilityIdentifier("paywall.plan.badge")
        }
    }

    private func badgeShape(_ style: String) -> some Shape {
        switch style {
        /*
         * `square` is accepted as an alias for `rectangle`, which Android has done since it
         * shipped. Without it the value fell through to `default:` and drew a **capsule** — the
         * opposite of what the word means, so one hand-written document was a box on Android and a
         * pill here. The Console never writes it (its picker offers capsule/rectangle/rounded), so
         * nothing an author authored changes; what changes is an imported or hand-edited document
         * finally getting the shape it asked for.
         */
        case "rectangle", "square":
            return AnyShape(RoundedRectangle(cornerRadius: 2))
        case "rounded":
            return AnyShape(RoundedRectangle(cornerRadius: 6))
        case "ribbon":
            // Notched-ribbon: rectangle with a triangular notch cut into the trailing
            // edge, matching the console preview polygon (0,0 → 100,0 → 92,50 → 100,100 → 0,100).
            return AnyShape(RibbonBadgeShape())
        default: // capsule
            return AnyShape(Capsule())
        }
    }
}

/// Notched-ribbon badge shape — a rectangle whose trailing edge caves inward to a
/// point at mid-height, producing top/bottom pennant tails. Kept visually equivalent
/// to the console PaywallPreview clipPath and the Android GenericShape counterpart.
private struct RibbonBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
