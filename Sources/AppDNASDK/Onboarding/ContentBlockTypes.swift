import SwiftUI
import MapKit
import PhotosUI

// MARK: - Content Block Type

public enum ContentBlockType: String, Codable {
    case heading, text, image, button, spacer, list, divider, badge, icon, toggle, video
    // SPEC-085: Rich media block types
    case lottie, rive
    // SPEC-089d Phase A: New onboarding block types
    case page_indicator, wheel_picker, pulsing_avatar, social_login
    case timeline, animated_loading, star_background, countdown_timer
    case rating, rich_text, progress_bar
    // SPEC-089d Phase F: Container & advanced block types
    case stack, custom_view, date_wheel_picker, circular_gauge, row
    // SPEC-089d Nurrai
    case pricing_card
    // EPIC-3 — media gallery (horizontal row of image tiles)
    case media_gallery
    // EPIC-4b — section background (vertical color zones behind overlaid content)
    case section_background
    // EPIC-8 — swipeable carousel (paged content + dot indicator)
    case carousel
    case otp_input
    case warning_banner
    case password_strength
    case speech_bubble
    case feedback_panel
    case summary_screen
    case press_hold_confirm
    case health_connect
    case settings_footer
    case memory_match
    case calendar_month
    // SPEC-089d Phase 3: Form input block types (22 types)
    case input_text, input_textarea, input_number, input_email, input_phone
    case input_password, input_date, input_time, input_datetime
    case input_select, input_slider, input_toggle, input_stepper, input_segmented
    case input_location, input_rating, input_range_slider, input_image_picker
    case input_color, input_url, input_chips, input_signature
    // Catch-all for future/unknown block types — prevents decoding failures
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ContentBlockType(rawValue: rawValue) ?? .unknown
    }
}

// MARK: - Block Style Design Tokens (SPEC-089d §6.1)

/// Per-block styling: background, border, shadow, padding, margin, opacity.
public struct BlockStyle: Codable {
    public var background_color: String?
    public var background_gradient: BlockGradientStyle?
    public var border_color: String?
    public var border_width: Double?
    public var border_style: String?   // solid, dashed, dotted
    public var border_radius: Double?
    public var shadow: BlockShadowStyle?
    public var padding_top: Double?
    public var padding_right: Double?
    public var padding_bottom: Double?
    public var padding_left: Double?
    public var margin_top: Double?
    public var margin_bottom: Double?
    public var margin_left: Double?
    public var margin_right: Double?
    public var opacity: Double?
}

/// Shadow definition for block_style.
public struct BlockShadowStyle: Codable {
    public var x: Double?
    public var y: Double?
    public var blur: Double?
    public var spread: Double?
    public var color: String?
}

/// Gradient definition for block_style background.
public struct BlockGradientStyle: Codable {
    public var angle: Double?
    public var start: String?
    public var end: String?
}

// MARK: - Block Style ViewModifier (SPEC-089d §6.1)

/// Applies `block_style` design tokens to any content block view.
struct BlockStyleModifier: ViewModifier {
    let style: BlockStyle?

    func body(content: Content) -> some View {
        if let s = style {
            content
                // Inner padding
                .padding(.top, CGFloat(s.padding_top ?? 0))
                .padding(.trailing, CGFloat(s.padding_right ?? 0))
                .padding(.bottom, CGFloat(s.padding_bottom ?? 0))
                .padding(.leading, CGFloat(s.padding_left ?? 0))
                // Background
                .background(backgroundView(s))
                // Border
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(s.border_radius ?? 0)))
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat(s.border_radius ?? 0))
                        .stroke(
                            Color(hex: s.border_color ?? "transparent"),
                            style: borderStrokeStyle(s)
                        )
                )
                // Shadow
                .shadow(
                    color: Color(hex: s.shadow?.color ?? "transparent"),
                    radius: CGFloat(s.shadow?.blur ?? 0) / 2,
                    x: CGFloat(s.shadow?.x ?? 0),
                    y: CGFloat(s.shadow?.y ?? 0)
                )
                // Opacity
                .opacity(s.opacity ?? 1.0)
                // Outer margin
                .padding(.top, CGFloat(s.margin_top ?? 0))
                .padding(.bottom, CGFloat(s.margin_bottom ?? 0))
                .padding(.leading, CGFloat(s.margin_left ?? 0))
                .padding(.trailing, CGFloat(s.margin_right ?? 0))
        } else {
            content
        }
    }

    @ViewBuilder
    private func backgroundView(_ s: BlockStyle) -> some View {
        if let gradient = s.background_gradient {
            LinearGradient(
                colors: [Color(hex: gradient.start ?? "#000000"), Color(hex: gradient.end ?? "#FFFFFF")],
                startPoint: gradientStartPoint(angle: gradient.angle ?? 0),
                endPoint: gradientEndPoint(angle: gradient.angle ?? 0)
            )
        } else if let bgColor = s.background_color {
            Color(hex: bgColor)
        } else {
            Color.clear
        }
    }

    private func borderStrokeStyle(_ s: BlockStyle) -> StrokeStyle {
        let lineWidth = CGFloat(s.border_width ?? 0)
        switch s.border_style {
        case "dashed":
            return StrokeStyle(lineWidth: lineWidth, dash: [8, 4])
        case "dotted":
            return StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [2, 4])
        default: // solid
            return StrokeStyle(lineWidth: lineWidth)
        }
    }

    private func gradientStartPoint(angle: Double) -> UnitPoint {
        let rads = angle * .pi / 180
        return UnitPoint(x: 0.5 - sin(rads) / 2, y: 0.5 + cos(rads) / 2)
    }

    private func gradientEndPoint(angle: Double) -> UnitPoint {
        let rads = angle * .pi / 180
        return UnitPoint(x: 0.5 + sin(rads) / 2, y: 0.5 - cos(rads) / 2)
    }
}

extension View {
    /// Apply block_style design tokens (SPEC-089d §6.1).
    func applyBlockStyle(_ style: BlockStyle?) -> some View {
        modifier(BlockStyleModifier(style: style))
    }
}

// MARK: - Visibility Condition (SPEC-089d §6.3)

/// Condition that determines whether a block should be rendered.
public struct VisibilityCondition: Codable {
    public let type: String?       // always, when_equals, when_not_equals, when_not_empty, when_empty, when_gt, when_lt, expression
    public let variable: String?  // dot-path e.g. "responses.step1.age"
    public let value: AnyCodable? // comparison value
    public let expression: String? // for complex expressions
}

/// Evaluates a visibility condition against the current data context.
func evaluateVisibilityCondition(
    _ condition: VisibilityCondition?,
    responses: [String: Any],
    hookData: [String: Any]?,
    userTraits: [String: Any]? = nil,
    sessionData: [String: Any]? = nil
) -> Bool {
    guard let cond = condition else { return true }

    switch cond.type {
    case "always":
        return true
    case "when_equals":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData)
        let expected = cond.value?.value
        return valuesEqual(resolved, expected)
    case "when_not_equals":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData)
        let expected = cond.value?.value
        return !valuesEqual(resolved, expected)
    case "when_not_empty":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData)
        return resolved.map { "\($0)" != "" } ?? false
    case "when_empty":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData)
        return resolved.map { "\($0)" == "" } ?? true
    case "when_gt":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData)
        return compareNumeric(resolved, cond.value?.value) == .orderedDescending
    case "when_lt":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData)
        return compareNumeric(resolved, cond.value?.value) == .orderedAscending
    default:
        return true // unknown condition types default to visible
    }
}

/// Resolves a dot-path variable from the evaluation context.
func resolveDotPath(
    _ path: String?,
    responses: [String: Any],
    hookData: [String: Any]?,
    userTraits: [String: Any]?,
    sessionData: [String: Any]?
) -> Any? {
    guard let path = path, !path.isEmpty else { return nil }
    let parts = path.split(separator: ".").map(String.init)
    guard parts.count >= 2 else { return nil }

    let root: [String: Any]?
    switch parts[0] {
    case "responses": root = responses
    case "hook_data": root = hookData
    case "user": root = userTraits
    case "session": root = sessionData
    default: root = nil
    }

    guard var current: Any = root else { return nil }
    for part in parts.dropFirst() {
        if let dict = current as? [String: Any], let next = dict[part] {
            current = next
        } else {
            return nil
        }
    }
    return current
}

/// Compares two values as strings for equality.
func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
    if a == nil && b == nil { return true }
    guard let a = a, let b = b else { return false }
    return "\(a)" == "\(b)"
}

/// Compares two values numerically.
func compareNumeric(_ a: Any?, _ b: Any?) -> ComparisonResult {
    let numA = toDouble(a)
    let numB = toDouble(b)
    guard let na = numA, let nb = numB else { return .orderedSame }
    if na < nb { return .orderedAscending }
    if na > nb { return .orderedDescending }
    return .orderedSame
}

