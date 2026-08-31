import SwiftUI

/// Individual plan option with radio-style selection.
/// Supports card/badge styling from section data (Gap 11).
struct PlanCard: View {
    let plan: PaywallPlan
    let isSelected: Bool
    let onSelect: () -> Void
    var planIndex: Int = 0
    var loc: ((String, String) -> String)? = nil
    /// SPEC-084: Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil
    /// Gap 11: Card/badge styling from section data.
    var cardStyle: PlanCardStyle = PlanCardStyle()
    private var showIcon: Bool { cardStyle.showIcon }
    private var showImage: Bool { cardStyle.showImage }
    private var showSubtitle: Bool { cardStyle.showSubtitle }
    private var showFeatures: Bool { cardStyle.showFeatures }
    private var showSavings: Bool { cardStyle.showSavings }

    private var planNameTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["plan_name"]?.textStyle ?? sectionStyle?.elements?["label"]?.textStyle
    }
    private var priceTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["price"]?.textStyle
    }
    private var periodTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["period"]?.textStyle
    }
    private var badgeTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["badge"]?.textStyle
    }
    private var featureTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["feature"]?.textStyle
    }
    private var trialTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["trial_label"]?.textStyle
    }

    private var cornerRadius: CGFloat { cardStyle.cardCornerRadius ?? 12 }
    private var cardPadding: CGFloat { cardStyle.cardPadding ?? 16 }
    private var selectedBorder: Color { Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) }
    private var selectedBg: Color? {
        cardStyle.selectedBgColor.map { Color(hex: $0) }
    }
    /// Text color applied to plan name / price / subtitle when the card is selected.
    /// Lets you do "white text on a solid green selected card" without overriding
    /// each element's style manually.
    private var selectedTextColor: Color? {
        cardStyle.selectedTextColor.map { Color(hex: $0) }
    }
    /// Border color for non-selected cards. Defaults to a visible light gray
    /// (was white.opacity(0.15) — invisible on light paywall backgrounds).
    private var unselectedBorder: Color {
        if let hex = cardStyle.unselectedBorderColor {
            return Color(hex: hex)
        }
        return Color.gray.opacity(0.3)
    }
    /// Text color for UNSELECTED state — falls back to .primary (default dark).
    private var unselectedTextColor: Color { .primary }
    /// Resolved text color for the current selection state.
    private var effectiveTextColor: Color {
        if isSelected, let sel = selectedTextColor { return sel }
        return unselectedTextColor
    }
    private var selectedScaleValue: CGFloat { cardStyle.selectedScale ?? 1.0 }
    private var badgeBg: Color { Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) }
    private var badgeFg: Color { Color(hex: cardStyle.badgeTextColor ?? "#FFFFFF") }

    /// #589 — everything the card gives a plan, deliberately absent: no border, no background, no
    /// badge, no subtitle, no selection control. Just the name and price on one centred line.
    ///
    /// Still a Button, and still calls `onSelect` — the layout this exists for is one prominent
    /// card with "or £4.99/month, cancel anytime" beneath it, and a caption you cannot pick would
    /// be a different thing entirely. Selection is shown by weight rather than a control, because a
    /// radio circle is the card treatment this mode exists to remove.
    @ViewBuilder
    private var textOnlyBody: some View {
        Button(action: onSelect) {
            Text("\(loc?("plan.\(planIndex).name", plan.displayName) ?? plan.displayName) · \(loc?("plan.\(planIndex).price", plan.displayPrice) ?? plan.displayPrice)")
                .font(.system(size: plan.text_only_font_size ?? 13,
                              weight: isSelected ? .semibold : .regular))
                .foregroundColor(Color(hex: plan.text_only_color ?? "#9CA3AF"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        if (plan.display_mode ?? "card") == "text_only" {
            textOnlyBody
        } else {
            cardBody
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        Button(action: {
            print("[PlanCard] Tapped plan: \(plan.id ?? "nil")")
            onSelect()
        }) {
            VStack(spacing: 0) {
                // Plan image (if enabled)
                if showImage, let imgUrl = plan.image_url, let url = URL(string: imgUrl) {
                    BundledAsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.1)
                    }
                    .frame(height: 80)
                    .clipped()
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        // Row 1: Name + inline badge
                        HStack(spacing: 8) {
                            if let ts = planNameTextStyle {
                                Text(loc?("plan.\(planIndex).name", plan.displayName) ?? plan.displayName)
                                    .applyTextStyle(ts)
                                    .foregroundColor(isSelected && selectedTextColor != nil ? effectiveTextColor : nil)
                            } else {
                                Text(loc?("plan.\(planIndex).name", plan.displayName) ?? plan.displayName)
                                    .font(.headline)
                                    .foregroundColor(effectiveTextColor)
                            }

                            if let badge = plan.badge, badgePositionValue == "inline" {
                                badgeView(badge)
                            }
                        }

                        // Subtitle above price (if configured)
                        if showSubtitle && cardStyle.subtitlePosition == "above_price",
                           let desc = plan.description, !desc.isEmpty {
                            planSubtitleView(desc)
                        }

                        // Row 2: Price display, in whichever layout preset the author picked
                        priceBlockView

                        if let trial = plan.trialLabel {
                            // Round-30 — render `trialLabel` verbatim; the " free trial"
                            // suffix for duration-only trials now lives in the computed
                            // property (PaywallConfig.swift) so every layout + Android match.
                            if let ts = trialTextStyle {
                                Text(loc?("plan.\(planIndex).trial", trial) ?? trial)
                                    .applyTextStyle(ts)
                                    .foregroundColor(isSelected && selectedTextColor != nil ? effectiveTextColor : nil)
                            } else {
                                Text(loc?("plan.\(planIndex).trial", trial) ?? trial)
                                    .font(.caption)
                                    .foregroundColor(isSelected ? effectiveTextColor : Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                            }
                        }

                        // Subtitle below price (default position) or below name
                        if showSubtitle && cardStyle.subtitlePosition != "above_price",
                           let desc = plan.description, !desc.isEmpty {
                            planSubtitleView(desc)
                        }

                        // Divider between price/subtitle and features
                        if cardStyle.showDivider {
                            Divider()
                                .background(Color(hex: cardStyle.dividerColor ?? "#E5E7EB"))
                                .padding(.vertical, 2)
                        }

                        // Savings text
                        if showSavings, let savings = plan.savings_text, !savings.isEmpty {
                            Text(loc?("plan.\(planIndex).savings", savings) ?? savings)
                                .font(.caption2.bold())
                                .foregroundColor(isSelected && selectedTextColor != nil ? effectiveTextColor : Color(hex: "#22C55E"))
                        }

                        // Per-plan features
                        if showFeatures, let features = plan.features, !features.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(features, id: \.self) { feat in
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(isSelected && selectedTextColor != nil ? effectiveTextColor : Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                        Text(feat)
                                            .font(.caption2)
                                            .foregroundColor(isSelected && selectedTextColor != nil ? effectiveTextColor.opacity(0.85) : .secondary)
                                    }
                                }
                            }
                        }
                    }

                    Spacer()

                    // Plan icon
                    if showIcon, let iconName = plan.icon, !iconName.isEmpty {
                        Image(systemName: iconName)
                            .font(.title3)
                            .foregroundColor(isSelected && selectedTextColor != nil ? effectiveTextColor : .secondary)
                            .padding(.trailing, 4)
                    }

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(isSelected ? (selectedTextColor ?? selectedBorder) : unselectedBorder)
                }
                .padding(cardPadding)
                .contentShape(Rectangle()) // Make entire card area tappable including Spacer gaps
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // console card_height → minimum card height (matches Android heightIn(min:)
            // + PaywallPreview minHeight). nil param is unspecified, so it never forces a 0 floor.
            .frame(minHeight: cardStyle.cardHeight)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill({
                        // SPEC-419 — default the UNSELECTED card to a subtle translucent overlay
                        // (matches Android PaywallActivity `Color.White.copy(alpha = 0.1f)`), NOT
                        // `Color(.systemBackground)`. systemBackground resolves to solid WHITE under a
                        // light color scheme, so on a dark paywall the unselected card was a glaring
                        // white box that also hid its (white, config-set) text — and made the selected
                        // dark card look *less* prominent than the unselected one. A 10% white overlay
                        // recedes on dark backgrounds and lets the selected card + its border stand out,
                        // matching Android + the console preview. Explicit unselected_bg_color still wins.
                        let unselBg = cardStyle.unselectedBgColor.map { Color(hex: $0) } ?? Color.white.opacity(0.1)
                        return isSelected ? (selectedBg ?? unselBg) : unselBg
                    }())
            )
            .overlay(
                // .strokeBorder draws entirely INSIDE the path so the stroke
                // aligns cleanly with the fill's rounded corners. Previous
                // `.stroke` drew centered on the edge (half outside), which
                // showed up as thicker-looking corners than straight sides.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isSelected ? selectedBorder : unselectedBorder, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(
                color: (cardStyle.cardShadow != nil && cardStyle.cardShadow != "none" && cardStyle.cardShadow != "false")
                    ? .black.opacity(0.1) : .clear,
                radius: cardStyle.cardShadow == "sm" ? 2 : cardStyle.cardShadow == "lg" ? 8 : 4,
                x: 0,
                y: cardStyle.cardShadow == "sm" ? 1 : cardStyle.cardShadow == "lg" ? 4 : 2
            )
            // Badge as .overlay instead of a ZStack sibling — extends beyond the
            // card's bounds without being clipped, and doesn't affect the card's
            // intrinsic size (important in LazyVGrid cells where width is
            // constrained). .allowsHitTesting(false) so tapping the badge still
            // registers as a card tap.
            .overlay(alignment: badgeAlignment) {
                if let badge = plan.badge, badgePositionValue != "inline" {
                    badgeView(badge)
                        .fixedSize()
                        // Keep the pill sitting ON the card's top edge — half
                        // above, half inside — at any font size. The estimated
                        // badge height is `font + vertical padding` (4 + 4);
                        // offsetting by half of that gives the classic
                        // straddle-the-edge look and scales with bigger fonts
                        // instead of staying stuck at -10pt.
                        .offset(y: -(((cardStyle.badgeFontSize ?? 11) + 8) / 2))
                        .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        // Reserve vertical space for the badge's overhang so it doesn't get
        // clipped by the parent cell / section. Matches the offset above +
        // a small buffer for the border / shadow.
        .padding(.top, plan.badge != nil && badgePositionValue != "inline"
            ? max(12, ((cardStyle.badgeFontSize ?? 11) + 8) / 2 + 2)
            : 0)
        // scaleEffect removed — it created a compositing layer that allowed
        // content to visually overflow cell bounds in grid layouts. Selection
        // emphasis comes from border width (2pt selected vs 1pt unselected),
        // selected_bg_color and selected_text_color.
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    // MARK: - Price block (SPEC-438 #548)

    private var strikeGap: CGFloat { cardStyle.strikethroughGap ?? 4 }
    private var strikeColor: Color { Color(hex: cardStyle.strikethroughColor ?? "#9CA3AF") }

    /// The struck "was" price. `strikethrough_font_size` is honoured when authored; the
    /// `.caption` fallback is what shipped before, so unauthored paywalls are unchanged.
    @ViewBuilder
    private func struckPriceView(_ original: String) -> some View {
        if let size = cardStyle.strikethroughFontSize {
            Text(original).font(.system(size: size)).strikethrough().foregroundColor(strikeColor)
        } else {
            Text(original).font(.caption).strikethrough().foregroundColor(strikeColor)
        }
    }

    /// #588 — this plan's own price colour, which beats BOTH the section's `elements.price` style
    /// and the selected/unselected text colour. Section styling paints every plan the same; the
    /// point of this field is to make one tier's price stand out from the others, so anything that
    /// could override it would defeat it.
    private var planPriceColor: Color? {
        plan.price_color.flatMap { $0.isEmpty ? nil : Color(hex: $0) }
    }

    @ViewBuilder
    private var currentPriceView: some View {
        if let ts = priceTextStyle {
            Text(loc?("plan.\(planIndex).price", plan.displayPrice) ?? plan.displayPrice)
                .applyTextStyle(ts)
                .foregroundColor(planPriceColor ?? (isSelected && selectedTextColor != nil ? effectiveTextColor : nil))
        } else {
            Text(loc?("plan.\(planIndex).price", plan.displayPrice) ?? plan.displayPrice)
                .font(.subheadline.bold())
                .foregroundColor(planPriceColor ?? effectiveTextColor)
        }
    }

    /// `headline_stacked` mirrors the console preview: the current price large on its own
    /// line, with the struck was-price and the real charged total side by side underneath.
    /// Anything else falls through to the inline arrangement that shipped before, so
    /// existing paywalls render byte-identically.
    @ViewBuilder
    private var priceBlockView: some View {
        if (cardStyle.priceLayout ?? "inline") == "headline_stacked" {
            VStack(alignment: .leading, spacing: 2) {
                currentPriceView
                if plan.original_price_display?.isEmpty == false || plan.price_total_display?.isEmpty == false {
                    HStack(spacing: strikeGap) {
                        if let original = plan.original_price_display, !original.isEmpty {
                            struckPriceView(original)
                        }
                        if let total = plan.price_total_display, !total.isEmpty {
                            if let size = cardStyle.strikethroughFontSize {
                                Text(total).font(.system(size: size)).foregroundColor(effectiveTextColor)
                            } else {
                                Text(total).font(.caption).foregroundColor(effectiveTextColor)
                            }
                        }
                    }
                }
            }
        } else {
            HStack(spacing: strikeGap) {
                if let original = plan.original_price_display, !original.isEmpty {
                    struckPriceView(original)
                }
                currentPriceView
            }
        }
    }

    /// SPEC-438 (#544) — the subtitle renders as a coloured pill when the product
    /// authored one, and as plain text otherwise. The pill hugs its text rather than
    /// filling the row, which is what makes it read as a badge instead of a banner.
    // MARK: - Subtitle helper
    @ViewBuilder
    private func planSubtitleView(_ desc: String) -> some View {
        let text = loc?("plan.\(planIndex).description", desc) ?? desc
        if let badge = plan.description_badge, badge.enabled == true {
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(Color(hex: badge.text_color ?? "#FFFFFF"))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(hex: badge.bg_color ?? "#15803D"))
                .cornerRadius(badge.corner_radius ?? 6)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // #587 — the plan's own subtitle type wins over the section style, for the same reason
            // the price colour does. `fixedSize(vertical:)` is what lets it WRAP to its two lines
            // rather than truncate: `lineLimit(2)` alone caps the count, it does not grant the
            // height, and in a tight card the second line was being clipped away.
            Text(text)
                .font(plan.subtitle_font_size.map { Font.system(size: $0) } ?? .caption)
                .foregroundColor(
                    plan.subtitle_color.flatMap { $0.isEmpty ? nil : Color(hex: $0) }
                        ?? (isSelected && selectedTextColor != nil ? effectiveTextColor.opacity(0.8) : .secondary)
                )
                .multilineTextAlignment(subtitleAlignment)
                .frame(maxWidth: .infinity, alignment: subtitleFrameAlignment)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `subtitle_align` for both the text's own wrapping and the frame it sits in. Setting only
    /// `multilineTextAlignment` centres the SECOND line under the first while the block stays
    /// left-hugging, which reads as a bug rather than a centred subtitle.
    private var subtitleAlignment: TextAlignment {
        switch plan.subtitle_align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private var subtitleFrameAlignment: Alignment {
        switch plan.subtitle_align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    // MARK: - Badge helpers

    // Round-21 F2 — the console writes HYPHENATED positions ("top-left"/"top-right"/"top-center"), but
    // the switch matched only UNDERSCORED constants, so every authored value hit the default. Normalize
    // hyphen→underscore. Also: the default was `.topLeading` while the nil-fallback is "top_right"
    // (`.topTrailing`) and Android's `else` is TopEnd (top-right) — so an authored "top-right" landed on
    // the OPPOSITE corner per platform. Default is now `.topTrailing` (top-right) on both; top_center added.
    private var badgePositionValue: String {
        (cardStyle.badgePosition ?? "top_right").replacingOccurrences(of: "-", with: "_").lowercased()
    }

    private var badgeAlignment: Alignment {
        switch badgePositionValue {
        case "top_left": return .topLeading
        case "top_center": return .top
        case "top_right": return .topTrailing
        default: return .topTrailing
        }
    }

    @ViewBuilder
    private func badgeView(_ badge: String) -> some View {
        let text = loc?("plan.\(planIndex).badge", badge) ?? badge
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
                    Text(text).applyTextStyle(ts)
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
            .background(badgeBg)
            .clipShape(badgeShape(shape))
            .overlay(
                badgeShape(shape)
                    .stroke(borderCol, lineWidth: borderW)
            )
        }
    }

    private func badgeShape(_ style: String) -> some Shape {
        switch style {
        case "rectangle":
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

/// Helper to hold plan card styling values extracted from section data.
struct PlanCardStyle {
    var cardCornerRadius: CGFloat? = nil
    var cardPadding: CGFloat? = nil
    var cardGap: CGFloat? = nil
    var cardHeight: CGFloat? = nil  // Minimum plan-card height in pt (console card_height); applied as .frame(minHeight:)
    var cardShadow: String? = nil  // "none", "sm", "md", "lg", or "true"/"false"
    var badgePosition: String? = nil
    var badgeStyle: String? = nil
    var badgeBgColor: String? = nil
    var badgeTextColor: String? = nil
    var selectedBorderColor: String? = nil
    var selectedBgColor: String? = nil
    var selectedTextColor: String? = nil      // Flips plan text colors when selected
    var unselectedBorderColor: String? = nil  // Default subtle gray when nil
    var unselectedBgColor: String? = nil      // Default system background when nil; supports "transparent"
    var selectedScale: CGFloat? = nil
    // Badge enhancements (#12)
    var badgeBorderColor: String? = nil
    var badgeBorderWidth: CGFloat? = nil
    var badgeIcon: String? = nil      // SF Symbol or emoji before badge text
    // Badge font size (pt). Authored flat in the console; the SDK also
    // honors `sectionStyle.elements.badge.textStyle.font_size` via
    // `badgeTextStyle`, but this flat field is simpler for most customers.
    var badgeFontSize: CGFloat? = nil
    // Plan card extras
    var subtitlePosition: String? = nil  // "below_name", "below_price" (default), "above_price"
    var showDivider: Bool = false        // Divider line between price and features
    var dividerColor: String? = nil
    var strikethroughColor: String? = nil  // Color of struck-through original_price_display
    // SPEC-438 (#548) — size of the struck price and its gap to the current price were
    // hardcoded, so authors could set the colour but nothing else.
    var strikethroughFontSize: CGFloat? = nil
    var strikethroughGap: CGFloat? = nil
    // SPEC-438 (#548) — "inline" (default, unchanged) or "headline_stacked".
    var priceLayout: String? = nil
    // Show flags
    var showIcon: Bool = false
    var showImage: Bool = false
    var showSubtitle: Bool = false
    var showFeatures: Bool = false
    var showSavings: Bool = false

    init() {}

    init(from data: PaywallSectionData?) {
        self.cardCornerRadius = data?.cardCornerRadius
        self.cardPadding = data?.cardPadding
        self.cardGap = data?.cardGap
        self.cardHeight = data?.cardHeight
        // card_shadow can be Bool or String ("none", "sm", "md", "lg")
        if let val = data?.cardShadow?.value {
            if let b = val as? Bool { self.cardShadow = b ? "md" : "none" }
            else if let s = val as? String { self.cardShadow = s }
        }
        self.badgePosition = data?.badgePosition
        self.badgeStyle = data?.badgeStyle
        self.badgeBgColor = data?.badgeBgColor
        self.badgeTextColor = data?.badgeTextColor
        self.selectedBorderColor = data?.selectedBorderColor
        self.selectedBgColor = data?.selectedBgColor
        self.selectedTextColor = data?.selectedTextColor
        self.unselectedBorderColor = data?.unselectedBorderColor
        self.unselectedBgColor = data?.unselectedBgColor
        self.selectedScale = data?.selectedScale
        self.badgeBorderColor = data?.badgeBorderColor
        self.badgeBorderWidth = data?.badgeBorderWidth
        self.badgeIcon = data?.badgeIcon
        self.badgeFontSize = data?.badgeFontSize
        self.subtitlePosition = data?.subtitlePosition
        self.showDivider = data?.showDivider ?? false
        self.dividerColor = data?.dividerColor
        self.strikethroughColor = data?.strikethroughColor
        self.strikethroughFontSize = data?.strikethroughFontSize
        self.strikethroughGap = data?.strikethroughGap
        self.priceLayout = data?.priceLayout
        self.showIcon = data?.showPlanIcons ?? false
        self.showImage = data?.showPlanImages ?? false
        self.showSubtitle = data?.showPlanSubtitles ?? false
        self.showFeatures = data?.showPlanFeatures ?? false
        self.showSavings = data?.showSavings ?? false
    }
}

/// Type-erased AnyShape for badge styling.
struct AnyShape: Shape {
    private let _path: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        _path = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

/// Conditional view modifier helper.
extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
