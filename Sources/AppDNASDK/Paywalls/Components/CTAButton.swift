import SwiftUI

/// Maps a console cta_font_weight string (normal | medium | semibold | bold) to a SwiftUI
/// Font.Weight. Falls back to .semibold — the historical hardcoded CTA weight — so paywalls
/// that never set the field keep their existing look. Shared by CTAButton + both sticky footers.
func resolveCTAFontWeight(_ raw: String?) -> Font.Weight {
    resolvePaywallFontWeight(raw, default: .semibold)
}

/// The same mapping with an explicit fallback.
///
/// The fallback is a PARAMETER because the countdown needs two of them: its label has
/// always drawn semibold and its digits bold, so one shared default would have changed the pixels
/// of every countdown already in the field.
func resolvePaywallFontWeight(_ raw: String?, default fallback: Font.Weight) -> Font.Weight {
    switch raw?.lowercased() {
    case "normal", "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    default: return fallback
    }
}

/// Primary purchase CTA button with loading state.
struct CTAButton: View {
    let cta: PaywallCTA?
    let isPurchasing: Bool
    /*
     * 🔴 WHETHER THERE IS ANYTHING TO BUY, which this button used to ignore.
     *
     * It was `.disabled(isPurchasing)` and nothing else, so a paywall whose plans are empty or
     * unresolvable drew a full-strength "Subscribe" that accepted the tap and did nothing:
     * `handleCTATap` returns on its first `guard`. Android has always disabled and dimmed it
     * (`enabled = !isPurchasing && selectedPlanId != null`, `alpha 0.5`), and iOS's OWN root-`cta`
     * fallback already carried `|| selectedPlanId == nil` — so the two iOS renderers of the same
     * control disagreed with each other as well as with Android.
     *
     * Defaulted to `true` so every existing construction keeps its behaviour; the renderer
     * supplies `selectedPlanId != nil`.
     */
    var canPurchase: Bool = true
    let onTap: () -> Void

    var loc: ((String, String) -> String)? = nil
    /// Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil
    /// CTA gradient (from section data)
    var ctaGradient: PaywallGradient? = nil
    /// Override CTA text (from section config.text)
    var textOverride: String? = nil
    /**
     The selected plan's name, appended AFTER localisation.

     🔴 WHY IT CANNOT BE PART OF `textOverride`. A multi-plan CTA names the plan it will
     buy, and the first version built the whole string ("Subscribe — Annual") and passed it as
     `textOverride` — which is the FALLBACK to `loc("cta.text", …)`. A paywall carrying a translation
     for `cta.text` therefore got the translation and LOST the plan name, so the mitigation vanished
     on exactly the paywalls hardest to check: a device walk in the default locale would never show
     it. Measured when this was found, 0 of 51 multi-plan paywalls were localised, so it was a
     future regression rather than a live one.

     Composing it here, after `loc`, means a localised CTA keeps its translation AND names the plan.
     The caller passes the plan's own localised name (`plan.<idx>.name`), so both halves are
     translated.
    */
    var planNameSuffix: String? = nil
    /// The localised `{cta}` / `{plan}` format; nil = the default.
    var planNameFormat: String? = nil
    /// CTA text font size (console "Section Font Size" = cta_font_size). Applied only when no
    /// Style-tab button text_style is set. Parity with Android (PaywallActivity.kt:2548, 17f
    /// baseline) + preview (PaywallPreview.tsx:1385).
    var ctaFontSize: CGFloat? = nil
    /// CTA text font weight (console "Font Weight" = cta_font_weight). Applied only when no
    /// Style-tab button text_style is set. Parity with Android + preview FONT_WEIGHT_MAP.
    var ctaFontWeight: String? = nil
    /// Restore purchase text (from section config)
    var restoreText: String? = nil
    /// Whether to show restore button
    var showRestore: Bool = false
    /// Restore button position relative to Subscribe: "above" or "below" (default: "below")
    var restorePosition: String = "below"
    /// Direct color override for the restore link (takes priority over restore_text element style)
    var restoreTextColor: String? = nil
    /// Direct font size override for the restore link
    var restoreFontSize: CGFloat? = nil
    /// The CTA↔Restore gap. Unset keeps the previous hardcoded 8.
    var restoreGap: CGFloat? = nil
    /// Restore's own fill. Unset renders the plain link exactly as before.
    var restoreBgColor: String? = nil
    /// Radius for that fill; only meaningful with `restoreBgColor`.
    var restoreCornerRadius: CGFloat? = nil
    /// Restore action
    var onRestore: (() -> Void)? = nil