func toDouble(_ value: Any?) -> Double? {
    guard let v = value else { return nil }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}

// MARK: - Entrance Animation (SPEC-089d §6.4)

/// Configuration for entrance animation on a content block.
public struct EntranceAnimation: Codable {
    public let type: String?       // none, fade_in, slide_up, slide_down, slide_left, slide_right, scale_up, scale_down, bounce, flip
    public let duration_ms: Int?  // 100-2000
    public let delay_ms: Int?     // 0-5000
    public let easing: String?    // linear, ease, ease_in, ease_out, ease_in_out, spring
    public let spring_damping: Double? // 0.1-1.0
}

// MARK: - Pressed Style (SPEC-089d §6.5)

/// Style to apply when an interactive element is pressed.
public struct PressedStyle: Codable {
    public let bg_color: String?
    public let text_color: String?
    public let scale: Double?    // 0.85-1.0
    public let opacity: Double?  // 0.5-1.0
}

// MARK: - Form Field Style (SPEC-089d §5.2)

/// Custom visual styling for form input blocks.
public struct FormFieldBlockStyle: Codable {
    public let background_color: String?
    public let border_color: String?
    public let border_width: Double?
    public let corner_radius: Double?
    public let height: String?           // sm, md, lg
    public let text_color: String?
    public let placeholder_color: String?
    public let font_size: Double?
    public let font_weight: String?
    public let focused_border_color: String?
    public let focused_background_color: String?
    public let label_color: String?
    public let label_font_size: Double?
    public let error_border_color: String?
    public let error_text_color: String?
    public let track_color: String?
    public let fill_color: String?
    public let thumb_color: String?
    public let toggle_on_color: String?
    public let toggle_off_color: String?
    // Select v2 (Mrozu QA) — per-option styling extras applied by the select renderers.
    public let option_font_family: String?      // font family for option title/subtitle/labels
    public let option_corner_radius: Double?    // option card corner radius (falls back to corner_radius ?? 10)
    public let option_text_wrap: Bool?          // true → option text wraps fully; false → single-line truncate
    public let option_image_scale: String?      // "contain" (default) | "cover" | "fit" for per-option images
    public let checkmark_color: String?         // radio/checkmark indicator color, decoupled from fill/accent
}

/// Option for select, chips, and segmented inputs.
/// Editor writes "id" + "label"; SDK accepts both "id"/"value" for the identifier.
public struct InputOption: Codable, Identifiable {
    public let id: String?
    public let label: String?
    public let value: String?
    public let icon: String?
    public let image_url: String?
    // State-variant image urls — when set, the grid/stacked renderer
    // swaps the option's image between selected and unselected states.
    // Falls back to `image_url` when either side is nil.
    public let selected_image_url: String?
    public let unselected_image_url: String?
    // Per-option subtitle (shown below label in a smaller font)
    public let subtitle: String?
    // Per-option text styling — overrides field_config defaults when set
    public let title_color: String?
    public let subtitle_color: String?
    public let title_font_size: Double?
    public let subtitle_font_size: Double?
    public let title_font_weight: String?  // regular, medium, semibold, bold
    // Grid toggle: icon to show when selected/unselected (SF Symbol name or emoji)
    public let selected_icon: String?
    public let unselected_icon: String?
    // Image overlay: colored circle with opacity rendered over the option image
    public let image_overlay_color: String?
    public let image_overlay_opacity: Double?
    // EPIC-1 — selected-state image tint (falls back to image_overlay_* when unset)
    public let selected_image_overlay_color: String?
    public let selected_image_overlay_opacity: Double?
    // EPIC-1 — per-option image clip shape: "circle" (default) | "rounded" | "square"
    public let image_shape: String?
    // Per-option border overrides
    public let border_color: String?
    public let selected_border_color: String?
    // Per-option bg for the unselected state. Falls through to
    // field_config.bg_color / field_style.background_color when nil.
    public let bg_color: String?
    // Per-option selected state overrides (each option can have its own highlight color)
    public let selected_bg_color: String?
    public let selected_text_color: String?
    // Per-option override for grid cell content alignment. Falls back to
    // the block-level `grid_cell_alignment` when nil so existing flows
    // inherit the overall layout.
    public let cell_alignment: String?  // "leading" | "center" | "trailing"
    // SPEC-070 EPIC-1 — per-option additions
    public let text_alignment: String?  // "leading" | "center" | "trailing" (stacked rows)
    public let leading_text: String?    // small label at the START of the row
    public let trailing_text: String?   // small label at the END of the row (e.g. "Casual")
    public let badge: OptionBadge?      // e.g. a RECOMMENDED chip on the option

    public struct OptionBadge: Codable {
        public let text: String?
        public let bg_color: String?
        public let text_color: String?
        public let position: String?    // top_trailing | top_leading | trailing | leading | bottom_*
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try container.decodeIfPresent(String.self, forKey: .id)
        let rawValue = try container.decodeIfPresent(String.self, forKey: .value)
        self.id = rawId ?? rawValue ?? ""
        self.value = rawValue ?? rawId
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon)
        self.image_url = try container.decodeIfPresent(String.self, forKey: .image_url)
        self.selected_image_url = try container.decodeIfPresent(String.self, forKey: .selected_image_url)
        self.unselected_image_url = try container.decodeIfPresent(String.self, forKey: .unselected_image_url)
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.title_color = try container.decodeIfPresent(String.self, forKey: .title_color)
        self.subtitle_color = try container.decodeIfPresent(String.self, forKey: .subtitle_color)
        self.title_font_size = try container.decodeIfPresent(Double.self, forKey: .title_font_size)
        self.subtitle_font_size = try container.decodeIfPresent(Double.self, forKey: .subtitle_font_size)
        self.title_font_weight = try container.decodeIfPresent(String.self, forKey: .title_font_weight)
        self.selected_icon = try container.decodeIfPresent(String.self, forKey: .selected_icon)
        self.unselected_icon = try container.decodeIfPresent(String.self, forKey: .unselected_icon)
        self.image_overlay_color = try container.decodeIfPresent(String.self, forKey: .image_overlay_color)
        self.image_overlay_opacity = try container.decodeIfPresent(Double.self, forKey: .image_overlay_opacity)
        self.selected_image_overlay_color = try container.decodeIfPresent(String.self, forKey: .selected_image_overlay_color)
        self.selected_image_overlay_opacity = try container.decodeIfPresent(Double.self, forKey: .selected_image_overlay_opacity)
        self.image_shape = try container.decodeIfPresent(String.self, forKey: .image_shape)
        self.border_color = try container.decodeIfPresent(String.self, forKey: .border_color)
        self.selected_border_color = try container.decodeIfPresent(String.self, forKey: .selected_border_color)
        self.bg_color = try container.decodeIfPresent(String.self, forKey: .bg_color)
        self.selected_bg_color = try container.decodeIfPresent(String.self, forKey: .selected_bg_color)
        self.selected_text_color = try container.decodeIfPresent(String.self, forKey: .selected_text_color)
        self.cell_alignment = try container.decodeIfPresent(String.self, forKey: .cell_alignment)
        self.text_alignment = try container.decodeIfPresent(String.self, forKey: .text_alignment)
        self.leading_text = try container.decodeIfPresent(String.self, forKey: .leading_text)
        self.trailing_text = try container.decodeIfPresent(String.self, forKey: .trailing_text)
        self.badge = try container.decodeIfPresent(OptionBadge.self, forKey: .badge)
    }

    /// Non-optional value — falls back to id if value is nil.
    public var resolvedValue: String { value ?? id ?? "" }

    enum CodingKeys: String, CodingKey {
        case id, label, value, icon, image_url
        case selected_image_url, unselected_image_url
        case subtitle, title_color, subtitle_color
        case title_font_size, subtitle_font_size, title_font_weight
        case selected_icon, unselected_icon
        case image_overlay_color, image_overlay_opacity, image_shape
        case selected_image_overlay_color, selected_image_overlay_opacity
        case border_color, selected_border_color
        case bg_color, selected_bg_color, selected_text_color
        case cell_alignment
        case text_alignment, leading_text, trailing_text, badge
    }

    /// Resolve which image URL to show for the given selection state.
    /// Precedence: selected/unselected variant → default image_url → nil.
    public func resolvedImageURL(isSelected: Bool) -> String? {
        let variant = isSelected ? selected_image_url : unselected_image_url
        if let v = variant, !v.isEmpty { return v }
        return image_url
    }
}

// MARK: - Relative Sizing Helper (SPEC-089d §6.7)

/// Parses a size string and returns a frame modifier.
enum SizeValue {
    case fill
    case auto_
    case percent(CGFloat)
    case px(CGFloat)

