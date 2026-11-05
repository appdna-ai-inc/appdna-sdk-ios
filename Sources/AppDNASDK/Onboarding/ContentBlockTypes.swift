import SwiftUI
import MapKit
import PhotosUI

// MARK: - Content Block Type

public enum ContentBlockType: String, Codable {
    case heading, text, image, button, spacer, list, divider, badge, icon, toggle, video
    // Rich media block types
    case lottie, rive
    // Phase A: New onboarding block types
    case page_indicator, wheel_picker, pulsing_avatar, social_login
    case timeline, animated_loading, star_background, countdown_timer
    case rating, rich_text, progress_bar
    // Phase F: Container & advanced block types
    case stack, custom_view, date_wheel_picker, circular_gauge, row
    /// Several CTAs laid out N per row on one shared background.
    case multi_buttons
    // Map with an optional route. Every setting rides in `field_config`.
    case map
    //
    case pricing_card
    // Media gallery (horizontal row of image tiles)
    case media_gallery
    // EPIC-4b — section background (vertical color zones behind overlaid content)
    case section_background
    // Swipeable carousel (paged content + dot indicator)
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
    // Device QA (s20/s22) — CTA-style button that plays an audio clip
    // (mp3/wav/aac) from `audio_url` on tap; reuses all button styling fields.
    case sound_button
    // Device QA (2026-08-04, s1) — standalone consent/agreement: a tappable checkbox + a
    // rich label with [terms](url)/[privacy](url) links, persisting a Bool to inputValues; its
    // `field_required` gates the CTA via RequiredFieldGate.
    case agreement
    // Form input block types (22 types)
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
        if let known = ContentBlockType(rawValue: rawValue) {
            self = known
        } else {
            // Decoding still SUCCEEDS — one unknown block must never cost the whole step. But it no
            // longer happens in silence: `.unknown` renders as EmptyView, so without this report a
            // host sees a step with a hole in it and nothing to explain it.
            UnsupportedBlockTypes.note(rawValue)
            self = .unknown
        }
    }
}

/// Every block `type` seen during decode that this SDK version does not know.
///
/// Reported ONCE per distinct type: a flow with twenty steps carrying the same unsupported block
/// would otherwise fire the host's delegate twenty times and drown the signal it exists to give.
enum UnsupportedBlockTypes {
    private static let lock = NSLock()
    private static var reported = Set<String>()

    static func note(_ rawType: String) {
        lock.lock()
        let isNew = reported.insert(rawType).inserted
        lock.unlock()
        guard isNew else { return }
        AppDNA.reportInitDegraded(AppDNAInitError.unsupportedBlockType(rawType))
    }

    /// Test seam — the set is process-global, so a test that asserts on the first report needs to
    /// clear what an earlier test already recorded.
    static func resetForTesting() {
        lock.lock(); reported.removeAll(); lock.unlock()
    }
}

// MARK: - Block Style Design Tokens

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

// MARK: - Block Style ViewModifier

/// Applies `block_style` design tokens to any content block view.
struct BlockStyleModifier: ViewModifier {
    let style: BlockStyle?

    /**
     A block's authored shadow through `StyleEngine.resolveShadow`, the ONE seam that says
     what an authored shadow means. `BlockShadowStyle` is the block spelling of the same five
     fields `ShadowStyleConfig` carries, so it converts rather than re-deciding.
     */
    static func resolved(_ style: BlockStyle?) -> ResolvedShadow? {
        guard let sh = style?.shadow else { return nil }
        return StyleEngine.resolveShadow(ShadowStyleConfig(
            x: sh.x, y: sh.y, blur: sh.blur, spread: sh.spread, color: sh.color
        ))
    }

