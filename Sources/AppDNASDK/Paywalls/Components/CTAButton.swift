import SwiftUI

/// Maps a console cta_font_weight string (normal | medium | semibold | bold) to a SwiftUI
/// Font.Weight. Falls back to .semibold — the historical hardcoded CTA weight — so paywalls
/// that never set the field keep their existing look. Shared by CTAButton + both sticky footers.
func resolveCTAFontWeight(_ raw: String?) -> Font.Weight {
    switch raw {
    case "normal", "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    default: return .semibold
    }
}

/// Primary purchase CTA button with loading state.
struct CTAButton: View {
    let cta: PaywallCTA?
    let isPurchasing: Bool
    let onTap: () -> Void
    var loc: ((String, String) -> String)? = nil
    /// SPEC-084: Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil
    /// CTA gradient (from section data)
    var ctaGradient: PaywallGradient? = nil
    /// Override CTA text (from section config.text)
    var textOverride: String? = nil
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
    /// SPEC-490 (#651 item 1) — the CTA↔Restore gap. Unset keeps the previous hardcoded 8.
    var restoreGap: CGFloat? = nil
    /// #651 — Restore's own fill. Unset renders the plain link exactly as before.
    var restoreBgColor: String? = nil
    /// #651 — radius for that fill; only meaningful with `restoreBgColor`.
    var restoreCornerRadius: CGFloat? = nil
    /// Restore action
    var onRestore: (() -> Void)? = nil

    private var buttonElement: ElementStyleConfig? {
        sectionStyle?.elements?["button"]
    }
    private var buttonTextStyle: TextStyleConfig? {
        buttonElement?.textStyle
    }
    private var buttonBgColor: Color {
        if let hex = buttonElement?.background?.color {
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

    @ViewBuilder
    private var subscribeButton: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isPurchasing {
                    ProgressView()
                        .tint(.white)
                }
                if let ts = buttonTextStyle {
                    Text(isPurchasing ? "Processing..." : (loc?("cta.text", textOverride ?? cta?.text ?? "Subscribe") ?? textOverride ?? cta?.text ?? "Subscribe"))
                        .applyTextStyle(ts)
                } else {
                    Text(isPurchasing ? "Processing..." : (loc?("cta.text", textOverride ?? cta?.text ?? "Subscribe") ?? textOverride ?? cta?.text ?? "Subscribe"))
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
        .disabled(isPurchasing)
        .padding(.horizontal)
    }

    /// #651 — Restore could be recoloured and resized but never FILLED, so it could not be made to
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
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
              })
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
    /// #651 — Restore's own fill + radius, the pair the CTA already has. Unset = the plain link.
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
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
              })
            }
        }
    }
}