    private var buttonElement: SectionElementConfig? {
        sectionStyle?.elements?["button"]
    }
    private var buttonTextStyle: TextStyleConfig? {
        buttonElement?.textStyle
    }
    /// The button's container half, from either spelling (`element_style` or flattened).
    private var buttonContainer: ElementStyleConfig? { buttonElement?.container }
    private var buttonBgColor: Color {
        if let hex = buttonContainer?.background?.color {
            return Color(hex: hex)
        }
        return Color(hex: cta?.resolvedBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))
    }
    private var buttonTextColor: Color {
        if let ts = buttonTextStyle, let hex = ts.color {
            return Color(hex: hex)
        }
        return Color(hex: cta?.resolvedTextColor ?? "#FFFFFF")
    }
    private var buttonCornerRadius: CGFloat {
        CGFloat(cta?.resolvedCornerRadius ?? 12.0)
    }

    private var restoreTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["restore_text"]?.textStyle
    }

    /// `@SwiftUI.Environment`, qualified: the SDK exports its own `enum Environment`
    /// (Configuration.swift) which shadows the property wrapper.
    @SwiftUI.Environment(\.paywallBackgroundHex) private var backgroundHex: String?

    /**
     The restore link's default colour, from the BACKGROUND rather than from the theme.

     `.secondary` is a system colour: grey in light appearance, and it does not know what the
     paywall is painted. Android's default was `white @ 60%`, which on the light paywall this was
     walked against drew white-on-white — the link was in the view tree, had its authored border,
     and was invisible. Two platforms, two different wrong answers to the same question.

     So both take the plan tiles' answer: the shared WCAG ladder the console and both SDKs agree on, kept at
     60% so an unauthored restore link still reads as secondary to the CTA.
     */
    private var restoreDefaultColor: Color {
        PaywallTextDefaults.readable(on: backgroundHex).opacity(0.6)
    }

    @ViewBuilder
    /// The label the button draws: localised first, THEN the plan's name appended.
    ///
    /// The already-contains-the-name guard lives here as well, so a translation that happens to
    /// include the plan's name does not receive it twice.
    private var displayText: String {
        let base = loc?("cta.text", textOverride ?? cta?.text ?? "Subscribe")
            ?? textOverride ?? cta?.text ?? "Subscribe"
        return CTAPlanName.compose(base: base, plan: planNameSuffix, format: planNameFormat)
    }

    private var subscribeButton: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isPurchasing {
                    ProgressView()
                        .tint(.white)
                }
                if let ts = buttonTextStyle {
                    Text(isPurchasing ? "Processing..." : displayText)
                        .applyTextStyle(ts)
                } else {
                    Text(isPurchasing ? "Processing..." : displayText)
                        .font(.system(size: ctaFontSize ?? 17, weight: resolveCTAFontWeight(ctaFontWeight)))
                        .foregroundColor(buttonTextColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CGFloat(cta?.resolvedPaddingVertical ?? 16))
            .background(
                Group {
                    if let grad = ctaGradient, let stops = grad.stops, stops.count >= 2 {
                        RoundedRectangle(cornerRadius: buttonCornerRadius)
                            .fill(LinearGradient(
                                stops: stops.map { Gradient.Stop(color: Color(hex: $0.color ?? "#000"), location: ($0.position ?? 0) / 100.0) },
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                    } else {
                        RoundedRectangle(cornerRadius: buttonCornerRadius)
                            .fill(buttonBgColor)
                    }
                }
            )
        }
        .disabled(isPurchasing || !canPurchase)
        // And it has to LOOK unavailable, not merely behave so. Android's 0.5, because a
        // control that refuses a tap while looking normal is the harder defect to report.
        .opacity(canPurchase ? 1 : 0.5)
        // The rest of the button's authored container. Its background is already resolved
        // into `buttonBgColor` and painted above, so only the other halves are applied here.
        .applyElementStyle(buttonContainer?.withoutBackground)
        .padding(.horizontal)
    }

    /// Restore could be recoloured and resized but never FILLED, so it could not be made to
    /// look like a second button beside the CTA. Applied to the composed label so all three styling
    /// branches below get it, and a nil `restoreBgColor` leaves the view tree byte-identical.
    @ViewBuilder
    private func restoreFill(_ view: some View) -> some View {
        if let hex = restoreBgColor, !hex.isEmpty {
            view
                .frame(maxWidth: .infinity)
                .background(Color(hex: hex))
                .clipShape(RoundedRectangle(cornerRadius: restoreCornerRadius ?? 0))
        } else {
            view
        }
    }

    @ViewBuilder
    private var restoreButton: some View {
        if showRestore, let text = restoreText, !text.isEmpty {
            Button(action: { onRestore?() }) {
              restoreFill(Group {
                // Priority order:
                // 1. Direct restoreTextColor/restoreFontSize from section data (console Content tab)
                // 2. restore_text element style (console Style tab)
                // 3. Default: .secondary gray at .subheadline size
                let directColor: Color? = restoreTextColor.map { Color(hex: $0) }
                let directFont: Font = restoreFontSize.map { .system(size: $0) } ?? .subheadline
                if let directColor = directColor {
                    Text(text)
                        .font(directFont)
                        .foregroundColor(directColor)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                } else if let ts = restoreTextStyle {
                    Text(text)
                        .applyTextStyle(ts)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                } else {
                    Text(text)
                        .font(directFont)
                        .foregroundColor(restoreDefaultColor)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
              })
              // The restore link's authored container.
              .applyElementStyle(sectionStyle?.elements?["restore_text"]?.container)
            }
        }
    }

    var body: some View {
        VStack(spacing: restoreGap ?? 8) {
            if restorePosition == "above" {
                restoreButton
                subscribeButton
            } else {
                subscribeButton
                restoreButton
            }
        }
    }
}

/// Restore-purchase link rendered outside the CTA section's container so its
/// background is always the page background (transparent) — even when the
/// CTA section uses a solid container color for the subscribe button.
struct RestoreLinkView: View {
    let text: String?
    let show: Bool
    var textColor: String? = nil
    var fontSize: CGFloat? = nil
    var style: TextStyleConfig? = nil
    /// The `restore_text` element's container half. This view is the SECOND renderer of the
    /// restore link (CTAButton has the other), and the console has ONE control for both, so a
    /// container wired to only one of them is invisible on whichever layout the host happens to
    /// take — a defect that has already hit other duplicated render sites.
    var elementStyle: ElementStyleConfig? = nil
    /// Same default as `CTAButton.restoreDefaultColor`; the console has ONE control.
    var backgroundHex: String? = nil
    /// Restore's own fill + radius, the pair the CTA already has. Unset = the plain link.
    var bgColor: String? = nil
    var cornerRadius: CGFloat? = nil
    let onRestore: (() -> Void)?

    /// Mirrors `CTAButton.restoreFill` — the two restore renderers must agree, because the console
    /// has one control and a host sees whichever path its layout happens to take.
    @ViewBuilder
    private func restoreFill(_ view: some View) -> some View {
        if let hex = bgColor, !hex.isEmpty {
            view
                .frame(maxWidth: .infinity)
                .background(Color(hex: hex))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? 0))
        } else {
            view
        }
    }

    var body: some View {
        if show, let text = text, !text.isEmpty {
            Button(action: { onRestore?() }) {
              restoreFill(Group {
                let directColor: Color? = textColor.map { Color(hex: $0) }
                let directFont: Font = fontSize.map { .system(size: $0) } ?? .subheadline
                if let directColor = directColor {
                    Text(text)
                        .font(directFont)
                        .foregroundColor(directColor)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                } else if let ts = style {
                    Text(text)
                        .applyTextStyle(ts)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                } else {
                    Text(text)
                        .font(directFont)
                        .foregroundColor(PaywallTextDefaults.readable(on: backgroundHex).opacity(0.6))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
              })
              .applyElementStyle(elementStyle)
            }
        }
    }
}