    func body(content: Content) -> some View {
        let resolvedShadow = Self.resolved(style)
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
                // Shadow — through `StyleEngine.resolveShadow`: the same seam the paywall
                // container styling uses and the same seam the shared fixture drives, so a block
                // and a section cannot disagree about what an authored shadow means. The values are
                // unchanged on this side; Android was the half that dropped colour and offset.
                .shadow(
                    color: resolvedShadow?.color ?? .clear,
                    radius: CGFloat(resolvedShadow?.radius ?? 0),
                    x: CGFloat(resolvedShadow?.dx ?? 0),
                    y: CGFloat(resolvedShadow?.dy ?? 0)
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
    /// Apply block_style design tokens.
    func applyBlockStyle(_ style: BlockStyle?) -> some View {
        modifier(BlockStyleModifier(style: style))
    }
}

// MARK: - Visibility Condition

/// Condition that determines whether a block should be rendered.
public struct VisibilityCondition: Codable {
    public let type: String?       // always, when_equals, when_not_equals, when_not_empty, when_empty, when_gt, when_lt, expression
    public let variable: String?  // dot-path e.g. "responses.step1.age"
    public let value: AnyCodable? // comparison value
    public let expression: String? // for complex expressions
}

/// Evaluates a visibility condition against the current data context.
/// The input key a Summary Screen stat reads and writes.
///
/// A stat authored with an `input` but no `field_id` used to render as an EMPTY CARD, and its
/// `required` was silently dropped with it: the renderer and `RequiredFieldGate` both skipped the
/// stat on the missing id, so the author saw a blank box where a control belonged and a
/// requirement that gated nothing. Deriving a stable id from the block and the stat's position
/// makes the control appear and the requirement real.
///
/// 🔴 The renderer and the gate MUST derive this identically. If they drift, the gate blocks on a
/// key nothing writes and the step cannot be advanced at all — the exact failure the gate's own
/// history records fixing twice.
func summaryStatFieldId(blockId: String, index: Int, stat: [String: Any]) -> String {
    if let authored = stat["field_id"] as? String, !authored.isEmpty { return authored }
    return "\(blockId)_stat_\(index)"
}

/// `stepId` + `stepInputs` are what make a condition react WHILE the step is open.
///
/// `responses` holds completed steps only, so "show this when the category above is Modern" could
/// never be true: the category is chosen while the step is still on screen, which is the only
/// moment the condition matters. `VisibilityScope` merges the live inputs in under the step's own
/// id (live winning), so `responses.<thisStep>.<field>` resolves to what the control holds right
/// now — and `step.<field>` resolves too, the root the template engine and bindings have always
/// had and a condition never did.
///
/// Both default to nil, so every caller that cannot supply them — a Screens surface, an option
/// sheet — behaves exactly as before.
func evaluateVisibilityCondition(
    _ condition: VisibilityCondition?,
    responses: [String: Any],
    hookData: [String: Any]?,
    userTraits: [String: Any]? = nil,
    sessionData: [String: Any]? = nil,
    stepId: String? = nil,
    stepInputs: [String: Any]? = nil
) -> Bool {
    guard let cond = condition else { return true }
    let responses = VisibilityScope.merge(responses: responses, stepId: stepId, stepInputs: stepInputs)

    switch cond.type {
    case "always":
        return true
    case "when_equals":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData, stepInputs: stepInputs)
        let expected = cond.value?.value
        return valuesEqual(resolved, expected)
    case "when_not_equals":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData, stepInputs: stepInputs)
        let expected = cond.value?.value
        return !valuesEqual(resolved, expected)
    case "when_not_empty":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData, stepInputs: stepInputs)
        return resolved.map { "\($0)" != "" } ?? false
    case "when_empty":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData, stepInputs: stepInputs)
        return resolved.map { "\($0)" == "" } ?? true
    case "when_gt":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData, stepInputs: stepInputs)
        return compareNumeric(resolved, cond.value?.value) == .orderedDescending
    case "when_lt":
        let resolved = resolveDotPath(cond.variable, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData, stepInputs: stepInputs)
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
    sessionData: [String: Any]?,
    /// The current step's live `inputValues`, addressable as `{{step.field_id}}`.
    /// Defaulted so every existing call site keeps compiling and behaves exactly as before.
    stepInputs: [String: Any]? = nil,
    /// A stored value's or a URL's path: a Google location answer it reaches or passes through
    /// resolves to the answer's typed text (`HostDataResolver.typedTextRule`).
    typedText: Bool = false
) -> Any? {
    guard let path = path, !path.isEmpty else { return nil }
    // An empty segment (`responses..x`) names nothing: refused, as Android and the credit walk read it.
    let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, !parts.contains(where: \.isEmpty) else { return nil }

    let root: [String: Any]?
    switch parts[0] {
    case "responses": root = responses
    case "hook_data": root = hookData
    case "user": root = userTraits
    case "session": root = sessionData
    // The CURRENT step's in-progress inputs. `responses` holds completed steps only,
    // so a stat showing the value of a slider on the same card resolved to nothing until the step
    // ended, at which point the card is gone. Registered here, in the preview, and in the
    // picker's namespace list; an unregistered root resolves to nil and renders raw.
    case "step": root = stepInputs
    // The OPTION the user picked, not just its value. `{{selected.venue.subtitle}}`
    // on a later screen. Read from its own store rather than `responses`, because `responses` is
    // what customer webhooks receive and must stay byte-identical for anyone not using this.
    case "selected": root = SelectedOptionStore.shared.snapshot
    default: root = nil
    }

    guard var current: Any = root else { return nil }
    for part in parts.dropFirst() {
        if typedText && LocationAnswer.carriesPlaceId(current) { return TemplateEngine.typedText(of: current) }
        // A picked option's key that came from a Google answer: the text as the user typed it.
        if typedText && parts[0] == "selected", let typed = SelectedOptionStore.typedText(of: current, key: part) { return typed }
        if let dict = current as? [String: Any], let next = dict[part] {
            current = next
        } else if let array = current as? [Any], let idx = Int(part), idx >= 0, idx < array.count {
            // Numeric step into an array — `{{selected.tags.0.label}}`. Multi-select records an
            // array in selection order, so without this the first choice is unreachable.
            current = array[idx]
        } else {
            return nil
        }
    }
    // A path that stops at a picked record (or a multi pick's list): every key it took from a Google
    // answer takes the text the user typed, as a path to that key does.
    if typedText && parts[0] == "selected" { current = SelectedOptionStore.withTypedText(current) }
    return typedText ? TemplateEngine.typedTextForGoogleAnswers(in: current) : current
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

// MARK: - Entrance Animation

/// Configuration for entrance animation on a content block.
public struct EntranceAnimation: Codable {
    public let type: String?       // none, fade_in, slide_up, slide_down, slide_left, slide_right, scale_up, scale_down, bounce, flip
    public let duration_ms: Int?  // 100-2000
    public let delay_ms: Int?     // 0-5000
    public let easing: String?    // linear, ease, ease_in, ease_out, ease_in_out, spring
    public let spring_damping: Double? // 0.1-1.0
    // Sequenced animation (Device QA — s14): per-block stagger + ordering.
    // animation_delay_ms is ADDED to delay_ms to sequence blocks; animation_order is
    // authored ordering metadata (lower plays first, full timeline engine deferred).
    public let animation_delay_ms: Int? // 0-5000
    public let animation_order: Int?    // 0-999
}

// MARK: - Pressed Style

/// Style to apply when an interactive element is pressed.
public struct PressedStyle: Codable {
    public let bg_color: String?
    public let text_color: String?
    public let scale: Double?    // 0.85-1.0
    public let opacity: Double?  // 0.5-1.0
}

// MARK: - Form Field Style

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
    // `label_position` has been settable in the console (and honoured by
    // the web preview) since it shipped, but NEITHER native decoded it, so authors were
    // setting a control that did nothing on device. "hidden" is the value with a defined
    // meaning; "inline"/"floating" are not distinct behaviours on any surface yet.
    public let label_position: String?
    // The two controls the reporter found genuinely missing.
    public let label_align: String?          // "left" (default) | "center" | "right"
    public let label_font_family: String?
    public let error_border_color: String?
    public let error_text_color: String?
    public let track_color: String?
    public let fill_color: String?
    public let thumb_color: String?
    public let toggle_on_color: String?
    public let toggle_off_color: String?
    // Select v2 (Device QA) — per-option styling extras applied by the select renderers.
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
    /// Which category chip this option belongs to. An option with NO
    /// category shows under EVERY chip, so adding chips to an existing Select never hides
    /// options the author already had.
    public let category: String?
    /// The bottom sheet this option opens when picked. Contents are
    /// ordinary content blocks, so one engine serves both the chooser sheet and the detail
    /// sheet. Presentation-only: nothing set inside is reported back, so there is no new
    /// response plumbing here.
    public var sheet_blocks: [ContentBlock]?
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
    // Selected-state image tint (falls back to image_overlay_* when unset)
    public let selected_image_overlay_color: String?
    public let selected_image_overlay_opacity: Double?
    // Per-option image clip shape: "circle" (default) | "rounded" | "square"
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
    // Per-option additions
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
        let rawId = container.lenient(String.self, .id)
        let rawValue = container.lenient(String.self, .value)
        self.id = rawId ?? rawValue ?? ""
        self.value = rawValue ?? rawId
        self.label = container.lenient(String.self, .label)
        self.icon = container.lenient(String.self, .icon)
        self.image_url = container.lenient(String.self, .image_url)
        self.selected_image_url = container.lenient(String.self, .selected_image_url)
        self.unselected_image_url = container.lenient(String.self, .unselected_image_url)
        self.category = container.lenient(String.self, .category)
        // Defensive, like every other optional here: a malformed sheet costs the author their
        // sheet, never the whole step.
        self.sheet_blocks = try? container.decodeLenientArray(ContentBlock.self, forKey: .sheet_blocks, in: "block.sheet_blocks")
        self.subtitle = container.lenient(String.self, .subtitle)
        self.title_color = container.lenient(String.self, .title_color)
        self.subtitle_color = container.lenient(String.self, .subtitle_color)
        self.title_font_size = container.lenient(Double.self, .title_font_size)
        self.subtitle_font_size = container.lenient(Double.self, .subtitle_font_size)
        self.title_font_weight = container.lenient(String.self, .title_font_weight)
        self.selected_icon = container.lenient(String.self, .selected_icon)
        self.unselected_icon = container.lenient(String.self, .unselected_icon)
        self.image_overlay_color = container.lenient(String.self, .image_overlay_color)
        self.image_overlay_opacity = container.lenient(Double.self, .image_overlay_opacity)
        self.selected_image_overlay_color = container.lenient(String.self, .selected_image_overlay_color)
        self.selected_image_overlay_opacity = container.lenient(Double.self, .selected_image_overlay_opacity)
        self.image_shape = container.lenient(String.self, .image_shape)
        self.border_color = container.lenient(String.self, .border_color)
        self.selected_border_color = container.lenient(String.self, .selected_border_color)
        self.bg_color = container.lenient(String.self, .bg_color)
        self.selected_bg_color = container.lenient(String.self, .selected_bg_color)
        self.selected_text_color = container.lenient(String.self, .selected_text_color)
        self.cell_alignment = container.lenient(String.self, .cell_alignment)
        self.text_alignment = container.lenient(String.self, .text_alignment)
        self.leading_text = container.lenient(String.self, .leading_text)
        self.trailing_text = container.lenient(String.self, .trailing_text)
        self.badge = try container.decodeIfPresent(OptionBadge.self, forKey: .badge)
    }

    /// Non-optional value — falls back to id if value is nil.
    public var resolvedValue: String { value ?? id ?? "" }

    /// The keys of this option whose drawn text took a Google location answer's content, each with
    /// that text as the user typed it (every Google answer in it replaced by its `raw_query`), as the
    /// resolver that filled the option found them (`HostDataResolveResult.googleOptionKeys`). Never
    /// decoded from or encoded to JSON: a pick records it with the option, so a later
    /// `{{selected.<field>.<key>}}` showing that text draws Google's attribution, and one storing or
    /// sending it takes the typed text.
    var googleKeys: [String: String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, label, value, icon, image_url
        case selected_image_url, unselected_image_url
        case category, sheet_blocks
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

// MARK: - Relative Sizing Helper

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

// MARK: - Template String Resolution

/// Resolves `{{variable}}` template strings in text.
func resolveTemplateString(
    _ text: String,
    hookData: [String: Any]?,
    responses: [String: Any],
    sessionData: [String: Any]? = nil,
    userTraits: [String: Any]? = nil,
    stepInputs: [String: Any]? = nil,
    /// Where `text` sits (`HostDataResolver.typedTextRule`): a token the rule covers resolves a Google
    /// answer to its typed text. Nil: drawn text, where only a markdown link's target does.
    key: String? = nil,
    isOption: Bool = false,
    /// Every token takes the typed text: text drawn where no Google credit is (a Screen), or the text
    /// an option keeps for a Google key (`InputOption.googleKeys`).
    allTyped: Bool = false,
    /// A token naming a whole location answer draws its line (`formatted_address`, else `address`)
    /// rather than the dictionary — a sheet's late `{{step.<field>}}`.
    wholeLocationAnswer: Bool = false
) -> String {
    resolveTemplateStringReadingGoogle(
        text, hookData: hookData, responses: responses, sessionData: sessionData, userTraits: userTraits,
        stepInputs: stepInputs, key: key, isOption: isOption, allTyped: allTyped, wholeLocationAnswer: wholeLocationAnswer
    ).value
}

/// `resolveTemplateString`, and whether what it drew shows a Google answer's content: a token that resolves (not to
/// its fallback) where the typed-text rule does not apply, on a path that reads a Google answer under
/// `googleAnswers` (`GoogleCredit.pathCredits`). An option's stored key (`value`, ...) takes the typed text, so it
/// shows none. The Kotlin twin is `HostDataResolver.plainStringReadsGoogle`.
func resolveTemplateStringReadingGoogle(
    _ text: String,
    hookData: [String: Any]?,
    responses: [String: Any],
    sessionData: [String: Any]? = nil,
    userTraits: [String: Any]? = nil,
    stepInputs: [String: Any]? = nil,
    /// Where `text` sits (`HostDataResolver.typedTextRule`): a token the rule covers resolves a Google
    /// answer to its typed text. Nil: drawn text, where only a markdown link's target does.
    key: String? = nil,
    isOption: Bool = false,
    /// Every token takes the typed text: text drawn where no Google credit is (a Screen), or the text
    /// an option keeps for a Google key (`InputOption.googleKeys`).
    allTyped: Bool = false,
    /// A token naming a whole location answer draws its line (`formatted_address`, else `address`)
    /// rather than the dictionary — a sheet's late `{{step.<field>}}`.
    wholeLocationAnswer: Bool = false,
    googleAnswers: GoogleCredit.Answers? = nil
) -> (value: String, readGoogle: Bool) {
    var result = text
    var readGoogle = false
    let rule = allTyped
        ? HostDataResolver.TypedTextRule(all: true, ranges: [])
        : HostDataResolver.typedTextRule(text, key: key, isOption: isOption)
    // The console's variable picker tells authors to write `{{var | fallback}}`
    // and the web preview implements it. Neither native did: this character class contained
    // neither `|` nor a space, so `{{responses.name | Guest}}` did not match AT ALL and the whole
    // literal — pipe included — rendered on the user's screen. An author following our own
    // instruction shipped a raw token to customers.
    // The character class includes `-` because `field_id` is a free string in the console schema:
    // an author can type `party-size`, and an AI-generated flow routinely does. The picker then
    // offers `{{responses.party-size}}` and the editor preview drew it as a valid chip, while this
    // pattern did not match it AT ALL and the literal shipped to the user — the same shape as the
    // pipe bug, where the console advertised a syntax the natives could not read.
    let pattern = "\\{\\{\\s*([a-zA-Z0-9_.\\-]+)\\s*(?:\\|\\s*([^}]*?)\\s*)?\\}\\}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, false) }
    let nsRange = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: nsRange)

    // Iterate in reverse to preserve ranges
    for match in matches.reversed() {
        guard let fullRange = Range(match.range, in: result),
              let pathRange = Range(match.range(at: 1), in: result) else { continue }
        let path = String(result[pathRange])
        var resolved = resolveDotPath(
            path, responses: responses, hookData: hookData, userTraits: userTraits, sessionData: sessionData,
            stepInputs: stepInputs, typedText: rule.covers(match.range.location)
        )
        if wholeLocationAnswer, let line = LocationAnswer.fieldText(forStored: resolved), !(resolved is String) {
            resolved = line
        }
        // `{{x | Guest}}` — the fallback is used when the path resolves to nothing, which is also
        // the only way an author can stop an unresolved token reaching a customer's screen.
        let fallback: String? = match.range(at: 2).location == NSNotFound
            ? nil
            : Range(match.range(at: 2), in: result).map { String(result[$0]) }
        // A null (a trait identify kept as NSNull, a null in hook data) is unresolved, never "<null>".
        if let resolved = resolved, !(resolved is NSNull) {
            if let answers = googleAnswers, !rule.covers(match.range.location),
               GoogleCredit.pathCredits(path, answers) {
                readGoogle = true
            }
            result.replaceSubrange(fullRange, with: "\(resolved)")
        } else if let fallback = fallback {
            result.replaceSubrange(fullRange, with: fallback)
        }
    }
    return (result, readGoogle)
}