    static func parse(_ str: String?) -> SizeValue? {
        guard let s = str?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if s == "fill" { return .fill }
        if s == "auto" { return .auto_ }
        if s.hasSuffix("%"), let num = Double(s.dropLast()) { return .percent(CGFloat(num) / 100.0) }
        if s.hasSuffix("px"), let num = Double(s.dropLast(2)) { return .px(CGFloat(num)) }
        if let num = Double(s) { return .px(CGFloat(num)) }
        return nil
    }
}

// MARK: - Template String Resolution (SPEC-089d §6.6)

/// Resolves `{{variable}}` template strings in text.
func resolveTemplateString(
    _ text: String,
    hookData: [String: Any]?,
    responses: [String: Any],
    sessionData: [String: Any]? = nil,
    userTraits: [String: Any]? = nil
) -> String {
    var result = text
    let pattern = "\\{\\{\\s*([a-zA-Z0-9_.]+)\\s*\\}\\}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let nsRange = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: nsRange)

    // Iterate in reverse to preserve ranges
    for match in matches.reversed() {
        guard let fullRange = Range(match.range, in: result),
              let pathRange = Range(match.range(at: 1), in: result) else { continue }
        let path = String(result[pathRange])
        let resolved = resolveDotPath(path, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData)
        if let resolved = resolved {
            result.replaceSubrange(fullRange, with: "\(resolved)")
        }
    }
    return result
}

// MARK: - 2D Positioning Modifier (SPEC-089d §6.2)

/// Applies vertical/horizontal alignment + offset positioning to a content block.
struct BlockPositionModifier: ViewModifier {
    let verticalAlign: String?
    let horizontalAlign: String?
    let verticalOffset: Double?
    let horizontalOffset: Double?
    /// When true, vertical_align is handled by ThreeZoneStepLayout (zone partitioning).
    /// The modifier only applies horizontal alignment and pixel offsets.
    var isZoneManaged: Bool = false

    func body(content: Content) -> some View {
        let hasPositioning = verticalAlign != nil || horizontalAlign != nil
            || verticalOffset != nil || horizontalOffset != nil

        if hasPositioning {
            let yOffset = CGFloat(verticalOffset ?? 0)
            // Positive vertical_offset participates in layout (top padding) so
            // scrollable zones can still scroll the full content. Negative
            // offsets stay as `.offset` since there's no negative padding —
            // users rely on negative offsets to pull elements upward without
            // reserving space.
            let topPadding = max(yOffset, 0)
            let residualYOffset = yOffset < 0 ? yOffset : 0
            content
                .frame(
                    maxWidth: .infinity,
                    alignment: mapAlignment(
                        horizontal: horizontalAlign,
                        vertical: isZoneManaged ? nil : verticalAlign
                    )
                )
                .padding(.top, topPadding)
                .offset(
                    x: CGFloat(horizontalOffset ?? 0),
                    y: residualYOffset
                )
        } else {
            content
        }
    }

    private func mapAlignment(horizontal: String?, vertical: String?) -> Alignment {
        let h: HorizontalAlignment = {
            switch horizontal {
            case "left": return .leading
            case "right": return .trailing
            default: return .center
            }
        }()
        let v: VerticalAlignment = {
            switch vertical {
            case "top": return .top
            case "bottom": return .bottom
            default: return .center
            }
        }()
        return Alignment(horizontal: h, vertical: v)
    }
}

extension View {
    /// Apply 2D positioning (SPEC-089d §6.2).
    func applyBlockPosition(
        verticalAlign: String?,
        horizontalAlign: String?,
        verticalOffset: Double?,
        horizontalOffset: Double?,
        isZoneManaged: Bool = false
    ) -> some View {
        modifier(BlockPositionModifier(
            verticalAlign: verticalAlign,
            horizontalAlign: horizontalAlign,
            verticalOffset: verticalOffset,
            horizontalOffset: horizontalOffset,
            isZoneManaged: isZoneManaged
        ))
    }
}

// MARK: - Entrance Animation Wrapper (SPEC-089d §6.4)

/// Wraps a content block with entrance animation.
struct EntranceAnimationWrapper<Content: View>: View {
    let animation: EntranceAnimation
    let content: () -> Content

    @State private var isVisible = false

    var body: some View {
        content()
            .opacity(animationType.usesOpacity ? (isVisible ? 1 : 0) : 1)
            .offset(x: offsetX, y: offsetY)
            .scaleEffect(scaleValue)
            .rotation3DEffect(
                .degrees(animationType == .flip ? (isVisible ? 0 : 90) : 0),
                axis: (x: 1, y: 0, z: 0)
            )
            .onAppear {
                let delaySeconds = Double(animation.delay_ms ?? 0) / 1000.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
                    withAnimation(swiftUIAnimation) {
                        isVisible = true
                    }
                }
            }
    }

    private enum AnimType: Equatable {
        case none, fadeIn, slideUp, slideDown, slideLeft, slideRight
        case scaleUp, scaleDown, bounce, flip

        var usesOpacity: Bool {
            switch self {
            case .fadeIn, .scaleUp, .scaleDown, .bounce, .flip: return true
            default: return false
            }
        }
    }

    private var animationType: AnimType {
        switch animation.type {
        case "fade_in": return .fadeIn
        case "slide_up": return .slideUp
        case "slide_down": return .slideDown
        case "slide_left": return .slideLeft
        case "slide_right": return .slideRight
        case "scale_up": return .scaleUp
        case "scale_down": return .scaleDown
        case "bounce": return .bounce
        case "flip": return .flip
        default: return .none
        }
    }

    private var offsetX: CGFloat {
        switch animationType {
        case .slideLeft: return isVisible ? 0 : -50
        case .slideRight: return isVisible ? 0 : 50
        default: return 0
        }
    }

    private var offsetY: CGFloat {
        switch animationType {
        case .slideUp: return isVisible ? 0 : 50
        case .slideDown: return isVisible ? 0 : -50
        default: return 0
        }
    }

    private var scaleValue: CGFloat {
        switch animationType {
        case .scaleUp: return isVisible ? 1 : 0.5
        case .scaleDown: return isVisible ? 1 : 1.5
        case .bounce: return isVisible ? 1 : 0.3
        default: return 1
        }
    }

    private var swiftUIAnimation: Animation {
        let duration = Double(animation.duration_ms ?? 300) / 1000.0
        switch animation.easing {
        case "spring":
            return .spring(dampingFraction: animation.spring_damping ?? 0.7)
        case "ease_in":
            return .easeIn(duration: duration)
        case "ease_out":
            return .easeOut(duration: duration)
        case "ease_in_out":
            return .easeInOut(duration: duration)
        case "ease":
            return .easeInOut(duration: duration)
        default:
            return .linear(duration: duration)
        }
    }
}

// MARK: - Pressed Style ViewModifier (SPEC-089d §6.5)

/// Applies press/tap state visual feedback to interactive elements.
struct PressedStyleModifier: ViewModifier {
    let pressedStyle: PressedStyle?

    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        if let ps = pressedStyle {
            content
                .scaleEffect(isPressed ? CGFloat(ps.scale ?? 0.97) : 1.0)
                .opacity(isPressed ? (ps.opacity ?? 0.9) : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isPressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isPressed) { _, state, _ in
                            state = true
                        }
                )
        } else {
            content
        }
    }
}

extension View {
    /// Apply press/tap state styling (SPEC-089d §6.5).
    func applyPressedStyle(_ style: PressedStyle?) -> some View {
        modifier(PressedStyleModifier(pressedStyle: style))
    }
}

// MARK: - Relative Sizing ViewModifier (SPEC-089d §6.7)

/// Applies relative sizing (element_width, element_height) to a content block.
struct RelativeSizingModifier: ViewModifier {
    let width: String?
    let height: String?
    var useMinHeight: Bool = false

    func body(content: Content) -> some View {
        content
            .modifier(WidthModifier(size: SizeValue.parse(width)))
            .modifier(HeightModifier(size: SizeValue.parse(height), useMin: useMinHeight))
    }

    struct WidthModifier: ViewModifier {
        let size: SizeValue?
        func body(content: Content) -> some View {
            switch size {
            case .fill:
                content.frame(maxWidth: .infinity)
            case .px(let val):
                content.frame(width: val)
            case .percent(let fraction):
                if fraction >= 1.0 {
                    // 100% = fill available space (respect parent padding)
                    content.frame(maxWidth: .infinity)
                } else {
                    // <100% = fraction of parent width (approximate using screen width minus global padding)
                    let availableWidth = UIScreen.main.bounds.width - (max(24, UIScreen.main.bounds.width * 0.08) * 2)
                    content.frame(width: availableWidth * fraction)
                }
            case .auto_, .none:
                content
            }
        }
    }

