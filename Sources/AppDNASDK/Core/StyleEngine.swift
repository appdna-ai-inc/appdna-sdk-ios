import SwiftUI

// MARK: - Config types for design tokens

/// Text styling properties from Firestore config.
public struct TextStyleConfig: Codable {
    public let font_family: String?
    public let font_size: Double?
    public let font_weight: Int?
    /// var (not let) so callers can build a copy with a different color when
    /// a higher-priority override needs to replace the decoded value.
    /// `SwiftUI.Text.foregroundColor` is baked in at view construction, so
    /// applying a second `.foregroundColor` modifier downstream is a no-op —
    /// the only reliable override path is to feed `applyTextStyle` a style
    /// with the new color already in place.
    public var color: String?
    public let alignment: String?
    public let line_height: Double?
    public let letter_spacing: Double?
    public let opacity: Double?
    public let text_transform: String?  // "none", "uppercase", "lowercase"
}

/// Background style (color, gradient, image, or animation).
public struct BackgroundStyleConfig: Codable {
    public let type: String?         // "color", "gradient", "image", "lottie", "rive"
    public let color: String?
    public let gradient: GradientConfig?
    public let image_url: String?
    public let image_fit: String?    // "cover", "contain", "fill", "none"
    public let overlay: String?      // hex color overlay
    /// Opacity applied to the overlay color (0–1). When nil, treats a
    /// 6-digit hex as fully opaque (legacy) EXCEPT when overlay is pure
    /// black/white — those default to 0.4 so images aren't silently
    /// obliterated by an editor-seeded default color.
    public let overlay_opacity: Double?
    // Animation backgrounds (item #1)
    public let lottie_url: String?   // Lottie animation URL for fullscreen bg
    public let rive_url: String?     // Rive animation URL for fullscreen bg
    public let animation_loop: Bool? // Loop animation (default true)
}

public struct GradientConfig: Codable {
    public let type: String?         // "linear", "radial"
    public let angle: Double?
    public let stops: [GradientStopConfig]?
}

public struct GradientStopConfig: Codable {
    public let color: String?
    public let position: Double?
}

/// Border style.
public struct BorderStyleConfig: Codable {
    public let width: Double?
    public let color: String?
    public let style: String?        // "solid", "dashed", "dotted", "none"
    public let radius: Double?
    public let radius_top_left: Double?
    public let radius_top_right: Double?
    public let radius_bottom_left: Double?
    public let radius_bottom_right: Double?
}

/// Shadow style.
public struct ShadowStyleConfig: Codable {
    public let x: Double?
    public let y: Double?
    public let blur: Double?
    public let spread: Double?
    public let color: String?
}

/// Spacing/padding.
public struct SpacingConfig: Codable {
    public let top: Double?
    public let right: Double?
    public let bottom: Double?
    public let left: Double?
}

/// Full container/element style combining background, border, shadow, padding, and text.
public struct ElementStyleConfig: Codable {
    public let background: BackgroundStyleConfig?
    public let border: BorderStyleConfig?
    public let shadow: ShadowStyleConfig?
    public let padding: SpacingConfig?
    public let corner_radius: Double?
    public let opacity: Double?
    /// SPEC-084: Per-element text style for inner text elements.
    public let textStyle: TextStyleConfig?

    enum CodingKeys: String, CodingKey {
        case background, border, shadow, padding, opacity
        case corner_radius
        case textStyle = "text_style"
    }
}

/// Per-section margin (top/bottom/left/right in points).
public struct SpacingMargin: Codable {
    public let top: Double?
    public let bottom: Double?
    public let left: Double?
    public let right: Double?
    public let leading: Double?
    public let trailing: Double?
}

/// Per-section position: vertical_align/horizontal_align/offsets.
public struct SectionPositionConfig: Codable {
    public let vertical_align: String?    // "top" | "center" | "bottom"
    public let horizontal_align: String?  // "left" | "center" | "right"
    public let vertical_offset: Double?
    public let horizontal_offset: Double?
}

/// Section-level style (container + per-element overrides + margin).
public struct SectionStyleConfig: Codable {
    public let container: ElementStyleConfig?
    public let elements: [String: ElementStyleConfig]?
    public let margin: SpacingMargin?
    public let position: SectionPositionConfig?
}

/// Animation configuration.
public struct AnimationConfig: Codable {
    public let entry_animation: String?       // slide_up, fade_in, scale_in, none
    public let entry_duration_ms: Int?
    public let section_stagger: String?       // fade_in, slide_in_left, slide_in_right, bounce, none
    public let section_stagger_delay_ms: Int?
    public let cta_animation: String?         // pulse, glow, bounce, none
    public let plan_selection_animation: String? // scale, border_highlight, glow, none
    public let dismiss_animation: String?     // slide_down, fade_out, none
}