// MARK: - 2D Positioning Modifier

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
    /// Apply 2D positioning.
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

// MARK: - Entrance Animation Wrapper

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
                let delaySeconds = Double((animation.delay_ms ?? 0) + (animation.animation_delay_ms ?? 0)) / 1000.0
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

// MARK: - Pressed Style ViewModifier

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
    /// Apply press/tap state styling.
    func applyPressedStyle(_ style: PressedStyle?) -> some View {
        modifier(PressedStyleModifier(pressedStyle: style))
    }
}

// MARK: - Relative Sizing ViewModifier

/// The width of the container a block is being laid out in, published by whoever lays it out.
///
/// A percentage `element_width` used to resolve against `UIScreen.main.bounds` minus an
/// ASSUMED global padding. Android resolves it against the real container (`fillMaxWidth(fraction)`)
/// and so does the console preview (CSS `width: 75%`), so iOS was the one surface disagreeing: the
/// same authored `75%` came out a different width on iOS than the canvas the author designed on,
/// and a different width again on a different-sized phone.
///
/// 0 means "nobody measured" — the modifier then falls back to the old screen approximation, which
/// keeps any surface that has not adopted this working exactly as it did.
private struct ContainerWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var appdnaContainerWidth: CGFloat {
        get { self[ContainerWidthKey.self] }
        set { self[ContainerWidthKey.self] = newValue }
    }
}

/// "this block was produced by the raw host-data pass". Propagates to every NESTED
/// renderer a raw-resolved block creates (carousel pages, option sheets), so none of them runs the
/// view-level template pass over strings that were already resolved (no re-scan of host data).
private struct RawResolvedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var appdnaRawResolved: Bool {
        get { self[RawResolvedKey.self] }
        set { self[RawResolvedKey.self] = newValue }
    }
}

/// Where the blocks below are drawn. Only an onboarding step's container credits Google, so only the
/// step router sets `.onboarding`; anywhere else (a Screen) the view-level pass resolves a Google
/// answer — and a picked option's Google key — to the text the user typed.
private struct TemplateSurfaceKey: EnvironmentKey {
    static let defaultValue: TemplateSurface = .other
}