    struct HeightModifier: ViewModifier {
        let size: SizeValue?
        var useMin: Bool = false
        func body(content: Content) -> some View {
            switch size {
            case .fill:
                content.frame(maxHeight: .infinity)
            case .px(let val):
                if useMin {
                    content.frame(minHeight: val)
                } else {
                    content.frame(height: val)
                }
            case .percent(let fraction):
                if fraction >= 1.0 {
                    content.frame(maxHeight: .infinity)
                } else {
                    let h = UIScreen.main.bounds.height * fraction
                    if useMin {
                        content.frame(minHeight: h)
                    } else {
                        content.frame(height: h)
                    }
                }
            case .auto_, .none:
                content
            }
        }
    }
}

extension View {
    /// Apply relative sizing (SPEC-089d §6.7).
    func applyRelativeSizing(width: String?, height: String?, useMinHeight: Bool = false) -> some View {
        modifier(RelativeSizingModifier(width: width, height: height, useMinHeight: useMinHeight))
    }

    /// Universal container styling for ANY content block: background opacity, blur,
    /// border, and corner radius. Reads from field_config so all block types
    /// (input, select, row, image, text, etc.) can be made transparent/blurred.
    @ViewBuilder
    func applyBlockContainerStyle(_ block: ContentBlock) -> some View {
        let cfg = block.field_config
        // Completely opt-in: only apply when blur is on OR container_bg_color
        // is explicitly set to a visible value. Prevents phantom backgrounds
        // from stale/default color picker values.
        let useBlur = (cfg?["blur_background"]?.value as? Bool) == true
        let containerBg = cfg?["container_bg_color"]?.value as? String
        let hasBg = containerBg != nil && containerBg != "" && containerBg != "#ffffff" && containerBg != "#FFFFFF" && containerBg != "transparent"
        let containerBorderW = (cfgDouble(cfg?["container_border_width"])).flatMap { $0 > 0 ? CGFloat($0) : nil }
        let hasBorder = containerBorderW != nil && (cfg?["container_border_color"]?.value as? String) != nil
        // `container_opacity` (whole wrapper) takes priority; falls back to
        // `background_opacity` for backward compat where that key was the only
        // opacity control exposed.
        let bgOpacity = CGFloat((cfgDouble(cfg?["container_opacity"])) ?? (cfgDouble(cfg?["background_opacity"])) ?? 1.0)
        let containerCornerR = CGFloat((cfgDouble(cfg?["container_corner_radius"])) ?? 0)

        if useBlur || hasBg || hasBorder {
            self
                .background {
                    ZStack {
                        if useBlur {
                            RoundedRectangle(cornerRadius: containerCornerR).fill(.ultraThinMaterial)
                        }
                        if hasBg, let bg = containerBg {
                            RoundedRectangle(cornerRadius: containerCornerR)
                                .fill(Color(hex: bg).opacity(bgOpacity))
                        }
                        if let bw = containerBorderW, let bc = cfg?["container_border_color"]?.value as? String, !bc.isEmpty {
                            RoundedRectangle(cornerRadius: containerCornerR)
                                .strokeBorder(Color(hex: bc), lineWidth: bw)
                        }
                    }
                }
                .cornerRadius(containerCornerR)
        } else {
            self
        }
    }
}

// MARK: - Nested Codable types for SPEC-089d block fields

/// A single timeline item for the `timeline` block.
public struct TimelineItemConfig: Codable, Identifiable {
    public let id: String?
    public let title: String?
    public let subtitle: String?
    public let icon: String?
    public let status: String?  // completed | current | upcoming
}

/// A social login provider entry for the `social_login` block.
public struct SocialProviderConfig: Codable {
    public let type: String?    // apple, google, email, facebook, github
    public let label: String?
    public let enabled: Bool?
    public let icon_style: String?  // "default", "monochrome_light", "monochrome_dark", "filled", "outline"
    // Per-button style overrides — nil → fall back to provider-type defaults
    // (Apple=black, Google=#4285F4, email=#6366F1, etc.). SPEC-089e amendment.
    public let bg_color: String?
    public let text_color: String?
    public let border_color: String?
    public let border_width: Double?
    public let corner_radius: Double?
    // Social-Login styling v2 — per-provider custom icon override. When set to a
    // non-empty URL the SDK renders the remote image instead of the built-in
    // provider glyph. nil → keep the brand glyph.
    public let icon_url: String?
}

/// A single item for the `animated_loading` checklist OR for the
/// `orbiting_icons` variant (each item = one icon orbiting the center).
public struct LoadingItemConfig: Codable {
    public let label: String?
    public let duration_ms: Int?
    public let icon: String?
    // Orbiting-icons variant fields
    public let icon_url: String?
    public let icon_bg_color: String?
    public let icon_size: Double?         // diameter in pt; default 48
    public let icon_orbit_angle: Double?  // 0-360; nil = auto-distribute
}

/// Countdown label overrides.
public struct CountdownLabelsConfig: Codable {
    public let days: String?
    public let hours: String?
    public let minutes: String?
    public let seconds: String?
}

/// A pricing plan entry for the `pricing_card` block.
public struct PricingPlanConfig: Codable, Identifiable {
    public let id: String?
    public let label: String?
    public let price: String?
    public let period: String?
    public let badge: String?
    public let is_highlighted: Bool?
}

/// A date wheel picker column for the `date_wheel_picker` block.
public struct DateWheelColumnConfig: Codable {
    public let type: String?   // day | month | year | custom
    public let label: String?
    public let values: [String]?
}

/// Star/particle background config for `star_background` block.
public struct StarParticle {
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var opacity: Double
    var speed: CGFloat
}

// MARK: - Content Block model

public struct ContentBlock: Codable, Identifiable {
    public let id: String
    public let type: ContentBlockType
    // Common
    public let text: String?
    public let style: TextStyleConfig?
    // Heading
    public let level: Int?
    // Image / Video
    public let image_url: String?
    public let alt: String?
    public let corner_radius: Double?
    public let height: Double?
    public let image_fit: String?  // "contain" | "fill" | "cover" — default fill
    // EPIC-3 — wrap the image in a device frame: "phone" = bezel + dynamic-island notch.
    public let image_frame: String?
    // Button
    public let variant: String?
    public let action: String?     // next, skip, link, permission
    public let action_value: String?  // URL for link, permission type for permission
    public let bg_color: String?
    public let text_color: String?
    public let button_corner_radius: Double?
    // Spacer
    public let spacer_height: Double?
    // List
    public let items: [String]?
    public let list_style: String?   // bullet, numbered, check
    // Divider
    public let divider_color: String?
    public let divider_thickness: Double?
    public let divider_margin_y: Double?
    // Badge — used by pulsing_avatar (and any future block with a badge overlay).
    public let badge_text: String?
    public let badge_bg_color: String?
    public let badge_text_color: String?
    public let badge_corner_radius: Double?
    public let badge_position: String?  // "top_trailing" (default) | "top_leading" | "bottom_trailing" | "bottom_leading"
    public let badge_size: Double?      // Scale factor (default 1.0 — native caption2 + 6/2 padding)
    // Pulsing avatar — image shape override (legacy default = circle).
    public let image_shape: String?           // "circle" (default) | "square" | "rounded"
    public let image_corner_radius: Double?   // Used when image_shape == "rounded" (default 16)
    // Icon
    public let icon_emoji: String?
    public let icon_size: Double?
    public let icon_alignment: String?
    // Toggle
    public let toggle_label: String?
    public let toggle_description: String?
    public let toggle_default: Bool?
    // Video
    public let video_url: String?
    public let video_thumbnail_url: String?
    public let video_height: Double?
    public let video_corner_radius: Double?
    // SPEC-085: Video playback options
    public let autoplay: Bool?
    public let loop: Bool?
    public let muted: Bool?
    public let controls: Bool?
    // SPEC-419 pass-14 — `video_*`-prefixed fallbacks. The console editor +
    // preview + Android all write the prefixed keys (video_autoplay/_loop/
    // _muted/_controls); iOS previously only decoded the unprefixed
    // autoplay/loop/muted/controls, so authored prefixed payloads were
    // silently ignored. Decode both; the renderer falls back unprefixed → prefixed.
    public let video_autoplay: Bool?
    public let video_loop: Bool?
    public let video_muted: Bool?
    public let video_controls: Bool?
    // SPEC-085: Lottie
    public let lottie_url: String?
    public let lottie_speed: Double?
    public let lottie_width: Double?
    public let lottie_height: Double?
    public let play_on_scroll: Bool?
    public let play_on_tap: Bool?
    // SPEC-085: Rive
    public let rive_url: String?
    public let artboard: String?
    public let state_machine: String?
    public let trigger_on_step_complete: String?
    // SPEC-085: Icon reference (structured icon)
    public let icon_ref: IconReference?

    // SPEC-089d §6.1: Per-block style design tokens
    public let block_style: BlockStyle?

    // Zone-based positioning
    public let zone: String?              // "top", "center", "bottom" — explicit zone
    public let vertical_align: String?    // Legacy, used as fallback when zone is nil
    public let horizontal_align: String?
    public let vertical_offset: Double?
    public let horizontal_offset: Double?