/// Localization strings per locale.
public struct LocalizationConfig: Codable {
    public let localizations: [String: [String: String]]?
    public let default_locale: String?
}

// MARK: - SwiftUI View extensions for applying design tokens

extension View {
    /// #609 — a button's OWN authored font size, applied after `applyTextStyle` so it wins.
    ///
    /// Same specificity rule as the button's `text_color`, and for the same reason: the control sits
    /// on the button panel beside Height, so it has to beat the generic Typography size rather than
    /// be silently beaten by it. Nothing read this field on any surface, so the input did nothing.
    ///
    /// 🔴 Applied CONDITIONALLY. `.font(nil)` does not mean "inherit" in SwiftUI — it resets to the
    /// default font, which would drop the `.semibold` every unauthored button relies on. The same
    /// trap `foregroundColor(nil)` set for `text_color`, where a nil-passing version changed three
    /// goldens on CI while rendering identically on a Mac.
    @ViewBuilder
    func applyButtonFontSize(_ size: Double?, weight: Font.Weight = .semibold) -> some View {
        if let size, size > 0 {
            self.font(.system(size: CGFloat(size), weight: weight))
        } else {
            self
        }
    }

    /// Apply TextStyleConfig to a Text-like view.
    func applyTextStyle(_ style: TextStyleConfig?) -> some View {
        guard let s = style else { return AnyView(self) }
        let font = FontResolver.font(family: s.font_family, size: s.font_size, weight: s.font_weight)
        let base = self
            .font(font)
            .foregroundColor(s.color.map { Color(hex: $0) } ?? .primary)
            .multilineTextAlignment(textAlignment(s.alignment))
            .lineSpacing(lineSpacing(s.line_height, s.font_size))
            .opacity(s.opacity ?? 1.0)

        let kerned: AnyView = {
            if #available(iOS 16.0, *), let spacing = s.letter_spacing, spacing != 0 {
                return AnyView(base.kerning(CGFloat(spacing)))
            }
            return AnyView(base)
        }()
        // Apply text_transform (uppercase/lowercase)
        switch s.text_transform {
        case "uppercase": return AnyView(kerned.textCase(.uppercase))
        case "lowercase": return AnyView(kerned.textCase(.lowercase))
        default: return kerned
        }
    }

    /// Apply only the NON-FONT parts of a TextStyleConfig.
    ///
    /// `applyTextStyle` is `extension View` so its inner `.font(font)` uses
    /// the View-env overload of `.font`. When called on a chain that already
    /// has a direct `.font()` applied to a `Text`, the direct Text-font wins
    /// and the author's `font_size`/`font_weight` are silently ignored.
    ///
    /// Callers (text/heading blocks) therefore resolve the font themselves
    /// and apply it directly on the `Text(...)` — then call this helper for
    /// line spacing, kerning, opacity, and text-transform so those still
    /// come from the authored style.
    func applyTextStyleDecorations(_ style: TextStyleConfig?) -> some View {
        guard let s = style else { return AnyView(self) }
        let base = self
            .lineSpacing(lineSpacing(s.line_height, s.font_size))
            .opacity(s.opacity ?? 1.0)
        let kerned: AnyView = {
            if #available(iOS 16.0, *), let spacing = s.letter_spacing, spacing != 0 {
                return AnyView(base.kerning(CGFloat(spacing)))
            }
            return AnyView(base)
        }()
        switch s.text_transform {
        case "uppercase": return AnyView(kerned.textCase(.uppercase))
        case "lowercase": return AnyView(kerned.textCase(.lowercase))
        default: return kerned
        }
    }

    /// Apply ElementStyleConfig to a container view.
    func applyContainerStyle(_ style: ElementStyleConfig?) -> some View {
        guard let s = style else { return AnyView(self) }
        let defaultRadius = CGFloat(s.corner_radius ?? 0)
        let border = s.border

        // Per-corner radius support (SPEC-084)
        let hasPerCorner = border?.radius_top_left != nil || border?.radius_top_right != nil
            || border?.radius_bottom_left != nil || border?.radius_bottom_right != nil

        let base = self
            .padding(edgeInsets(s.padding))
            .background(StyleEngine.backgroundView(s.background))

        if hasPerCorner {
            let tl = CGFloat(border?.radius_top_left ?? Double(defaultRadius))
            let tr = CGFloat(border?.radius_top_right ?? Double(defaultRadius))
            let bl = CGFloat(border?.radius_bottom_left ?? Double(defaultRadius))
            let br = CGFloat(border?.radius_bottom_right ?? Double(defaultRadius))
            let path = PerCornerRadiusShape(topLeft: tl, topRight: tr, bottomLeft: bl, bottomRight: br)
            return AnyView(
                base
                    .clipShape(path)
                    .overlay(path.stroke(
                        Color(hex: border?.color ?? "transparent"),
                        lineWidth: CGFloat(border?.width ?? 0)
                    ))
                    .shadow(
                        color: Color(hex: s.shadow?.color ?? "transparent"),
                        radius: CGFloat(s.shadow?.blur ?? 0) / 2,
                        x: CGFloat(s.shadow?.x ?? 0),
                        y: CGFloat(s.shadow?.y ?? 0)
                    )
                    .opacity(s.opacity ?? 1.0)
            )
        } else {
            let shape = RoundedRectangle(cornerRadius: defaultRadius)
            return AnyView(
                base
                    .clipShape(shape)
                    .overlay(shape.stroke(
                        Color(hex: border?.color ?? "transparent"),
                        lineWidth: CGFloat(border?.width ?? 0)
                    ))
                    .shadow(
                        color: Color(hex: s.shadow?.color ?? "transparent"),
                        radius: CGFloat(s.shadow?.blur ?? 0) / 2,
                        x: CGFloat(s.shadow?.x ?? 0),
                        y: CGFloat(s.shadow?.y ?? 0)
                    )
                    .opacity(s.opacity ?? 1.0)
            )
        }
    }

    /// Apply ElementStyleConfig to an option card, or fall back to the default survey option border style.
    /// SPEC-084: Gap #19 — used by SingleChoiceView and MultiChoiceView.
    /// R89 — `accentColor` is the survey theme's resolved accent_color (threaded from the
    /// choice view). Was `Color.accentColor` (the app-global SwiftUI tint), which ignored
    /// SurveyTheme.accent_color so the selected card border rendered the host brand indigo
    /// instead of the console-authored accent. Defaults to `.accentColor` for other callers.
    func applyContainerStyleOrDefault(_ style: ElementStyleConfig?, isSelected: Bool, accentColor: Color = .accentColor) -> some View {
        if let s = style {
            return AnyView(self.applyContainerStyle(s))
        } else {
            return AnyView(
                self.background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                )
            )
        }
    }

    private func textAlignment(_ alignment: String?) -> TextAlignment {
        switch alignment {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private func lineSpacing(_ lineHeight: Double?, _ fontSize: Double?) -> CGFloat {
        guard let lh = lineHeight else { return 0 }
        let size = CGFloat(fontSize ?? 16)
        return (CGFloat(lh) - 1.0) * size
    }

    private func edgeInsets(_ padding: SpacingConfig?) -> EdgeInsets {
        guard let p = padding else { return EdgeInsets() }
        return EdgeInsets(
            top: CGFloat(p.top ?? 0),
            leading: CGFloat(p.left ?? 0),
            bottom: CGFloat(p.bottom ?? 0),
            trailing: CGFloat(p.right ?? 0)
        )
    }
}

// MARK: - Background rendering

enum StyleEngine {
    @ViewBuilder
    static func backgroundView(_ bg: BackgroundStyleConfig?) -> some View {
        switch bg?.type {
        case "transparent", "clear", "none":
            Color.clear
        case "color":
            let colorVal = bg?.color ?? "#FFFFFF"
            if colorVal == "transparent" || colorVal == "clear" {
                Color.clear
            } else {
                Color(hex: colorVal)
            }
        case "gradient":
            if let grad = bg?.gradient, let stops = grad.stops, stops.count >= 2 {
                switch grad.type {
                case "radial":
                    RadialGradient(
                        colors: stops.map { Color(hex: $0.color ?? "#000000") },
                        center: .center,
                        startRadius: 0,
                        endRadius: 300
                    )
                default: // linear
                    LinearGradient(
                        colors: stops.map { Color(hex: $0.color ?? "#000000") },
                        startPoint: gradientPoint(angle: grad.angle ?? 180, start: true),
                        endPoint: gradientPoint(angle: grad.angle ?? 180, start: false)
                    )
                }
            } else {
                Color.clear
            }
        case "image":
            ZStack {
                if let urlString = bg?.image_url, let url = URL(string: urlString) {
                    BundledAsyncPhaseImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: imageFit(bg?.image_fit))
                        default:
                            Color.clear
                        }
                    }
                }
                if let overlay = bg?.overlay, !overlay.isEmpty, overlay.lowercased() != "transparent" {
                    // If overlay_opacity is set explicitly, use it.
                    // Otherwise, a 6-digit pure-black / pure-white overlay
                    // (editor default) defaults to 0.4 so the image is
                    // visible. 8-digit hex is respected as-is (alpha baked in).
                    let defaultedOpacity: Double? = {
                        if let o = bg?.overlay_opacity { return o }
                        let lowered = overlay.lowercased()
                        let looksLikeDefault = lowered == "#000000" || lowered == "#ffffff" || lowered == "000000" || lowered == "ffffff"
                        return looksLikeDefault ? 0.4 : nil
                    }()
                    if let op = defaultedOpacity {
                        Color(hex: overlay).opacity(op)
                    } else {
                        Color(hex: overlay)
                    }
                }
            }
        case "lottie":
            // Full-screen Lottie animation background (item #1)
            ZStack {
                if let urlStr = bg?.lottie_url {
                    LottieBlockView(block: LottieBlock(
                        lottie_url: urlStr, lottie_json: nil,
                        autoplay: true, loop: bg?.animation_loop ?? true,
                        speed: 1.0, width: nil,
                        height: UIScreen.main.bounds.height,
                        alignment: "center",
                        play_on_scroll: nil, play_on_tap: nil, color_overrides: nil
                    ))
                    .ignoresSafeArea()
                }
                if let overlay = bg?.overlay, !overlay.isEmpty, overlay.lowercased() != "transparent" {
                    // If overlay_opacity is set explicitly, use it.
                    // Otherwise, a 6-digit pure-black / pure-white overlay
                    // (editor default) defaults to 0.4 so the image is
                    // visible. 8-digit hex is respected as-is (alpha baked in).
                    let defaultedOpacity: Double? = {
                        if let o = bg?.overlay_opacity { return o }
                        let lowered = overlay.lowercased()
                        let looksLikeDefault = lowered == "#000000" || lowered == "#ffffff" || lowered == "000000" || lowered == "ffffff"
                        return looksLikeDefault ? 0.4 : nil
                    }()
                    if let op = defaultedOpacity {
                        Color(hex: overlay).opacity(op)
                    } else {
                        Color(hex: overlay)
                    }
                }
            }
        case "rive":
            // Full-screen Rive animation background (item #1)
            ZStack {
                if let urlStr = bg?.rive_url {
                    RiveBlockView(block: RiveBlock(
                        rive_url: urlStr,
                        artboard: nil,
                        state_machine: "State Machine 1",
                        autoplay: true,
                        height: UIScreen.main.bounds.height,
                        alignment: "center",
                        inputs: nil, trigger_on_step_complete: nil
                    ))
                    .ignoresSafeArea()
                }
                if let overlay = bg?.overlay, !overlay.isEmpty, overlay.lowercased() != "transparent" {
                    // If overlay_opacity is set explicitly, use it.
                    // Otherwise, a 6-digit pure-black / pure-white overlay
                    // (editor default) defaults to 0.4 so the image is
                    // visible. 8-digit hex is respected as-is (alpha baked in).
                    let defaultedOpacity: Double? = {
                        if let o = bg?.overlay_opacity { return o }
                        let lowered = overlay.lowercased()
                        let looksLikeDefault = lowered == "#000000" || lowered == "#ffffff" || lowered == "000000" || lowered == "ffffff"
                        return looksLikeDefault ? 0.4 : nil
                    }()
                    if let op = defaultedOpacity {
                        Color(hex: overlay).opacity(op)
                    } else {
                        Color(hex: overlay)
                    }
                }
            }
        default:
            Color.clear
        }
    }

    private static func gradientPoint(angle: Double, start: Bool) -> UnitPoint {
        let rads = angle * .pi / 180
        let dx = sin(rads)
        let dy = -cos(rads)
        if start {
            return UnitPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2)
        }
        return UnitPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2)
    }

    /// SPEC-205: Public helper to render a `GradientConfig` as a SwiftUI
    /// LinearGradient (radial treated as linear fallback — matches the
    /// internal BackgroundConfig path). Exposed so per-feature renderers
    /// (surveys, paywalls) can share the same conversion.
    public static func linearGradient(from config: GradientConfig) -> LinearGradient {
        let stops = config.stops ?? []
        let colors = stops.map { Color(hex: $0.color ?? "#000000") }
        let angle = config.angle ?? 180
        return LinearGradient(
            colors: colors,
            startPoint: gradientPoint(angle: angle, start: true),
            endPoint: gradientPoint(angle: angle, start: false)
        )
    }

    private static func imageFit(_ fit: String?) -> ContentMode {
        switch fit {
        case "contain": return .fit
        default: return .fill
        }
    }
}

// MARK: - Per-corner radius shape (iOS 15 compatible)

struct PerCornerRadiusShape: Shape {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomLeft: CGFloat
    let bottomRight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
            radius: bottomRight, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
            radius: bottomLeft, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Localization helper

enum LocalizationEngine {
    static func resolve(key: String, localizations: [String: [String: String]]?, defaultLocale: String?, fallback: String) -> String {
        let deviceLocale = Locale.current.languageCode ?? "en"
        if let value = localizations?[deviceLocale]?[key] {
            return value
        }
        if let defLocale = defaultLocale, let value = localizations?[defLocale]?[key] {
            return value
        }
        return fallback
    }
}