extension EnvironmentValues {
    var appdnaTemplateSurface: TemplateSurface {
        get { self[TemplateSurfaceKey.self] }
        set { self[TemplateSurfaceKey.self] = newValue }
    }
}

/// The onboarding step's interaction channel, for `refresh_step` buttons at ANY
/// depth: top level, the three zones, `multi_buttons` children, `row` / `stack` /
/// `section_background` children and carousel pages (whose nested renderer is built without
/// `onInteract`). Provided by `OnboardingStepRouter` on its block-step content.
///
/// Precedence: when NON-nil it is authoritative for `refresh_step` buttons — the call, the loading
/// state and tappability. When nil (Screens / SDUI, an option sheet) the explicit `onInteract`
/// parameter is used, so those surfaces are unchanged. Option sheets set it to nil explicitly: a
/// sheet has its own inputs and no interaction channel.
struct StepInteraction: Equatable {
    /// The presentation serial this channel belongs to — compared, so a router reused for a new
    /// presentation always hands its children the new instance's `fire`.
    var presentation: Int
    /// The refresh button whose call is in flight (spinner), if any.
    var loadingBlockId: String?
    /// False while ANY interaction of the presentation is in flight, or while the
    /// presentation is pending. Such a button draws normally; a tap is not a call.
    var refreshTappable: Bool
    /// The step scope's `handleInteract(blockId, action, value)`.
    var fire: (String, String, String?) -> Void

    /// The ONE tap rule for a `refresh_step` button (C5.3 / C5.4), used by the button and by the
    /// fixture driver: a locked button's tap is not a call (debug log); otherwise it fires `refresh`
    /// with the button's `action_value`. Returns whether the call was handed to the step.
    @discardableResult
    func tapRefresh(blockId: String, actionValue: String?) -> Bool {
        guard refreshTappable else {
            Log.debug("[Onboarding] refresh_step \(blockId) tapped while locked (an interaction is in flight or host data is pending) — ignored")
            return false
        }
        fire(blockId, InteractionCoordinator.refreshAction, actionValue)
        return true
    }

    /// Built from the presentation's coordinator — the one place `refreshTappable` is derived.
    static func make(presentation: Int, coordinator: InteractionCoordinator, pending: Bool,
                     fire: @escaping (String, String, String?) -> Void) -> StepInteraction {
        StepInteraction(presentation: presentation, loadingBlockId: coordinator.loadingBlockId,
                        refreshTappable: coordinator.isTappable(blockId: "", pending: pending), fire: fire)
    }

    /// The closure is deliberately not compared (closures cannot be); the state is what re-renders.
    /// A stale `fire` (bound to an older router copy) is safe: every input the reply fold reads —
    /// the base override, the layer — is read LIVE from the store.
    static func == (a: StepInteraction, b: StepInteraction) -> Bool {
        a.presentation == b.presentation && a.loadingBlockId == b.loadingBlockId && a.refreshTappable == b.refreshTappable
    }
}

private struct StepInteractionKey: EnvironmentKey {
    static let defaultValue: StepInteraction? = nil
}

extension EnvironmentValues {
    var appdnaStepInteraction: StepInteraction? {
        get { self[StepInteractionKey.self] }
        set { self[StepInteractionKey.self] = newValue }
    }
}

/// What a fractional `element_width` actually resolves to.
///
/// Pure so the rule is asserted by a test rather than by eye. `container` is the measured width of
/// whatever the block sits in; 0 means nobody measured, and the fallback is the historical
/// screen-minus-assumed-padding approximation so an unmeasured surface behaves exactly as before
/// rather than collapsing to zero.
func relativeWidth(_ fraction: CGFloat, container: CGFloat) -> CGFloat {
    if container > 0 { return container * fraction }
    let screen = UIScreen.main.bounds.width
    return (screen - (max(24, screen * 0.08) * 2)) * fraction
}

/// Does this block need an outer full-width box to align inside?
///
/// Mirrors Android `needsOuterAlignmentBox`, and iOS needed it for the same reason Android did:
/// `BlockPositionModifier` applies `.frame(maxWidth: .infinity, alignment:)` INSIDE the sizing
/// frame, so once the sizing frame constrains the block to 300pt the alignment is resolving inside
/// 300pt and has nowhere to move. The VStack then centres the result, which is why a block authored
/// `right` and one authored `center` rendered in the SAME position.
///
/// Only a width-CONSTRAINED block needs it: an unconstrained one is already full-width, so its
/// inner alignment has the whole row and wrapping it again would change nothing but the layout
/// tree.
func needsOuterAlignmentBox(elementWidth: String?, horizontalAlign: String?) -> Bool {
    guard let align = horizontalAlign, !align.isEmpty else { return false }
    guard let width = elementWidth, !width.isEmpty, width != "auto", width != "fill" else { return false }
    return width.hasSuffix("%") || width.hasSuffix("px")
}

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
        // NB: the SDK defines a public `enum Environment` (Configuration.swift) that shadows
        // SwiftUI's `@Environment` property wrapper here — fully qualify it.
        @SwiftUI.Environment(\.appdnaContainerWidth) private var containerWidth

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
                    content.frame(width: relativeWidth(fraction, container: containerWidth))
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
    /// Apply relative sizing.
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