    // SPEC-089d Phase A: page_indicator fields
    public let dot_count: Int?
    public let active_index: Int?
    public let active_color: String?
    public let inactive_color: String?
    public let dot_size: Double?
    public let dot_spacing: Double?
    public let active_dot_width: Double?
    public let alignment: String?

    // SPEC-089d Phase A: social_login fields
    public let providers: [SocialProviderConfig]?
    public let button_style: String?       // filled, outlined, minimal
    public let button_height: Double?
    public let spacing: Double?
    public let show_divider: Bool?
    public let divider_text: String?
    // Social-Login styling v2 — divider placement ("top" | "bottom", default
    // "bottom") and in-button text alignment ("leading" | "center", default
    // "center"). divider_color (declared above with the divider block) tints the
    // "or" separator rules.
    public let divider_position: String?
    public let button_text_align: String?
    // SPEC-089e amendment — email CTA placement + spacer
    public let email_login_placement: String?   // "with_providers" | "below_inputs"
    public let email_cta_spacing_below: Double? // px spacer after email button

    // SPEC-089d Phase A: countdown_timer fields
    public let timer_variant: String?      // digital, circular, flip, bar
    public let duration_seconds: Int?
    public let show_days: Bool?
    public let show_hours: Bool?
    public let show_minutes: Bool?
    public let show_seconds: Bool?
    public let labels: CountdownLabelsConfig?
    public let on_expire_action: String?   // hide, show_expired_text, auto_advance
    public let expired_text: String?
    public let accent_color: String?
    public let font_size: Double?

    // SPEC-089d Phase A: rating fields
    public let max_stars: Int?
    public let default_rating: Double?
    public let star_size: Double?
    public let filled_color: String?
    public let empty_color: String?
    public let allow_half: Bool?
    public let field_id: String?
    public let rating_label: String?

    // SPEC-089d Phase A: rich_text fields
    public let markdown_content: String?
    public let rich_text_variant: String?  // default, legal
    public let base_style: TextStyleConfig?
    public let link_color: String?

    // SPEC-089d Phase A: progress_bar fields
    public let progress_variant: String?   // continuous, segmented
    public let progress_value: Double?
    public let total_segments: Int?
    public let filled_segments: Int?
    public let bar_height: Double?
    public let bar_color: String?
    // EPIC-2 — multiple progress colors at once (horizontal gradient across the fill).
    public let bar_gradient_colors: [String]?
    public let track_color: String?
    public let show_label: Bool?
    public let segment_gap: Double?
    // SPEC-419 gap#6 — progress_bar label formatting. `label_format`:
    // "percentage" | "fraction" | "custom"; `custom_label` supplies the text
    // when format == "custom". Authored top-level by the console editor.
    public let label_format: String?
    public let custom_label: String?
    // Progress/Loading v2 — placement of the progress label relative to the bar:
    // "above" (default) | "below" | "left" | "right".
    public let label_placement: String?

    // SPEC-089d Phase A: timeline fields
    public let timeline_items: [TimelineItemConfig]?
    public let line_color: String?
    public let completed_color: String?
    public let current_color: String?
    public let upcoming_color: String?
    public let show_line: Bool?
    public let compact: Bool?
    public let title_style: TextStyleConfig?
    public let subtitle_style: TextStyleConfig?

    // SPEC-089d Phase A: animated_loading fields
    public let loading_variant: String?    // circular, linear, checklist
    // EPIC-3 — configurable loading message + independent position (above/below), size, color.
    public let loading_text: String?
    public let loading_text_position: String?  // "above" | "below" (default "below")
    public let loading_text_size: Double?
    public let loading_text_color: String?
    // Progress/Loading v2 — horizontal alignment of the loading message:
    // "left" | "center" (default) | "right".
    public let loading_text_align: String?
    // EPIC-3 — media_gallery: horizontal row of image tiles.
    public let gallery_images: [String]?
    public let gallery_item_width: Double?
    public let gallery_item_height: Double?
    public let gallery_corner_radius: Double?
    public let gallery_spacing: Double?
    public let gallery_align: String?  // "start" | "center" | "end" (default "center")
    public let loading_items: [LoadingItemConfig]?
    public let progress_color: String?
    public let check_color: String?
    public let total_duration_ms: Int?
    public let auto_advance: Bool?
    public let show_percentage: Bool?

    // SPEC-089d Phase F: circular_gauge fields
    public let gauge_variant: String?    // "arc" (default), "speedometer", "radial", "linear"
    public let gauge_value: Double?
    public let max_value: Double?
    public let sublabel: String?
    public let stroke_width: Double?
    public let label_color: String?
    public let label_font_size: Double?
    public let min_label: String?
    public let max_label: String?
    public let min_max_font_size: Double?
    public let min_max_color: String?
    public let animate: Bool?
    public let animation_duration_ms: Int?
    // Arrow/needle styling (console uses these names)
    public let arrow_color: String?
    public let arrow_stroke_width: Double?
    // Percentage location: "center" (default), "below", "above", "none"
    public let percentage_location: String?

    // SPEC-089d Phase F: date_wheel_picker fields
    public let columns: [DateWheelColumnConfig]?
    public let default_date_value: String?
    public let min_date: String?
    public let max_date: String?
    public let allow_future: Bool?
    public let allow_past: Bool?
    public let date_validation_message: String?
    public let highlight_color: String?
    public let haptic_on_scroll: Bool?
    public let orientation: String?              // "vertical" | "horizontal" for wheel picker
    public let wheel_orientation: String?        // console saves this instead of orientation
    public let picker_presentation: String?      // "inline" | "field" for date picker
    public let picker_mode: String?              // "date" | "datetime" | "time" for date picker
    public let picker_spacing: Double?           // spacing between time wheel and date graphical in datetime mode
    public let calendar_bg_color: String?        // explicit background color for graphical date picker
    public let wheel_bg_color: String?           // explicit background color for wheel date picker (top-level, not field_config)
    public let wheel_height: Double?             // wheel picker height in pt (top-level)
    // SPEC-419 — console writes the picker divider/border line color + stroke at top level
    // (wheel_line_color / wheel_line_stroke_width). iOS previously read only field_config
    // picker_border_color/width, so authored line styling never appeared.
    public let wheel_line_color: String?
    public let wheel_line_stroke_width: Double?

    // SPEC-089d Phase F: stack / row fields (container blocks)
    public let children: [ContentBlock]?
    public let stack_children: [ContentBlock]?  // Console uses this key; SDK prefers children
    public let z_index: Double?
    public let gap: Double?
    public let wrap: Bool?
    public let justify: String?
    public let align_items: String?
    // Row layout direction and distribution
    public let row_direction: String?       // horizontal (default), vertical
    public let row_distribution: String?    // fill, start, center, end, space_between, space_around
    public let row_child_fill: Bool?        // true (default) — each child gets maxWidth: .infinity
    public let column_ratios: String?       // "1:2", "1:1:2" — proportional widths for horizontal layout

    // SPEC-089d Phase F: custom_view fields
    public let view_key: String?
    public let custom_config: [String: AnyCodable]?
    public let placeholder_image_url: String?
    public let placeholder_text: String?

    // SPEC-089d Phase F: star_background fields
    public let particle_type: String?      // stars, sparkles, dots, snow, bokeh
    public let density: String?            // sparse, medium, dense
    public let speed: String?              // slow, medium, fast
    public let secondary_color: String?
    public let size_range: [Double]?
    public let fullscreen: Bool?
    // SPEC-419 pass-15 #8/#9/#25 — editor authors these top-level for star_background.
    public let particle_color: String?
    public let particle_opacity: Double?
    public let particle_speed: String?     // slow, medium, fast (editor key; falls back to `speed`)

    // SPEC-089d Phase F: wheel_picker fields
    public let min_value: Double?
    public let max_value_picker: Double?
    public let step_value: Double?
    public let default_picker_value: Double?
    // SPEC-419 — the console editor writes top-level `default_value` (number) for wheel_picker;
    // read it as a fallback for default_picker_value so authored defaults aren't lost on-device.
    public let default_value: Double?
    public let unit: String?
    public let unit_position: String?
    public let visible_items: Int?

    // SPEC-089d Phase F: pulsing_avatar fields
    public let pulse_color: String?
    public let pulse_ring_count: Int?
    public let pulse_speed: Double?
    public let border_width: Double?
    public let border_color: String?

    // SPEC-089d Nurrai: pricing_card fields
    public let pricing_plans: [PricingPlanConfig]?
    public let pricing_layout: String?     // stack, side_by_side

    // SPEC-089d Phase 3: Form input common fields
    public let field_label: String?
    public let field_placeholder: String?
    public let field_required: Bool?
    public let field_style: FormFieldBlockStyle?
    public let field_options: [InputOption]?
    public let multi_select: Bool?
    // Form input specific config
    public let field_config: [String: AnyCodable]?

    // SPEC-089d §6.3: Visibility condition
    public let visibility_condition: VisibilityCondition?

    // SPEC-089d §6.4: Entrance animation
    public let entrance_animation: EntranceAnimation?

    // SPEC-089d §6.5: Press/tap state
    public let pressed_style: PressedStyle?

    // SPEC-089d §6.6: Dynamic bindings
    public let bindings: [String: String]?

    // SPEC-089d §6.7: Relative sizing
    public let element_width: String?
    public let element_height: String?

    // Overflow control: "visible" disables clipping (e.g. for images that bleed out of rows)
    public let overflow: String?
    // Sprint 7: Scroll-collapse — block fades out and shrinks to 0 height when scrolled
    public let collapse_on_scroll: Bool?
    // SPEC-419 pass-15 #23 — max line count for text/rich_text truncation (parity with Android `max_lines`)
    public let max_lines: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, text, style, level
        case image_url, alt, corner_radius, height, image_fit, image_frame
        case variant, action, action_value, bg_color, text_color, button_corner_radius
        case spacer_height, items, list_style
        case divider_color, divider_thickness, divider_margin_y
        case badge_text, badge_bg_color, badge_text_color, badge_corner_radius
        case badge_position, badge_size
        case image_shape, image_corner_radius
        case icon_emoji, icon_size, icon_alignment
        case toggle_label, toggle_description, toggle_default
        case video_url, video_thumbnail_url, video_height, video_corner_radius
        case autoplay, loop, muted, controls
        case video_autoplay, video_loop, video_muted, video_controls
        case lottie_url, lottie_speed, lottie_width, lottie_height
        case play_on_scroll, play_on_tap
        case rive_url, artboard, state_machine, trigger_on_step_complete
        case icon_ref
        case block_style
        case zone, vertical_align, horizontal_align, vertical_offset, horizontal_offset
        // SPEC-089d Phase A: new block fields
        case dot_count, active_index, active_color, inactive_color
        case dot_size, dot_spacing, active_dot_width, alignment
        case providers, button_style, button_height, spacing
        case show_divider, divider_text
        // Social-Login styling v2
        case divider_position, button_text_align
        // SPEC-089e amendment — email button placement + spacer
        case email_login_placement, email_cta_spacing_below
        case timer_variant, duration_seconds
        case show_days, show_hours, show_minutes, show_seconds
        case labels, on_expire_action, expired_text, accent_color, font_size
        case max_stars, default_rating, star_size, filled_color, empty_color
        case allow_half, field_id, rating_label
        case markdown_content, rich_text_variant, base_style, link_color
        case progress_variant, progress_value, total_segments, filled_segments
        case bar_height, bar_color, bar_gradient_colors, track_color, show_label, segment_gap
        case label_format, custom_label, label_placement
        case timeline_items, line_color, completed_color, current_color
        case upcoming_color, show_line, compact, title_style, subtitle_style
        case loading_variant, loading_text, loading_text_position, loading_text_size, loading_text_color, loading_text_align, loading_items, progress_color, check_color
        case gallery_images, gallery_item_width, gallery_item_height, gallery_corner_radius, gallery_spacing, gallery_align
        case total_duration_ms, auto_advance, show_percentage
        // SPEC-089d Phase F: new block fields
        case gauge_variant, gauge_value, max_value, sublabel, stroke_width, min_label, max_label, min_max_font_size
        case min_max_color, arrow_color, arrow_stroke_width, percentage_location
        case label_color, label_font_size, animate, animation_duration_ms
        case columns, default_date_value, min_date, max_date, allow_future, allow_past, date_validation_message
        case highlight_color, haptic_on_scroll, orientation, wheel_orientation, picker_presentation, picker_mode
        case picker_spacing, calendar_bg_color, wheel_bg_color, wheel_height
        case wheel_line_color, wheel_line_stroke_width
        case children, stack_children, z_index, gap, wrap, justify, align_items
        case row_direction, row_distribution, row_child_fill, column_ratios
        case view_key, custom_config, placeholder_image_url, placeholder_text
        case particle_type, density, speed, secondary_color, size_range, fullscreen
        case particle_color, particle_opacity, particle_speed
        case min_value, max_value_picker, step_value, default_picker_value, default_value
        case unit, unit_position, visible_items
        case pulse_color, pulse_ring_count, pulse_speed, border_width, border_color
        case pricing_plans, pricing_layout
        // SPEC-089d Phase 3: form input + advanced styling fields
        case field_label, field_placeholder, field_required, field_style, field_options, multi_select, field_config
        case visibility_condition, entrance_animation, pressed_style, bindings
        case element_width, element_height
        case overflow, collapse_on_scroll, max_lines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Core fields — provide safe defaults so missing data doesn't crash
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.type = try c.decodeIfPresent(ContentBlockType.self, forKey: .type) ?? .unknown
        // All remaining fields are optional — decode normally
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .style)
        self.level = try c.decodeIfPresent(Int.self, forKey: .level)
        self.image_url = try c.decodeIfPresent(String.self, forKey: .image_url)
        self.alt = try c.decodeIfPresent(String.self, forKey: .alt)
        self.corner_radius = try c.decodeIfPresent(Double.self, forKey: .corner_radius)
        self.height = try c.decodeIfPresent(Double.self, forKey: .height)
        self.image_fit = try c.decodeIfPresent(String.self, forKey: .image_fit)
        self.image_frame = try c.decodeIfPresent(String.self, forKey: .image_frame)
        self.variant = try c.decodeIfPresent(String.self, forKey: .variant)
        self.action = try c.decodeIfPresent(String.self, forKey: .action)
        self.action_value = try c.decodeIfPresent(String.self, forKey: .action_value)
        self.bg_color = try c.decodeIfPresent(String.self, forKey: .bg_color)
        self.text_color = try c.decodeIfPresent(String.self, forKey: .text_color)
        self.button_corner_radius = try c.decodeIfPresent(Double.self, forKey: .button_corner_radius)
        self.spacer_height = try c.decodeIfPresent(Double.self, forKey: .spacer_height)
        self.items = try c.decodeIfPresent([String].self, forKey: .items)
        self.list_style = try c.decodeIfPresent(String.self, forKey: .list_style)
        self.divider_color = try c.decodeIfPresent(String.self, forKey: .divider_color)
        self.divider_thickness = try c.decodeIfPresent(Double.self, forKey: .divider_thickness)
        self.divider_margin_y = try c.decodeIfPresent(Double.self, forKey: .divider_margin_y)
        self.badge_text = try c.decodeIfPresent(String.self, forKey: .badge_text)
        self.badge_bg_color = try c.decodeIfPresent(String.self, forKey: .badge_bg_color)
        self.badge_text_color = try c.decodeIfPresent(String.self, forKey: .badge_text_color)
        self.badge_corner_radius = try c.decodeIfPresent(Double.self, forKey: .badge_corner_radius)
        self.badge_position = try c.decodeIfPresent(String.self, forKey: .badge_position)
        self.badge_size = try c.decodeIfPresent(Double.self, forKey: .badge_size)
        self.image_shape = try c.decodeIfPresent(String.self, forKey: .image_shape)
        self.image_corner_radius = try c.decodeIfPresent(Double.self, forKey: .image_corner_radius)
        self.icon_emoji = try c.decodeIfPresent(String.self, forKey: .icon_emoji)
        self.icon_size = try c.decodeIfPresent(Double.self, forKey: .icon_size)
        self.icon_alignment = try c.decodeIfPresent(String.self, forKey: .icon_alignment)
        self.toggle_label = try c.decodeIfPresent(String.self, forKey: .toggle_label)
        self.toggle_description = try c.decodeIfPresent(String.self, forKey: .toggle_description)
        self.toggle_default = try c.decodeIfPresent(Bool.self, forKey: .toggle_default)
        self.video_url = try c.decodeIfPresent(String.self, forKey: .video_url)
        self.video_thumbnail_url = try c.decodeIfPresent(String.self, forKey: .video_thumbnail_url)
        self.video_height = try c.decodeIfPresent(Double.self, forKey: .video_height)
        self.video_corner_radius = try c.decodeIfPresent(Double.self, forKey: .video_corner_radius)
        self.autoplay = try c.decodeIfPresent(Bool.self, forKey: .autoplay)
        self.loop = try c.decodeIfPresent(Bool.self, forKey: .loop)
        self.muted = try c.decodeIfPresent(Bool.self, forKey: .muted)
        self.controls = try c.decodeIfPresent(Bool.self, forKey: .controls)
        self.video_autoplay = try c.decodeIfPresent(Bool.self, forKey: .video_autoplay)
        self.video_loop = try c.decodeIfPresent(Bool.self, forKey: .video_loop)
        self.video_muted = try c.decodeIfPresent(Bool.self, forKey: .video_muted)
        self.video_controls = try c.decodeIfPresent(Bool.self, forKey: .video_controls)
        self.lottie_url = try c.decodeIfPresent(String.self, forKey: .lottie_url)
        self.lottie_speed = try c.decodeIfPresent(Double.self, forKey: .lottie_speed)
        self.lottie_width = try c.decodeIfPresent(Double.self, forKey: .lottie_width)
        self.lottie_height = try c.decodeIfPresent(Double.self, forKey: .lottie_height)
        self.play_on_scroll = try c.decodeIfPresent(Bool.self, forKey: .play_on_scroll)
        self.play_on_tap = try c.decodeIfPresent(Bool.self, forKey: .play_on_tap)
        self.rive_url = try c.decodeIfPresent(String.self, forKey: .rive_url)
        self.artboard = try c.decodeIfPresent(String.self, forKey: .artboard)
        self.state_machine = try c.decodeIfPresent(String.self, forKey: .state_machine)
        self.trigger_on_step_complete = try c.decodeIfPresent(String.self, forKey: .trigger_on_step_complete)
        self.icon_ref = try c.decodeIfPresent(IconReference.self, forKey: .icon_ref)
        self.block_style = try c.decodeIfPresent(BlockStyle.self, forKey: .block_style)
        self.zone = try c.decodeIfPresent(String.self, forKey: .zone)
        self.vertical_align = try c.decodeIfPresent(String.self, forKey: .vertical_align)
        self.horizontal_align = try c.decodeIfPresent(String.self, forKey: .horizontal_align)
        self.vertical_offset = try c.decodeIfPresent(Double.self, forKey: .vertical_offset)
        self.horizontal_offset = try c.decodeIfPresent(Double.self, forKey: .horizontal_offset)
        self.dot_count = try c.decodeIfPresent(Int.self, forKey: .dot_count)
        self.active_index = try c.decodeIfPresent(Int.self, forKey: .active_index)
        self.active_color = try c.decodeIfPresent(String.self, forKey: .active_color)
        self.inactive_color = try c.decodeIfPresent(String.self, forKey: .inactive_color)
        self.dot_size = try c.decodeIfPresent(Double.self, forKey: .dot_size)
        self.dot_spacing = try c.decodeIfPresent(Double.self, forKey: .dot_spacing)
        self.active_dot_width = try c.decodeIfPresent(Double.self, forKey: .active_dot_width)
        self.alignment = try c.decodeIfPresent(String.self, forKey: .alignment)
        self.providers = try c.decodeIfPresent([SocialProviderConfig].self, forKey: .providers)
        self.button_style = try c.decodeIfPresent(String.self, forKey: .button_style)
        self.button_height = try c.decodeIfPresent(Double.self, forKey: .button_height)
        self.spacing = try c.decodeIfPresent(Double.self, forKey: .spacing)
        self.show_divider = try c.decodeIfPresent(Bool.self, forKey: .show_divider)
        self.divider_text = try c.decodeIfPresent(String.self, forKey: .divider_text)
        self.divider_position = try c.decodeIfPresent(String.self, forKey: .divider_position)
        self.button_text_align = try c.decodeIfPresent(String.self, forKey: .button_text_align)
        self.email_login_placement = try c.decodeIfPresent(String.self, forKey: .email_login_placement)
        self.email_cta_spacing_below = try c.decodeIfPresent(Double.self, forKey: .email_cta_spacing_below)
        self.timer_variant = try c.decodeIfPresent(String.self, forKey: .timer_variant)
        self.duration_seconds = try c.decodeIfPresent(Int.self, forKey: .duration_seconds)
        self.show_days = try c.decodeIfPresent(Bool.self, forKey: .show_days)
        self.show_hours = try c.decodeIfPresent(Bool.self, forKey: .show_hours)
        self.show_minutes = try c.decodeIfPresent(Bool.self, forKey: .show_minutes)
        self.show_seconds = try c.decodeIfPresent(Bool.self, forKey: .show_seconds)
        self.labels = try c.decodeIfPresent(CountdownLabelsConfig.self, forKey: .labels)
        self.on_expire_action = try c.decodeIfPresent(String.self, forKey: .on_expire_action)
        self.expired_text = try c.decodeIfPresent(String.self, forKey: .expired_text)
        self.accent_color = try c.decodeIfPresent(String.self, forKey: .accent_color)
        self.font_size = try c.decodeIfPresent(Double.self, forKey: .font_size)
        self.max_stars = try c.decodeIfPresent(Int.self, forKey: .max_stars)
        self.default_rating = try c.decodeIfPresent(Double.self, forKey: .default_rating)
        self.star_size = try c.decodeIfPresent(Double.self, forKey: .star_size)
        self.filled_color = try c.decodeIfPresent(String.self, forKey: .filled_color)
        self.empty_color = try c.decodeIfPresent(String.self, forKey: .empty_color)
        self.allow_half = try c.decodeIfPresent(Bool.self, forKey: .allow_half)
        self.field_id = try c.decodeIfPresent(String.self, forKey: .field_id)
        self.rating_label = try c.decodeIfPresent(String.self, forKey: .rating_label)
        self.markdown_content = try c.decodeIfPresent(String.self, forKey: .markdown_content)
        self.rich_text_variant = try c.decodeIfPresent(String.self, forKey: .rich_text_variant)
        self.base_style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .base_style)
        self.link_color = try c.decodeIfPresent(String.self, forKey: .link_color)
        self.progress_variant = try c.decodeIfPresent(String.self, forKey: .progress_variant)
        self.progress_value = try c.decodeIfPresent(Double.self, forKey: .progress_value)
        self.total_segments = try c.decodeIfPresent(Int.self, forKey: .total_segments)
        self.filled_segments = try c.decodeIfPresent(Int.self, forKey: .filled_segments)
        self.bar_height = try c.decodeIfPresent(Double.self, forKey: .bar_height)
        self.bar_color = try c.decodeIfPresent(String.self, forKey: .bar_color)
        self.bar_gradient_colors = try c.decodeIfPresent([String].self, forKey: .bar_gradient_colors)
        self.track_color = try c.decodeIfPresent(String.self, forKey: .track_color)
        self.show_label = try c.decodeIfPresent(Bool.self, forKey: .show_label)
        self.segment_gap = try c.decodeIfPresent(Double.self, forKey: .segment_gap)
        self.label_format = try c.decodeIfPresent(String.self, forKey: .label_format)
        self.custom_label = try c.decodeIfPresent(String.self, forKey: .custom_label)
        self.label_placement = try c.decodeIfPresent(String.self, forKey: .label_placement)
        self.timeline_items = try c.decodeIfPresent([TimelineItemConfig].self, forKey: .timeline_items)
        self.line_color = try c.decodeIfPresent(String.self, forKey: .line_color)
        self.completed_color = try c.decodeIfPresent(String.self, forKey: .completed_color)
        self.current_color = try c.decodeIfPresent(String.self, forKey: .current_color)
        self.upcoming_color = try c.decodeIfPresent(String.self, forKey: .upcoming_color)
        self.show_line = try c.decodeIfPresent(Bool.self, forKey: .show_line)
        self.compact = try c.decodeIfPresent(Bool.self, forKey: .compact)
        self.title_style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .title_style)
        self.subtitle_style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .subtitle_style)
        self.loading_variant = try c.decodeIfPresent(String.self, forKey: .loading_variant)
        self.loading_text = try c.decodeIfPresent(String.self, forKey: .loading_text)
        self.loading_text_position = try c.decodeIfPresent(String.self, forKey: .loading_text_position)
        self.loading_text_size = try c.decodeIfPresent(Double.self, forKey: .loading_text_size)
        self.loading_text_color = try c.decodeIfPresent(String.self, forKey: .loading_text_color)
        self.loading_text_align = try c.decodeIfPresent(String.self, forKey: .loading_text_align)
        self.loading_items = try c.decodeIfPresent([LoadingItemConfig].self, forKey: .loading_items)
        self.gallery_images = try c.decodeIfPresent([String].self, forKey: .gallery_images)
        self.gallery_item_width = try c.decodeIfPresent(Double.self, forKey: .gallery_item_width)
        self.gallery_item_height = try c.decodeIfPresent(Double.self, forKey: .gallery_item_height)
        self.gallery_corner_radius = try c.decodeIfPresent(Double.self, forKey: .gallery_corner_radius)
        self.gallery_spacing = try c.decodeIfPresent(Double.self, forKey: .gallery_spacing)
        self.gallery_align = try c.decodeIfPresent(String.self, forKey: .gallery_align)
        self.progress_color = try c.decodeIfPresent(String.self, forKey: .progress_color)
        self.check_color = try c.decodeIfPresent(String.self, forKey: .check_color)
        self.total_duration_ms = try c.decodeIfPresent(Int.self, forKey: .total_duration_ms)
        self.auto_advance = try c.decodeIfPresent(Bool.self, forKey: .auto_advance)
        self.show_percentage = try c.decodeIfPresent(Bool.self, forKey: .show_percentage)
        self.gauge_variant = try c.decodeIfPresent(String.self, forKey: .gauge_variant)
        self.gauge_value = try c.decodeIfPresent(Double.self, forKey: .gauge_value)
        self.max_value = try c.decodeIfPresent(Double.self, forKey: .max_value)
        self.sublabel = try c.decodeIfPresent(String.self, forKey: .sublabel)
        self.stroke_width = try c.decodeIfPresent(Double.self, forKey: .stroke_width)
        self.label_color = try c.decodeIfPresent(String.self, forKey: .label_color)
        self.label_font_size = try c.decodeIfPresent(Double.self, forKey: .label_font_size)
        self.min_label = try c.decodeIfPresent(String.self, forKey: .min_label)
        self.max_label = try c.decodeIfPresent(String.self, forKey: .max_label)
        self.min_max_font_size = try c.decodeIfPresent(Double.self, forKey: .min_max_font_size)
        self.min_max_color = try c.decodeIfPresent(String.self, forKey: .min_max_color)
        self.arrow_color = try c.decodeIfPresent(String.self, forKey: .arrow_color)
        self.arrow_stroke_width = try c.decodeIfPresent(Double.self, forKey: .arrow_stroke_width)
        self.percentage_location = try c.decodeIfPresent(String.self, forKey: .percentage_location)
        self.animate = try c.decodeIfPresent(Bool.self, forKey: .animate)
        self.animation_duration_ms = try c.decodeIfPresent(Int.self, forKey: .animation_duration_ms)
        self.columns = try c.decodeIfPresent([DateWheelColumnConfig].self, forKey: .columns)
        self.default_date_value = try c.decodeIfPresent(String.self, forKey: .default_date_value)
        self.min_date = try c.decodeIfPresent(String.self, forKey: .min_date)
        self.max_date = try c.decodeIfPresent(String.self, forKey: .max_date)
        self.allow_future = try c.decodeIfPresent(Bool.self, forKey: .allow_future)
        self.allow_past = try c.decodeIfPresent(Bool.self, forKey: .allow_past)
        self.date_validation_message = try c.decodeIfPresent(String.self, forKey: .date_validation_message)
        self.highlight_color = try c.decodeIfPresent(String.self, forKey: .highlight_color)
        self.orientation = try c.decodeIfPresent(String.self, forKey: .orientation)
        self.wheel_orientation = try c.decodeIfPresent(String.self, forKey: .wheel_orientation)
        self.picker_presentation = try c.decodeIfPresent(String.self, forKey: .picker_presentation)
        self.picker_mode = try c.decodeIfPresent(String.self, forKey: .picker_mode)
        self.picker_spacing = try c.decodeIfPresent(Double.self, forKey: .picker_spacing)
        self.calendar_bg_color = try c.decodeIfPresent(String.self, forKey: .calendar_bg_color)
        self.wheel_bg_color = try c.decodeIfPresent(String.self, forKey: .wheel_bg_color)
        self.wheel_height = try c.decodeIfPresent(Double.self, forKey: .wheel_height)
        self.wheel_line_color = try c.decodeIfPresent(String.self, forKey: .wheel_line_color)
        self.wheel_line_stroke_width = try c.decodeIfPresent(Double.self, forKey: .wheel_line_stroke_width)
        self.haptic_on_scroll = try c.decodeIfPresent(Bool.self, forKey: .haptic_on_scroll)
        self.children = try c.decodeIfPresent([ContentBlock].self, forKey: .children)
        self.stack_children = try c.decodeIfPresent([ContentBlock].self, forKey: .stack_children)
        self.z_index = try c.decodeIfPresent(Double.self, forKey: .z_index)
        self.gap = try c.decodeIfPresent(Double.self, forKey: .gap)
        self.wrap = try c.decodeIfPresent(Bool.self, forKey: .wrap)
        self.justify = try c.decodeIfPresent(String.self, forKey: .justify)
        self.align_items = try c.decodeIfPresent(String.self, forKey: .align_items)
        self.row_direction = try c.decodeIfPresent(String.self, forKey: .row_direction)
        self.column_ratios = try c.decodeIfPresent(String.self, forKey: .column_ratios)
        self.row_distribution = try c.decodeIfPresent(String.self, forKey: .row_distribution)
        self.row_child_fill = try c.decodeIfPresent(Bool.self, forKey: .row_child_fill)
        self.view_key = try c.decodeIfPresent(String.self, forKey: .view_key)
        self.custom_config = try c.decodeIfPresent([String: AnyCodable].self, forKey: .custom_config)
        self.placeholder_image_url = try c.decodeIfPresent(String.self, forKey: .placeholder_image_url)
        self.placeholder_text = try c.decodeIfPresent(String.self, forKey: .placeholder_text)
        self.particle_type = try c.decodeIfPresent(String.self, forKey: .particle_type)
        self.density = try c.decodeIfPresent(String.self, forKey: .density)
        self.speed = (try? c.decodeIfPresent(String.self, forKey: .speed)) ?? nil  // SPEC-419 pass-23 — tolerate a legacy numeric `speed` (old lottie blocks wrote a number here) rather than throwing on the whole block
        self.secondary_color = try c.decodeIfPresent(String.self, forKey: .secondary_color)
        self.size_range = try c.decodeIfPresent([Double].self, forKey: .size_range)
        self.fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen)
        self.particle_color = try c.decodeIfPresent(String.self, forKey: .particle_color)
        self.particle_opacity = try c.decodeIfPresent(Double.self, forKey: .particle_opacity)
        self.particle_speed = try c.decodeIfPresent(String.self, forKey: .particle_speed)
        self.min_value = try c.decodeIfPresent(Double.self, forKey: .min_value)
        self.max_value_picker = try c.decodeIfPresent(Double.self, forKey: .max_value_picker)
        self.step_value = try c.decodeIfPresent(Double.self, forKey: .step_value)
        self.default_picker_value = try c.decodeIfPresent(Double.self, forKey: .default_picker_value)
        // SPEC-419 — `try?`: top-level default_value is a number for wheel_picker, but tolerate a
        // stray non-number (e.g. an imported bool) without failing the whole block decode.
        self.default_value = (try? c.decodeIfPresent(Double.self, forKey: .default_value)) ?? nil
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.unit_position = try c.decodeIfPresent(String.self, forKey: .unit_position)
        self.visible_items = try c.decodeIfPresent(Int.self, forKey: .visible_items)
        self.pulse_color = try c.decodeIfPresent(String.self, forKey: .pulse_color)
        self.pulse_ring_count = try c.decodeIfPresent(Int.self, forKey: .pulse_ring_count)
        self.pulse_speed = try c.decodeIfPresent(Double.self, forKey: .pulse_speed)
        self.border_width = try c.decodeIfPresent(Double.self, forKey: .border_width)
        self.border_color = try c.decodeIfPresent(String.self, forKey: .border_color)
        self.pricing_plans = try c.decodeIfPresent([PricingPlanConfig].self, forKey: .pricing_plans)
        self.pricing_layout = try c.decodeIfPresent(String.self, forKey: .pricing_layout)
        self.field_label = try c.decodeIfPresent(String.self, forKey: .field_label)
        self.field_placeholder = try c.decodeIfPresent(String.self, forKey: .field_placeholder)
        self.field_required = try c.decodeIfPresent(Bool.self, forKey: .field_required)
        self.field_style = try c.decodeIfPresent(FormFieldBlockStyle.self, forKey: .field_style)
        self.field_options = try c.decodeIfPresent([InputOption].self, forKey: .field_options)
        self.multi_select = try c.decodeIfPresent(Bool.self, forKey: .multi_select)
        self.field_config = try c.decodeIfPresent([String: AnyCodable].self, forKey: .field_config)
        self.visibility_condition = try c.decodeIfPresent(VisibilityCondition.self, forKey: .visibility_condition)
        self.entrance_animation = try c.decodeIfPresent(EntranceAnimation.self, forKey: .entrance_animation)
        self.pressed_style = try c.decodeIfPresent(PressedStyle.self, forKey: .pressed_style)
        self.bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings)
        self.element_width = try c.decodeIfPresent(String.self, forKey: .element_width)
        self.element_height = try c.decodeIfPresent(String.self, forKey: .element_height)
        self.overflow = try c.decodeIfPresent(String.self, forKey: .overflow)
        self.collapse_on_scroll = try c.decodeIfPresent(Bool.self, forKey: .collapse_on_scroll)
        self.max_lines = try c.decodeIfPresent(Int.self, forKey: .max_lines)
    }
}