// MARK: - Nested Codable types for block fields

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
    // (Apple=black, Google=#4285F4, email=#6366F1, etc.).
    public let bg_color: String?
    public let text_color: String?
    public let border_color: String?
    public let border_width: Double?
    public let corner_radius: Double?
    // Social-Login styling v2 — per-provider custom icon override. When set to a
    // non-empty URL the SDK renders the remote image instead of the built-in
    // provider glyph. nil → keep the brand glyph.
    public let icon_url: String?
    /// Per-provider label size. Requested by QA once the Style section became findable:
    /// the colours were there and the size was not, so a provider could be styled to match a brand
    /// everywhere except its type.
    public let font_size: Double?
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
    /// The keys of this plan whose drawn text took a Google location answer's content, each with that
    /// text as the user typed it — as `InputOption.googleKeys`. Never decoded from or encoded to JSON: a
    /// pick stores the plan's label (`selected_plan_label`), and a stored label takes the typed text.
    var googleKeys: [String: String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, label, price, period, badge, is_highlighted
    }

    /// The label a pick stores: the text the user typed where the drawn label came from a Google answer.
    var storedLabel: String { googleKeys?["label"] ?? label ?? "" }
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
    // Wrap the image in a device frame: "phone" = bezel + dynamic-island notch.
    public let image_frame: String?
    // Button
    public let variant: String?
    public let action: String?     // next, skip, link, permission
    public let action_value: String?  // URL for link, permission type for permission
    public let bg_color: String?
    public let text_color: String?
    public let button_corner_radius: Double?
    // sound_button — remote audio clip (mp3/wav/aac) played on tap. `autoplay`
    // (declared below with the video fields) plays it when the block appears.
    public let audio_url: String?
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
    // Video playback options
    public let autoplay: Bool?
    public let loop: Bool?
    public let muted: Bool?
    public let controls: Bool?
    // `video_*`-prefixed fallbacks. The console editor +
    // preview + Android all write the prefixed keys (video_autoplay/_loop/
    // _muted/_controls); iOS previously only decoded the unprefixed
    // autoplay/loop/muted/controls, so authored prefixed payloads were
    // silently ignored. Decode both; the renderer falls back unprefixed → prefixed.
    public let video_autoplay: Bool?
    public let video_loop: Bool?
    public let video_muted: Bool?
    public let video_controls: Bool?
    // Lottie
    public let lottie_url: String?
    public let lottie_speed: Double?
    public let lottie_width: Double?
    public let lottie_height: Double?
    public let play_on_scroll: Bool?
    public let play_on_tap: Bool?
    // Rive
    public let rive_url: String?
    public let artboard: String?
    public let state_machine: String?
    public let trigger_on_step_complete: String?
    /*
     * 🔴 THE STATE-MACHINE INPUTS, which reached nothing on either platform under any name.
     *
     * `RiveBlockSchema` declares `inputs`; Android's renderer read `block.rive_inputs` and its
     * DECODER never populated that field, so it was always null; iOS did not declare an inputs key
     * at all and `riveBlock` passed `inputs: nil` outright. Three surfaces, three different
     * answers, and an authored input did nothing anywhere — the same shape as `field_style` vs
     * `style`.
     *
     * `inputs` is canonical because it is what the console schema writes. Android keeps
     * `rive_inputs` as a read-only alias so anything already authored that way still works.
     */
    public let inputs: [String: AnyCodable]?
    // Icon reference (structured icon)
    public let icon_ref: IconReference?

    // Per-block style design tokens
    public let block_style: BlockStyle?

    // Zone-based positioning
    public let zone: String?              // "top", "center", "bottom" — explicit zone
    public let vertical_align: String?    // Legacy, used as fallback when zone is nil
    public let horizontal_align: String?
    public let vertical_offset: Double?
    public let horizontal_offset: Double?

    // Phase A: page_indicator fields
    public let dot_count: Int?
    public let active_index: Int?
    public let active_color: String?
    public let inactive_color: String?
    public let dot_size: Double?
    public let dot_spacing: Double?
    public let active_dot_width: Double?
    public let dot_shape: String?   // "circle" (default) | "triangle" | "rectangle" | "star"
    public let alignment: String?

    // Phase A: social_login fields
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
    // Email CTA placement + spacer
    public let email_login_placement: String?   // "with_providers" | "below_inputs"
    public let email_cta_spacing_below: Double? // px spacer after email button

    // Phase A: countdown_timer fields
    public let timer_variant: String?      // digital, circular, flip, bar
    public let duration_seconds: Int?
    // Countdown target mode (parity with Android ContentBlockRenderer.kt): "duration"
    // (default — counts down duration_seconds) or "fixed_datetime" (counts down to an
    // absolute ISO-8601 UTC instant in target_datetime).
    public let target_type: String?
    public let target_datetime: String?    // ISO-8601 UTC, e.g. "2026-12-31T23:59:59"
    public let show_days: Bool?
    public let show_hours: Bool?
    public let show_minutes: Bool?
    public let show_seconds: Bool?
    public let labels: CountdownLabelsConfig?
    public let on_expire_action: String?   // hide, show_expired_text, auto_advance
    public let expired_text: String?
    public let accent_color: String?
    public let font_size: Double?

    // Phase A: rating fields
    public let max_stars: Int?
    public let default_rating: Double?
    public let star_size: Double?
    public let filled_color: String?
    public let empty_color: String?
    public let allow_half: Bool?
    public let field_id: String?
    public let rating_label: String?

    // Phase A: rich_text fields
    public let markdown_content: String?
    public let rich_text_variant: String?  // default, legal
    public let base_style: TextStyleConfig?
    public let link_color: String?

    // Phase A: progress_bar fields
    public let progress_variant: String?   // continuous, segmented
    public let progress_value: Double?
    public let total_segments: Int?
    public let filled_segments: Int?
    public let bar_height: Double?
    public let bar_color: String?
    // Multiple progress colors at once (horizontal gradient across the fill).
    public let bar_gradient_colors: [String]?
    public let track_color: String?
    public let show_label: Bool?
    public let segment_gap: Double?
    // progress_bar label formatting. `label_format`:
    // "percentage" | "fraction" | "custom"; `custom_label` supplies the text
    // when format == "custom". Authored top-level by the console editor.
    public let label_format: String?
    public let custom_label: String?
    // Progress/Loading v2 — placement of the progress label relative to the bar:
    // "above" (default) | "below" | "left" | "right".
    public let label_placement: String?

    // Phase A: timeline fields
    public let timeline_items: [TimelineItemConfig]?
    public let line_color: String?
    public let completed_color: String?
    public let current_color: String?
    public let upcoming_color: String?
    public let show_line: Bool?
    public let compact: Bool?
    public let title_style: TextStyleConfig?
    public let subtitle_style: TextStyleConfig?

    // Phase A: animated_loading fields
    public let loading_variant: String?    // circular, linear, checklist
    // Configurable loading message + independent position (above/below), size, color.
    public let loading_text: String?
    public let loading_text_position: String?  // "above" | "below" (default "below")
    public let loading_text_size: Double?
    public let loading_text_color: String?
    // Progress/Loading v2 — horizontal alignment of the loading message:
    // "left" | "center" (default) | "right".
    public let loading_text_align: String?
    // media_gallery: horizontal row of image tiles.
    public let gallery_images: [String]?
    /// An optional title above the strip, belonging to the element rather than to a
    /// separate heading block an author has to keep aligned with it. Unset draws nothing.
    public let gallery_title: String?
    /// The title's colour. Unset follows the step's own text colour via the renderer default.
    public let gallery_title_color: String?
    public let gallery_item_width: Double?
    public let gallery_item_height: Double?
    public let gallery_corner_radius: Double?
    public let gallery_spacing: Double?
    public let gallery_align: String?  // "start" | "center" | "end" (default "center")
    // Media-gallery v2 (Device QA): gallery_fill = edge-to-edge cover tiles (full container width);
    // gallery_autoscroll = continuous loop; gallery_autoscroll_speed = seconds per full cycle (default 20).
    // All default off → identical to the existing static tile row (non-breaking).
    public let gallery_fill: Bool?
    public let gallery_autoscroll: Bool?
    public let gallery_autoscroll_speed: Double?
    public let loading_items: [LoadingItemConfig]?
    public let progress_color: String?
    public let check_color: String?
    public let total_duration_ms: Int?
    public let auto_advance: Bool?
    public let show_percentage: Bool?

    // Phase F: circular_gauge fields
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

    // Phase F: date_wheel_picker fields
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
    public let time_format: String?              // "12h" (default) | "24h" — clock presentation for input_time
    public let time_text_size: Double?           // font size (pt) of the displayed time in field/trigger mode
    public let picker_spacing: Double?           // spacing between time wheel and date graphical in datetime mode
    public let calendar_bg_color: String?        // explicit background color for graphical date picker
    public let wheel_bg_color: String?           // explicit background color for wheel date picker (top-level, not field_config)
    public let wheel_height: Double?             // wheel picker height in pt (top-level)
    // Console writes the picker divider/border line color + stroke at top level
    // (wheel_line_color / wheel_line_stroke_width). iOS previously read only field_config
    // picker_border_color/width, so authored line styling never appeared.
    public let wheel_line_color: String?
    public let wheel_line_stroke_width: Double?

    // Phase F: stack / row fields (container blocks)
    public var children: [ContentBlock]?
    public var stack_children: [ContentBlock]?  // Console uses this key; SDK prefers children
    public let z_index: Double?
    public let gap: Double?
    public let wrap: Bool?
    public let align_items: String?
    // Row layout direction and distribution
    public let row_direction: String?       // horizontal (default), vertical
    public let row_distribution: String?    // fill, start, center, end, space_between, space_around
    public let row_child_fill: Bool?        // true (default) — each child gets maxWidth: .infinity
    public let column_ratios: String?       // "1:2", "1:1:2" — proportional widths for horizontal layout

    // Phase F: custom_view fields
    public let view_key: String?
    public let custom_config: [String: AnyCodable]?
    public let placeholder_image_url: String?
    public let placeholder_text: String?

    // Phase F: star_background fields
    public let particle_type: String?      // stars, sparkles, dots, snow, bokeh
    public let density: String?            // sparse, medium, dense
    public let speed: String?              // slow, medium, fast
    public let secondary_color: String?
    public let size_range: [Double]?
    public let fullscreen: Bool?
    // Editor authors these top-level for star_background.
    public let particle_color: String?
    public let particle_opacity: Double?
    public let particle_speed: String?     // slow, medium, fast (editor key; falls back to `speed`)
    // Device QA (2026-08-04): confetti multicolor — cycle a fixed palette instead of primary/secondary.
    // Defaults on when particle_type == "confetti".
    public let particle_multicolor: Bool?

    // Phase F: wheel_picker fields
    public let min_value: Double?
    public let max_value_picker: Double?
    public let step_value: Double?
    public let default_picker_value: Double?
    // The console editor writes top-level `default_value` (number) for wheel_picker;
    // read it as a fallback for default_picker_value so authored defaults aren't lost on-device.
    public let default_value: Double?
    public let unit: String?
    public let unit_position: String?
    public let visible_items: Int?

    // Phase F: pulsing_avatar fields
    public let pulse_color: String?
    public let pulse_ring_count: Int?
    public let pulse_speed: Double?
    public let border_width: Double?
    public let border_color: String?

    // pricing_card fields
    public var pricing_plans: [PricingPlanConfig]?
    public let pricing_layout: String?     // stack, side_by_side

    // Form input common fields
    public let field_label: String?
    public let field_placeholder: String?
    public let field_required: Bool?
    public let field_style: FormFieldBlockStyle?
    /// `var`, not `let`, for the same reason `StepConfig`'s fields are: the host-data hook lets a host
    /// replace a single block's options, and a merge that had to rebuild the whole ContentBlock
    /// through its memberwise init would silently drop any field the author of that call forgot —
    /// the exact bug `StepConfigOverrideMerger` documents having shipped once already.
    public var field_options: [InputOption]?
    public let multi_select: Bool?
    // Form input specific config.
    //
    // `var` for the same reason `field_options` above is: the host-data hook lets a host supply a map block's
    // route at runtime, and the merge writes it into this dictionary under the keys the console
    // authors, so the renderer keeps a single code path for authored and delegate-supplied routes.
    public var field_config: [String: AnyCodable]?

    // Visibility condition
    public let visibility_condition: VisibilityCondition?

    // Entrance animation
    public let entrance_animation: EntranceAnimation?

    // Press/tap state
    public let pressed_style: PressedStyle?

    // Dynamic bindings
    public let bindings: [String: String]?

    // Relative sizing
    public let element_width: String?
    public let element_height: String?

    // Overflow control: "visible" disables clipping (e.g. for images that bleed out of rows)
    public let overflow: String?
    // Sprint 7: Scroll-collapse — block fades out and shrinks to 0 height when scrolled
    public let collapse_on_scroll: Bool?
    // Max line count for text/rich_text truncation (parity with Android `max_lines`)
    public let max_lines: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, text, style, level
        case image_url, alt, corner_radius, height, image_fit, image_frame
        case variant, action, action_value, bg_color, text_color, button_corner_radius
        case audio_url
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
        case rive_url, artboard, state_machine, trigger_on_step_complete, inputs
        case icon_ref
        case block_style
        case zone, vertical_align, horizontal_align, vertical_offset, horizontal_offset
        // Phase A: new block fields
        case dot_count, active_index, active_color, inactive_color
        case dot_size, dot_spacing, active_dot_width, dot_shape, alignment
        case providers, button_style, button_height, spacing
        case show_divider, divider_text
        // Social-Login styling v2
        case divider_position, button_text_align
        // Email button placement + spacer
        case email_login_placement, email_cta_spacing_below
        case timer_variant, duration_seconds
        case target_type, target_datetime
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
        case gallery_title, gallery_title_color
        case gallery_fill, gallery_autoscroll, gallery_autoscroll_speed
        case total_duration_ms, auto_advance, show_percentage
        // Phase F: new block fields
        case gauge_variant, gauge_value, max_value, sublabel, stroke_width, min_label, max_label, min_max_font_size
        case min_max_color, arrow_color, arrow_stroke_width, percentage_location
        case label_color, label_font_size, animate, animation_duration_ms
        case columns, default_date_value, min_date, max_date, allow_future, allow_past, date_validation_message
        case highlight_color, haptic_on_scroll, orientation, wheel_orientation, picker_presentation, picker_mode
        case time_format, time_text_size
        case picker_spacing, calendar_bg_color, wheel_bg_color, wheel_height
        case wheel_line_color, wheel_line_stroke_width
        case children, stack_children, z_index, gap, wrap, align_items
        case row_direction, row_distribution, row_child_fill, column_ratios
        case view_key, custom_config, placeholder_image_url, placeholder_text
        case particle_type, density, speed, secondary_color, size_range, fullscreen
        case particle_color, particle_opacity, particle_speed, particle_multicolor
        case min_value, max_value_picker, step_value, default_picker_value, default_value
        case unit, unit_position, visible_items
        case pulse_color, pulse_ring_count, pulse_speed, border_width, border_color
        case pricing_plans, pricing_layout
        // Form input + advanced styling fields
        case field_label, field_placeholder, field_required, field_style, field_options, multi_select, field_config
        case visibility_condition, entrance_animation, pressed_style, bindings
        case element_width, element_height
        case overflow, collapse_on_scroll, max_lines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Core fields — provide safe defaults so missing data doesn't crash
        self.id = c.lenient(String.self, .id) ?? UUID().uuidString
        self.type = try c.decodeIfPresent(ContentBlockType.self, forKey: .type) ?? .unknown
        // All remaining fields are optional — decode normally
        self.text = c.lenient(String.self, .text)
        self.style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .style)
        self.level = c.lenient(Int.self, .level)
        self.image_url = c.lenient(String.self, .image_url)
        self.alt = c.lenient(String.self, .alt)
        self.corner_radius = c.lenient(Double.self, .corner_radius)
        self.height = c.lenient(Double.self, .height)
        self.image_fit = c.lenient(String.self, .image_fit)
        self.image_frame = c.lenient(String.self, .image_frame)
        self.variant = c.lenient(String.self, .variant)
        self.action = c.lenient(String.self, .action)
        self.action_value = c.lenient(String.self, .action_value)
        self.bg_color = c.lenient(String.self, .bg_color)
        self.text_color = c.lenient(String.self, .text_color)
        self.button_corner_radius = c.lenient(Double.self, .button_corner_radius)
        self.audio_url = c.lenient(String.self, .audio_url)
        self.spacer_height = c.lenient(Double.self, .spacer_height)
        self.items = try c.decodeIfPresent([String].self, forKey: .items)
        self.list_style = c.lenient(String.self, .list_style)
        self.divider_color = c.lenient(String.self, .divider_color)
        self.divider_thickness = c.lenient(Double.self, .divider_thickness)
        self.divider_margin_y = c.lenient(Double.self, .divider_margin_y)
        self.badge_text = c.lenient(String.self, .badge_text)
        self.badge_bg_color = c.lenient(String.self, .badge_bg_color)
        self.badge_text_color = c.lenient(String.self, .badge_text_color)
        self.badge_corner_radius = c.lenient(Double.self, .badge_corner_radius)
        self.badge_position = c.lenient(String.self, .badge_position)
        self.badge_size = c.lenient(Double.self, .badge_size)
        self.image_shape = c.lenient(String.self, .image_shape)
        self.image_corner_radius = c.lenient(Double.self, .image_corner_radius)
        self.icon_emoji = c.lenient(String.self, .icon_emoji)
        self.icon_size = c.lenient(Double.self, .icon_size)
        self.icon_alignment = c.lenient(String.self, .icon_alignment)
        self.toggle_label = c.lenient(String.self, .toggle_label)
        self.toggle_description = c.lenient(String.self, .toggle_description)
        self.toggle_default = c.lenient(Bool.self, .toggle_default)
        self.video_url = c.lenient(String.self, .video_url)
        self.video_thumbnail_url = c.lenient(String.self, .video_thumbnail_url)
        self.video_height = c.lenient(Double.self, .video_height)
        self.video_corner_radius = c.lenient(Double.self, .video_corner_radius)
        self.autoplay = c.lenient(Bool.self, .autoplay)
        self.loop = c.lenient(Bool.self, .loop)
        self.muted = c.lenient(Bool.self, .muted)
        self.controls = c.lenient(Bool.self, .controls)
        self.video_autoplay = c.lenient(Bool.self, .video_autoplay)
        self.video_loop = c.lenient(Bool.self, .video_loop)
        self.video_muted = c.lenient(Bool.self, .video_muted)
        self.video_controls = c.lenient(Bool.self, .video_controls)
        self.lottie_url = c.lenient(String.self, .lottie_url)
        self.lottie_speed = c.lenient(Double.self, .lottie_speed)
        self.lottie_width = c.lenient(Double.self, .lottie_width)
        self.lottie_height = c.lenient(Double.self, .lottie_height)
        self.play_on_scroll = c.lenient(Bool.self, .play_on_scroll)
        self.play_on_tap = c.lenient(Bool.self, .play_on_tap)
        self.rive_url = c.lenient(String.self, .rive_url)
        self.artboard = c.lenient(String.self, .artboard)
        self.state_machine = c.lenient(String.self, .state_machine)
        self.trigger_on_step_complete = c.lenient(String.self, .trigger_on_step_complete)
        self.inputs = try c.decodeIfPresent([String: AnyCodable].self, forKey: .inputs)
        self.icon_ref = try c.decodeIfPresent(IconReference.self, forKey: .icon_ref)
        self.block_style = try c.decodeIfPresent(BlockStyle.self, forKey: .block_style)
        self.zone = c.lenient(String.self, .zone)
        self.vertical_align = c.lenient(String.self, .vertical_align)
        self.horizontal_align = c.lenient(String.self, .horizontal_align)
        self.vertical_offset = c.lenient(Double.self, .vertical_offset)
        self.horizontal_offset = c.lenient(Double.self, .horizontal_offset)
        self.dot_count = c.lenient(Int.self, .dot_count)
        self.active_index = c.lenient(Int.self, .active_index)
        self.active_color = c.lenient(String.self, .active_color)
        self.inactive_color = c.lenient(String.self, .inactive_color)
        self.dot_size = c.lenient(Double.self, .dot_size)
        self.dot_spacing = c.lenient(Double.self, .dot_spacing)
        self.active_dot_width = c.lenient(Double.self, .active_dot_width)
        self.dot_shape = c.lenient(String.self, .dot_shape)
        self.alignment = c.lenient(String.self, .alignment)
        self.providers = try c.decodeIfPresent([SocialProviderConfig].self, forKey: .providers)
        self.button_style = c.lenient(String.self, .button_style)
        self.button_height = c.lenient(Double.self, .button_height)
        self.spacing = c.lenient(Double.self, .spacing)
        self.show_divider = c.lenient(Bool.self, .show_divider)
        self.divider_text = c.lenient(String.self, .divider_text)
        self.divider_position = c.lenient(String.self, .divider_position)
        self.button_text_align = c.lenient(String.self, .button_text_align)
        self.email_login_placement = c.lenient(String.self, .email_login_placement)
        self.email_cta_spacing_below = c.lenient(Double.self, .email_cta_spacing_below)
        self.timer_variant = c.lenient(String.self, .timer_variant)
        self.duration_seconds = c.lenient(Int.self, .duration_seconds)
        self.target_type = c.lenient(String.self, .target_type)
        self.target_datetime = c.lenient(String.self, .target_datetime)
        self.show_days = c.lenient(Bool.self, .show_days)
        self.show_hours = c.lenient(Bool.self, .show_hours)
        self.show_minutes = c.lenient(Bool.self, .show_minutes)
        self.show_seconds = c.lenient(Bool.self, .show_seconds)
        self.labels = try c.decodeIfPresent(CountdownLabelsConfig.self, forKey: .labels)
        self.on_expire_action = c.lenient(String.self, .on_expire_action)
        self.expired_text = c.lenient(String.self, .expired_text)
        self.accent_color = c.lenient(String.self, .accent_color)
        self.font_size = c.lenient(Double.self, .font_size)
        self.max_stars = c.lenient(Int.self, .max_stars)
        self.default_rating = c.lenient(Double.self, .default_rating)
        self.star_size = c.lenient(Double.self, .star_size)
        self.filled_color = c.lenient(String.self, .filled_color)
        self.empty_color = c.lenient(String.self, .empty_color)
        self.allow_half = c.lenient(Bool.self, .allow_half)
        self.field_id = c.lenient(String.self, .field_id)
        self.rating_label = c.lenient(String.self, .rating_label)
        self.markdown_content = c.lenient(String.self, .markdown_content)
        self.rich_text_variant = c.lenient(String.self, .rich_text_variant)
        self.base_style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .base_style)
        self.link_color = c.lenient(String.self, .link_color)
        self.progress_variant = c.lenient(String.self, .progress_variant)
        self.progress_value = c.lenient(Double.self, .progress_value)
        self.total_segments = c.lenient(Int.self, .total_segments)
        self.filled_segments = c.lenient(Int.self, .filled_segments)
        self.bar_height = c.lenient(Double.self, .bar_height)
        self.bar_color = c.lenient(String.self, .bar_color)
        self.bar_gradient_colors = try c.decodeIfPresent([String].self, forKey: .bar_gradient_colors)
        self.track_color = c.lenient(String.self, .track_color)
        self.show_label = c.lenient(Bool.self, .show_label)
        self.segment_gap = c.lenient(Double.self, .segment_gap)
        self.label_format = c.lenient(String.self, .label_format)
        self.custom_label = c.lenient(String.self, .custom_label)
        self.label_placement = c.lenient(String.self, .label_placement)
        self.timeline_items = try c.decodeIfPresent([TimelineItemConfig].self, forKey: .timeline_items)
        self.line_color = c.lenient(String.self, .line_color)
        self.completed_color = c.lenient(String.self, .completed_color)
        self.current_color = c.lenient(String.self, .current_color)
        self.upcoming_color = c.lenient(String.self, .upcoming_color)
        self.show_line = c.lenient(Bool.self, .show_line)
        self.compact = c.lenient(Bool.self, .compact)
        self.title_style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .title_style)
        self.subtitle_style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .subtitle_style)
        self.loading_variant = c.lenient(String.self, .loading_variant)
        self.loading_text = c.lenient(String.self, .loading_text)
        self.loading_text_position = c.lenient(String.self, .loading_text_position)
        self.loading_text_size = c.lenient(Double.self, .loading_text_size)
        self.loading_text_color = c.lenient(String.self, .loading_text_color)
        self.loading_text_align = c.lenient(String.self, .loading_text_align)
        self.loading_items = try c.decodeIfPresent([LoadingItemConfig].self, forKey: .loading_items)
        self.gallery_images = try c.decodeIfPresent([String].self, forKey: .gallery_images)
        // The gallery's own header.
        self.gallery_title = try c.decodeIfPresent(String.self, forKey: .gallery_title)
        self.gallery_title_color = try c.decodeIfPresent(String.self, forKey: .gallery_title_color)
        self.gallery_item_width = c.lenient(Double.self, .gallery_item_width)
        self.gallery_item_height = c.lenient(Double.self, .gallery_item_height)
        self.gallery_corner_radius = c.lenient(Double.self, .gallery_corner_radius)
        self.gallery_spacing = c.lenient(Double.self, .gallery_spacing)
        self.gallery_align = c.lenient(String.self, .gallery_align)
        self.gallery_fill = c.lenient(Bool.self, .gallery_fill)
        self.gallery_autoscroll = c.lenient(Bool.self, .gallery_autoscroll)
        self.gallery_autoscroll_speed = c.lenient(Double.self, .gallery_autoscroll_speed)
        self.progress_color = c.lenient(String.self, .progress_color)
        self.check_color = c.lenient(String.self, .check_color)
        self.total_duration_ms = c.lenient(Int.self, .total_duration_ms)
        self.auto_advance = c.lenient(Bool.self, .auto_advance)
        self.show_percentage = c.lenient(Bool.self, .show_percentage)
        self.gauge_variant = c.lenient(String.self, .gauge_variant)
        self.gauge_value = c.lenient(Double.self, .gauge_value)
        self.max_value = c.lenient(Double.self, .max_value)
        self.sublabel = c.lenient(String.self, .sublabel)
        self.stroke_width = c.lenient(Double.self, .stroke_width)
        self.label_color = c.lenient(String.self, .label_color)
        self.label_font_size = c.lenient(Double.self, .label_font_size)
        self.min_label = c.lenient(String.self, .min_label)
        self.max_label = c.lenient(String.self, .max_label)
        self.min_max_font_size = c.lenient(Double.self, .min_max_font_size)
        self.min_max_color = c.lenient(String.self, .min_max_color)
        self.arrow_color = c.lenient(String.self, .arrow_color)
        self.arrow_stroke_width = c.lenient(Double.self, .arrow_stroke_width)
        self.percentage_location = c.lenient(String.self, .percentage_location)
        self.animate = c.lenient(Bool.self, .animate)
        self.animation_duration_ms = c.lenient(Int.self, .animation_duration_ms)
        self.columns = try c.decodeIfPresent([DateWheelColumnConfig].self, forKey: .columns)
        self.default_date_value = c.lenient(String.self, .default_date_value)
        self.min_date = c.lenient(String.self, .min_date)
        self.max_date = c.lenient(String.self, .max_date)
        self.allow_future = c.lenient(Bool.self, .allow_future)
        self.allow_past = c.lenient(Bool.self, .allow_past)
        self.date_validation_message = c.lenient(String.self, .date_validation_message)
        self.highlight_color = c.lenient(String.self, .highlight_color)
        self.orientation = c.lenient(String.self, .orientation)
        self.wheel_orientation = c.lenient(String.self, .wheel_orientation)
        self.picker_presentation = c.lenient(String.self, .picker_presentation)
        self.picker_mode = c.lenient(String.self, .picker_mode)
        self.time_format = c.lenient(String.self, .time_format)
        self.time_text_size = c.lenient(Double.self, .time_text_size)
        self.picker_spacing = c.lenient(Double.self, .picker_spacing)
        self.calendar_bg_color = c.lenient(String.self, .calendar_bg_color)
        self.wheel_bg_color = c.lenient(String.self, .wheel_bg_color)
        self.wheel_height = c.lenient(Double.self, .wheel_height)
        self.wheel_line_color = c.lenient(String.self, .wheel_line_color)
        self.wheel_line_stroke_width = c.lenient(Double.self, .wheel_line_stroke_width)
        self.haptic_on_scroll = c.lenient(Bool.self, .haptic_on_scroll)
        // A bad CHILD costs that child, not the row it sits in.
        self.children = try c.decodeLenientArray(ContentBlock.self, forKey: .children, in: "block.children")
        self.stack_children = try c.decodeLenientArray(ContentBlock.self, forKey: .stack_children, in: "block.stack_children")
        self.z_index = c.lenient(Double.self, .z_index)
        self.gap = c.lenient(Double.self, .gap)
        self.wrap = c.lenient(Bool.self, .wrap)
        self.align_items = c.lenient(String.self, .align_items)
        self.row_direction = c.lenient(String.self, .row_direction)
        self.column_ratios = c.lenient(String.self, .column_ratios)
        self.row_distribution = c.lenient(String.self, .row_distribution)
        self.row_child_fill = c.lenient(Bool.self, .row_child_fill)
        self.view_key = c.lenient(String.self, .view_key)
        self.custom_config = try c.decodeIfPresent([String: AnyCodable].self, forKey: .custom_config)
        self.placeholder_image_url = c.lenient(String.self, .placeholder_image_url)
        self.placeholder_text = c.lenient(String.self, .placeholder_text)
        self.particle_type = c.lenient(String.self, .particle_type)
        self.density = c.lenient(String.self, .density)
        self.speed = (try? c.decodeIfPresent(String.self, forKey: .speed)) ?? nil  // Tolerate a legacy numeric `speed` (old lottie blocks wrote a number here) rather than throwing on the whole block
        self.secondary_color = c.lenient(String.self, .secondary_color)
        self.size_range = try c.decodeIfPresent([Double].self, forKey: .size_range)
        self.fullscreen = c.lenient(Bool.self, .fullscreen)
        self.particle_color = c.lenient(String.self, .particle_color)
        self.particle_opacity = c.lenient(Double.self, .particle_opacity)
        self.particle_speed = c.lenient(String.self, .particle_speed)
        self.particle_multicolor = c.lenient(Bool.self, .particle_multicolor)
        self.min_value = c.lenient(Double.self, .min_value)
        self.max_value_picker = c.lenient(Double.self, .max_value_picker)
        self.step_value = c.lenient(Double.self, .step_value)
        self.default_picker_value = c.lenient(Double.self, .default_picker_value)
        // `try?`: top-level default_value is a number for wheel_picker, but tolerate a
        // stray non-number (e.g. an imported bool) without failing the whole block decode.
        self.default_value = (try? c.decodeIfPresent(Double.self, forKey: .default_value)) ?? nil
        self.unit = c.lenient(String.self, .unit)
        self.unit_position = c.lenient(String.self, .unit_position)
        self.visible_items = c.lenient(Int.self, .visible_items)
        self.pulse_color = c.lenient(String.self, .pulse_color)
        self.pulse_ring_count = c.lenient(Int.self, .pulse_ring_count)
        self.pulse_speed = c.lenient(Double.self, .pulse_speed)
        self.border_width = c.lenient(Double.self, .border_width)
        self.border_color = c.lenient(String.self, .border_color)
        self.pricing_plans = try c.decodeIfPresent([PricingPlanConfig].self, forKey: .pricing_plans)
        self.pricing_layout = c.lenient(String.self, .pricing_layout)
        self.field_label = c.lenient(String.self, .field_label)
        self.field_placeholder = c.lenient(String.self, .field_placeholder)
        self.field_required = c.lenient(Bool.self, .field_required)
        self.field_style = try c.decodeIfPresent(FormFieldBlockStyle.self, forKey: .field_style)
        self.field_options = try c.decodeIfPresent([InputOption].self, forKey: .field_options)
        self.multi_select = c.lenient(Bool.self, .multi_select)
        self.field_config = try c.decodeIfPresent([String: AnyCodable].self, forKey: .field_config)
        self.visibility_condition = try c.decodeIfPresent(VisibilityCondition.self, forKey: .visibility_condition)
        self.entrance_animation = try c.decodeIfPresent(EntranceAnimation.self, forKey: .entrance_animation)
        self.pressed_style = try c.decodeIfPresent(PressedStyle.self, forKey: .pressed_style)
        self.bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings)
        self.element_width = c.lenient(String.self, .element_width)
        self.element_height = c.lenient(String.self, .element_height)
        self.overflow = c.lenient(String.self, .overflow)
        self.collapse_on_scroll = c.lenient(Bool.self, .collapse_on_scroll)
        self.max_lines = c.lenient(Int.self, .max_lines)
    }
}

extension ContentBlock {
    /// What VoiceOver says for an image block: the console's "Alt text" (`alt`), trimmed, else "Image".
    /// One rule for every place an image block is drawn; Android's `ContentBlock.imageAccessibilityLabel`
    /// is the same, and `packages/sdk-shared-fixtures/dto_parsing/onboarding_image_alt.fixture.json` pins both.
    static let defaultImageAccessibilityLabel = "Image"

    var imageAccessibilityLabel: String {
        guard let t = alt?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return Self.defaultImageAccessibilityLabel
        }
        return t
    }
}
