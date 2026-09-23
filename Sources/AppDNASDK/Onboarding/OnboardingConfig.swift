import Foundation

// MARK: - Firestore schema types for onboarding flows

/// Root onboarding config from Firestore `/config/onboarding`.
struct OnboardingFlowRoot: Codable {
    let flows: [String: OnboardingFlowConfig]?
    let active_flow_id: String?
}

/// A single onboarding flow definition.
public struct OnboardingFlowConfig: Codable {
    public let id: String
    public let name: String?
    public let version: Int?
    private let _steps: [OnboardingStep]?
    private let _settings: OnboardingSettings?
    public let status: String?
    public let graph_layout: AnyCodable?
    /// Lightweight extract of SDK-relevant graph nodes (paywall_trigger, login, end).
    /// Keyed by node ID for O(1) lookup. Preferred over graph_layout for SDK use.
    public let graph_nodes: AnyCodable?
    public let audience_rules: AnyCodable?

    /// Non-optional steps for renderer compatibility
    public var steps: [OnboardingStep] { _steps ?? [] }
    /// Non-optional settings for renderer compatibility
    public var settings: OnboardingSettings { _settings ?? OnboardingSettings() }

    enum CodingKeys: String, CodingKey {
        case id, name, version, _steps = "steps", _settings = "settings"
        case status, graph_layout, graph_nodes, audience_rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
        self._steps = try c.decodeIfPresent([OnboardingStep].self, forKey: ._steps)
        self._settings = try c.decodeIfPresent(OnboardingSettings.self, forKey: ._settings)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.graph_layout = try c.decodeIfPresent(AnyCodable.self, forKey: .graph_layout)
        self.graph_nodes = try c.decodeIfPresent(AnyCodable.self, forKey: .graph_nodes)
        self.audience_rules = try c.decodeIfPresent(AnyCodable.self, forKey: .audience_rules)
    }

    /// Convenience memberwise init for tests and manual construction.
    public init(id: String = "", name: String? = nil, version: Int? = nil, steps: [OnboardingStep] = [], settings: OnboardingSettings = OnboardingSettings()) {
        self.id = id
        self.name = name
        self.version = version
        self._steps = steps
        self._settings = settings
        self.status = nil
        self.graph_layout = nil
        self.graph_nodes = nil
        self.audience_rules = nil
    }
}

/// Flow-level settings.
public struct BackButtonStyle: Codable {
    public let icon_size: CGFloat?
    public let icon_color: String?
    public let position: String?  // "left" | "right"
    // EPIC-2 — custom back glyph (any char, default SF chevron) + back-arrow⇄X switch
    // (close_on_first: show the dismiss "✕" in the leading slot on the first/no-history step).
    public let icon: String?
    public let close_on_first: Bool?
}

public struct OnboardingSettings: Codable {
    public let show_progress: Bool
    public let allow_back: Bool
    public let skip_to_step: String?
    public let progress_style: String?  // "dots" | "segmented_bar" | "continuous_bar" | "fraction" | "none"
    public let progress_color: String?
    public let progress_track_color: String?
    // EPIC-2 — thin sizing (custom height) + multiple colors at once (gradient).
    public let progress_height: CGFloat?
    public let progress_gradient_colors: [String]?
    // EPIC-2 — optional "Skip" link beside the progress bar.
    public let progress_skip_label: String?
    // EPIC-2 — dynamic color flash on step-advance (the progress fill briefly animates to this color).
    public let progress_flash_color: String?
    public let back_button_style: BackButtonStyle?
    public let dismiss_allowed: Bool?
    /// Global horizontal content padding in points. Default 24.
    public let content_padding: CGFloat?
    /// Global vertical spacing between content blocks in points. Default 12.
    public let block_spacing: CGFloat?
    /// Console-configured haptic feedback (mirrors Android `flow.settings.haptic`). iOS onboarding
    /// previously had no such field and fired no haptics, so a flow's haptic config was iOS-ignored.
    public let haptic: HapticConfig?

    public init(show_progress: Bool = true, allow_back: Bool = true, skip_to_step: String? = nil,
                progress_style: String? = nil, progress_color: String? = nil, progress_track_color: String? = nil,
                progress_height: CGFloat? = nil, progress_gradient_colors: [String]? = nil,
                progress_skip_label: String? = nil, progress_flash_color: String? = nil,
                back_button_style: BackButtonStyle? = nil, dismiss_allowed: Bool? = nil,
                content_padding: CGFloat? = nil, block_spacing: CGFloat? = nil, haptic: HapticConfig? = nil) {
        self.show_progress = show_progress
        self.allow_back = allow_back
        self.skip_to_step = skip_to_step
        self.progress_style = progress_style
        self.progress_color = progress_color
        self.progress_track_color = progress_track_color
        self.progress_height = progress_height
        self.progress_gradient_colors = progress_gradient_colors
        self.progress_skip_label = progress_skip_label
        self.progress_flash_color = progress_flash_color
        self.back_button_style = back_button_style
        self.dismiss_allowed = dismiss_allowed
        self.content_padding = content_padding
        self.block_spacing = block_spacing
        self.haptic = haptic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.show_progress = try c.decodeIfPresent(Bool.self, forKey: .show_progress) ?? true
        self.allow_back = try c.decodeIfPresent(Bool.self, forKey: .allow_back) ?? true
        self.skip_to_step = try c.decodeIfPresent(String.self, forKey: .skip_to_step)
        self.progress_style = try c.decodeIfPresent(String.self, forKey: .progress_style)
        self.progress_color = try c.decodeIfPresent(String.self, forKey: .progress_color)
        self.progress_track_color = try c.decodeIfPresent(String.self, forKey: .progress_track_color)
        self.progress_height = try c.decodeIfPresent(CGFloat.self, forKey: .progress_height)
        self.progress_gradient_colors = try c.decodeIfPresent([String].self, forKey: .progress_gradient_colors)
        self.progress_skip_label = try c.decodeIfPresent(String.self, forKey: .progress_skip_label)
        self.progress_flash_color = try c.decodeIfPresent(String.self, forKey: .progress_flash_color)
        self.back_button_style = try c.decodeIfPresent(BackButtonStyle.self, forKey: .back_button_style)
        self.dismiss_allowed = try c.decodeIfPresent(Bool.self, forKey: .dismiss_allowed)
        self.content_padding = try c.decodeIfPresent(CGFloat.self, forKey: .content_padding)
        self.block_spacing = try c.decodeIfPresent(CGFloat.self, forKey: .block_spacing)
        self.haptic = try c.decodeIfPresent(HapticConfig.self, forKey: .haptic)
    }

    enum CodingKeys: String, CodingKey {
        case show_progress, allow_back, skip_to_step, progress_style
        case progress_color, progress_track_color, progress_height, progress_gradient_colors, progress_skip_label, progress_flash_color, back_button_style, dismiss_allowed
        case content_padding, block_spacing, haptic
    }
}

/// A single step within a flow.
/// Next step rule for conditional routing.
public struct NextStepRule: Codable {
    public let condition: AnyCodable?  // "always" or {type: "answer_equals", ...} — backward compat
    public let conditions: [AnyCodable]?  // Array of conditions (preferred)
    public let logic: String?  // "and" | "or" — how to combine conditions
    public let target_step_id: String
}

/// A single step within a flow.
public struct OnboardingStep: Codable, Identifiable {
    public let id: String
    /// The step's authored name ("Screen path 1").
    ///
    /// Decoded solely so a cross-step `answer_key` can name its source step the way the console
    /// writes it. `mapStepsForFirestore` deep-clones the whole step, so this has always been on
    /// the wire — it was simply never decoded, and every name-keyed navigation rule silently
    /// resolved to nil as a result.
    public let name: String?
    public let type: StepType
    public let config: StepConfig
    public let hook: StepHookConfig?
    public let next_step_rules: [NextStepRule]?
    /// When true, the progress indicator is hidden on this step but the step still counts toward total progress.
    public let hide_progress: Bool?
    /// When true, the back button is hidden on this step (the step still counts toward total progress).
    public let hide_back: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, config, layout, hook, hide_progress, hide_back, content_blocks, next_step_rules
    }

    /// `hide_progress` / `hide_back` are authored per-step but the console publishes them INSIDE the
    /// step's `layout` object (verified against `OnboardingFlowConfigSyncService.mapStepsForFirestore`,
    /// which never hoists `layout.*` to the step root). Read them from `layout` with a step-root
    /// fallback for any older/hand-written config.
    private enum LayoutFlagKeys: String, CodingKey { case hide_progress, hide_back }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.type = try c.decodeIfPresent(StepType.self, forKey: .type) ?? .custom
        self.hook = try c.decodeIfPresent(StepHookConfig.self, forKey: .hook)
        // Step-root first (legacy path), then the layout object where the console actually writes them.
        let rootHideProgress = try c.decodeIfPresent(Bool.self, forKey: .hide_progress)
        let rootHideBack = try c.decodeIfPresent(Bool.self, forKey: .hide_back)
        var layoutHideProgress: Bool? = nil
        var layoutHideBack: Bool? = nil
        if let layoutFlags = try? c.nestedContainer(keyedBy: LayoutFlagKeys.self, forKey: .layout) {
            layoutHideProgress = try? layoutFlags.decodeIfPresent(Bool.self, forKey: .hide_progress)
            layoutHideBack = try? layoutFlags.decodeIfPresent(Bool.self, forKey: .hide_back)
        }
        self.hide_progress = rootHideProgress ?? layoutHideProgress
        self.hide_back = rootHideBack ?? layoutHideBack
        // Read next_step_rules from step level, but also check layout.next_step_rules
        // which may have richer conditions from the Logic panel
        let stepRules = try c.decodeIfPresent([NextStepRule].self, forKey: .next_step_rules)

        // Server writes step content as "layout" or "config" depending on source.
        // Also, content_blocks may be at step level. Try all locations.
        var decoded = try c.decodeIfPresent(StepConfig.self, forKey: .config)
            ?? c.decodeIfPresent(StepConfig.self, forKey: .layout)
            ?? StepConfig()

        // If content_blocks empty in config/layout, check step-level content_blocks.
        //
        // Assigned, not rebuilt. This was a 26-argument re-construction that forwarded every other
        // field by hand — the same shape as the `StepConfigOverrideMerger` bug, where exactly such a
        // rebuild forgot `chat_config` and silently deleted it. Adding a field to `StepConfig` must not
        // require remembering two unrelated places to copy it.
        if (decoded.content_blocks ?? []).isEmpty {
            if let stepBlocks = try c.decodeIfPresent([ContentBlock].self, forKey: .content_blocks), !stepBlocks.isEmpty {
                decoded.content_blocks = stepBlocks
            }
        }
        self.config = decoded
        self.next_step_rules = stepRules
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(config, forKey: .config)
        try c.encodeIfPresent(hook, forKey: .hook)
        try c.encodeIfPresent(hide_progress, forKey: .hide_progress)
        try c.encodeIfPresent(hide_back, forKey: .hide_back)
        try c.encodeIfPresent(next_step_rules, forKey: .next_step_rules)
    }

    public init(id: String = "", type: StepType = .custom, config: StepConfig = StepConfig(), hook: StepHookConfig? = nil, hide_progress: Bool? = nil, hide_back: Bool? = nil, next_step_rules: [NextStepRule]? = nil, name: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.config = config
        self.hook = hook
        self.hide_progress = hide_progress
        self.hide_back = hide_back
        self.next_step_rules = next_step_rules
    }

    public enum StepType: String, Codable, Equatable {
        case welcome
        case question
        case value_prop
        case custom
        case form
        case interactive_chat

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = StepType(rawValue: rawValue) ?? .custom
        }
    }
}

// MARK: - Step Hook Config (SPEC-083 P1)

/// Server-side webhook configuration for a step.
public struct StepHookConfig: Codable {
    public let enabled: Bool?
    public let webhook_url: String?
    public let timeout_ms: Int?
    public let loading_text: String?
    public let error_text: String?
    public let retry_count: Int?
    public let headers: [String: String]?
}

/// Step configuration — varies by step type.
/// The authored content of one onboarding step.
///
/// The fields are `var`, not `let`, and that is load-bearing: `StepConfigOverrideMerger` used to apply
/// a host override by REBUILDING this struct field-by-field through the memberwise init, and it forgot
/// `chat_config`. A rebuild that forgets a field does not fail — it silently DELETES it. Overrides are
/// applied by copying this value and assigning the two or three fields the override actually names, so
/// a field nobody remembered survives by construction.
public struct StepConfig: Codable {
    // welcome
    public var title: String?
    public var subtitle: String?
    public var image_url: String?
    public var cta_text: String?
    public var skip_enabled: Bool?

    // question
    public var options: [QuestionOption]?
    public var selection_mode: SelectionMode?

    // value_prop
    public var items: [ValuePropItem]?

    // custom
    public var layout: [String: AnyCodable]?

    // form (SPEC-082)
    public var fields: [FormField]?
    public var validation_mode: String?  // "on_submit" or "realtime"

    // SPEC-083: Populated by applyOverrides from StepConfigOverride.fieldDefaults
    public var field_defaults: [String: AnyCodable]?

    // SPEC-090: Interactive chat
    public var chat_config: ChatConfig?

    // SPEC-084: Content blocks (block-based step rendering)
    public var content_blocks: [ContentBlock]?
    public var layout_variant: String?   // image_top, image_bottom, image_fullscreen, image_split, no_image
    public var background: BackgroundStyleConfig?
    public var text_style: TextStyleConfig?
    public var element_style: ElementStyleConfig?
    public var animation: AnimationConfig?
    public var localizations: [String: [String: String]]?
    public var default_locale: String?
    // Navigation rules from layout (may have Logic panel conditions)
    public var next_step_rules: [NextStepRule]?
    // Per-step progress bar color override (overrides flow.settings.progress_color)
    public var progress_color: String?

    // SPEC-421 — permission-step contract. The console serializer writes these at the
    // step-content TOP LEVEL (siblings of `content_blocks`), NOT under the inner `layout`
    // sub-map. They were previously only read from `layout[...]` → resolved to nil → every
    // authored permission step emitted `permission_unavailable` and advanced without prompting.
    // Decode them as first-class fields here; the renderer prefers these, falling back to the
    // inner `layout` map only for safety.
    public var permission_type: String?
    public var show_settings_fallback_on_denied: Bool?
    public var settings_fallback_label: String?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, image_url, cta_text, skip_enabled
        case options, selection_mode, items, layout, next_step_rules
        case fields, validation_mode, field_defaults
        case chat_config
        case content_blocks, layout_variant, background
        case text_style, element_style, animation
        case localizations, default_locale
        case progress_color
        case permission_type, show_settings_fallback_on_denied, settings_fallback_label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        image_url = try c.decodeIfPresent(String.self, forKey: .image_url)
        cta_text = try c.decodeIfPresent(String.self, forKey: .cta_text)
        skip_enabled = try c.decodeIfPresent(Bool.self, forKey: .skip_enabled)
        options = try c.decodeIfPresent([QuestionOption].self, forKey: .options)
        selection_mode = try c.decodeIfPresent(SelectionMode.self, forKey: .selection_mode)
        items = try c.decodeIfPresent([ValuePropItem].self, forKey: .items)
        layout = try c.decodeIfPresent([String: AnyCodable].self, forKey: .layout)
        fields = try c.decodeIfPresent([FormField].self, forKey: .fields)
        validation_mode = try c.decodeIfPresent(String.self, forKey: .validation_mode)
        field_defaults = nil  // Never from JSON; only set via applyOverrides
        chat_config = try c.decodeIfPresent(ChatConfig.self, forKey: .chat_config)
        content_blocks = try c.decodeIfPresent([ContentBlock].self, forKey: .content_blocks)
        layout_variant = try c.decodeIfPresent(String.self, forKey: .layout_variant)
        background = try c.decodeIfPresent(BackgroundStyleConfig.self, forKey: .background)
        text_style = try c.decodeIfPresent(TextStyleConfig.self, forKey: .text_style)
        element_style = try c.decodeIfPresent(ElementStyleConfig.self, forKey: .element_style)
        animation = try c.decodeIfPresent(AnimationConfig.self, forKey: .animation)
        localizations = try c.decodeIfPresent([String: [String: String]].self, forKey: .localizations)
        default_locale = try c.decodeIfPresent(String.self, forKey: .default_locale)
        next_step_rules = try c.decodeIfPresent([NextStepRule].self, forKey: .next_step_rules)
        progress_color = try c.decodeIfPresent(String.self, forKey: .progress_color)
        // SPEC-421 — decoded from the SAME top-level container as content_blocks (console siblings).
        permission_type = try c.decodeIfPresent(String.self, forKey: .permission_type)
        show_settings_fallback_on_denied = try c.decodeIfPresent(Bool.self, forKey: .show_settings_fallback_on_denied)
        settings_fallback_label = try c.decodeIfPresent(String.self, forKey: .settings_fallback_label)
    }

    // Public memberwise init used by applyOverrides and default construction
    public init(
        title: String? = nil, subtitle: String? = nil, image_url: String? = nil,
        cta_text: String? = nil, skip_enabled: Bool? = nil,
        options: [QuestionOption]? = nil, selection_mode: SelectionMode? = nil,
        items: [ValuePropItem]? = nil, layout: [String: AnyCodable]? = nil,
        fields: [FormField]? = nil, validation_mode: String? = nil,
        field_defaults: [String: AnyCodable]? = nil,
        chat_config: ChatConfig? = nil,
        content_blocks: [ContentBlock]? = nil, layout_variant: String? = nil,
        background: BackgroundStyleConfig? = nil, text_style: TextStyleConfig? = nil,
        element_style: ElementStyleConfig? = nil, animation: AnimationConfig? = nil,
        localizations: [String: [String: String]]? = nil, default_locale: String? = nil,
        next_step_rules: [NextStepRule]? = nil,
        progress_color: String? = nil,
        permission_type: String? = nil,
        show_settings_fallback_on_denied: Bool? = nil,
        settings_fallback_label: String? = nil
    ) {
        self.title = title; self.subtitle = subtitle; self.image_url = image_url
        self.cta_text = cta_text; self.skip_enabled = skip_enabled
        self.options = options; self.selection_mode = selection_mode
        self.items = items; self.layout = layout
        self.fields = fields; self.validation_mode = validation_mode
        self.field_defaults = field_defaults; self.chat_config = chat_config
        self.content_blocks = content_blocks; self.layout_variant = layout_variant
        self.background = background; self.text_style = text_style
        self.element_style = element_style; self.animation = animation
        self.localizations = localizations; self.default_locale = default_locale
        self.next_step_rules = next_step_rules
        self.progress_color = progress_color
        self.permission_type = permission_type
        self.show_settings_fallback_on_denied = show_settings_fallback_on_denied
        self.settings_fallback_label = settings_fallback_label
    }
}

public struct QuestionOption: Codable, Identifiable {
    public let id: String?
    public let label: String?
    public let icon: String?
    public let subtitle: String?
}

public enum SelectionMode: String, Codable {
    case single
    case multi

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = SelectionMode(rawValue: rawValue) ?? .single
    }
}

public struct ValuePropItem: Codable, Identifiable {
    public let icon: String?
    public let title: String?
    public let subtitle: String?

    public var id: String { title ?? UUID().uuidString }
}

// MARK: - Form Field Types (SPEC-082)

public enum FormFieldType: String, Codable {
    case text, textarea, number, email, phone
    // SPEC-401-A: previously-missing types now first-class on iOS so the
    // dispatch in `FormStepView.fieldControl(_:)` matches Android (which
    // already renders all 22 of these). The schema source-of-truth is
    // `flow.schema.ts FORM_FIELD_TYPES`.
    case password
    case url
    case date, time, datetime
    case select, slider, toggle, stepper, segmented
    case location
    case rating
    case range_slider
    case image_picker
    case color
    case multiline_chips
    case signature

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = FormFieldType(rawValue: rawValue) ?? .text
    }
}

public struct FormFieldOption: Codable, Identifiable {
    public let id: String?
    public let label: String?
    public let icon: String?
    public let value: AnyCodable?
}

public struct FormFieldValidation: Codable {
    public let pattern: String?
    public let pattern_message: String?
}

public struct FormFieldDependency: Codable {
    public let field_id: String?
    public let operator_type: String?  // equals, not_equals, contains, not_empty, empty, gt, lt, is_set
    public let value: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case field_id
        case operator_type = "operator"
        case value
    }
}

public struct FormFieldConfig: Codable {
    public let max_length: Int?
    public let min_length: Int?
    public let keyboard_type: String?
    public let autocapitalize: String?
    public let autocorrect: Bool?
    public let multiline_min_lines: Int?
    public let min_value: Double?
    public let max_value: Double?
    public let step: Double?
    public let unit: String?
    public let decimal_places: Int?
    public let min_date: String?
    public let max_date: String?
    public let date_format: String?
    public let picker_style: String?
    public let search_enabled: Bool?
    public let multi_select: Bool?
    public let max_selections: Int?
    public let default_value: AnyCodable?
    // Location (SPEC-089)
    public let location_type: String?
    public let location_bias_country: String?
    public let location_language: String?
    public let location_placeholder: String?
    public let location_min_chars: Int?
    // SPEC-401-A: rating
    public let max_stars: Int?
    public let allow_half: Bool?
    public let star_size: Int?
    public let filled_color: String?
    public let empty_color: String?
    // SPEC-401-A: range_slider
    public let min_label: String?
    public let max_label: String?
    // SPEC-401-A: image_picker
    public let max_size_mb: Double?
    public let allowed_types: String?
    public let aspect_ratio: String?
    public let placeholder_text: String?
    // SPEC-401-A: color picker
    public let default_color: String?
    public let show_opacity: Bool?
    public let preset_colors: [String]?
    // SPEC-401-A: url
    public let validate_format: Bool?
    // SPEC-401-A: multiline_chips
    public let max_chips: Int?
    public let suggestions: [String]?
    public let allow_custom: Bool?
    // SPEC-401-A: signature
    public let stroke_color: String?
    public let stroke_width: Double?
    public let clear_button_text: String?
}

/// SPEC-401-A — per-field style envelope mirroring `FormFieldStyleSchema`
/// in `flow.schema.ts:101-109` and the Android `FormFieldStyle` data
/// class. Authors set these in the console; the renderer applies them
/// to the equivalent SwiftUI controls (Toggle.tint, TextField overlay
/// border, corner_radius). The free-form sub-maps `label_style`,
/// `input_style`, `error_style` are untyped because the schema treats
/// them as opaque records — authors can pass any sub-keys.
public struct FormFieldStyle: Codable {
    public let label_style: AnyCodable?
    public let input_style: AnyCodable?
    public let error_style: AnyCodable?
    public let corner_radius: Double?
    public let border_color: String?
    public let focus_border_color: String?
    public let background_color: String?
}

public struct FormField: Codable, Identifiable {
    public let id: String
    public let type: FormFieldType
    public let label: String
    public let placeholder: String?
    public let required: Bool
    public let validation: FormFieldValidation?
    public let options: [FormFieldOption]?
    public let config: FormFieldConfig?
    /// #596 — the SAME `config` object, kept raw.
    ///
    /// `FormFieldConfig` is a typed struct, so every key it does not declare is dropped at decode.
    /// The console's Select field offers six display styles and roughly twenty option-styling keys;
    /// none of them are declared here, so `display_style: "image_tiles"` never survived parsing and
    /// the field always fell through to a `.menu` Picker — "a small list, only visible when
    /// press-and-holding the label", as reported.
    ///
    /// Keeping the raw dict lets a form Select render through the same engine the `input_select`
    /// CONTENT block uses, rather than growing a second implementation of six layouts that would
    /// diverge from the first.
    public let config_raw: [String: AnyCodable]?
    public let depends_on: FormFieldDependency?
    public let style: FormFieldStyle?

    private enum CodingKeys: String, CodingKey {
        case id, type, label, placeholder, required, validation, options, config, depends_on, style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.type = try c.decodeIfPresent(FormFieldType.self, forKey: .type) ?? .text
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        // Decoded from the same key as `config`; `try?` so a shape the typed struct rejects costs
        // the raw copy only, never the field.
        self.config_raw = try? c.decodeIfPresent([String: AnyCodable].self, forKey: .config)
        self.validation = try c.decodeIfPresent(FormFieldValidation.self, forKey: .validation)
        self.options = try c.decodeIfPresent([FormFieldOption].self, forKey: .options)
        self.config = try c.decodeIfPresent(FormFieldConfig.self, forKey: .config)
        self.depends_on = try c.decodeIfPresent(FormFieldDependency.self, forKey: .depends_on)
        self.style = try c.decodeIfPresent(FormFieldStyle.self, forKey: .style)
    }
}

// MARK: - Async Step Hook Types (SPEC-083)

/// Result of the async step hook called before advancing.
public enum StepAdvanceResult {
    /// Continue to next step normally.
    case proceed

    /// Continue to next step, merging additional data into responses.
    case proceedWithData([String: Any])

    /// Block advancement. Stay on current step and display error message.
    case block(message: String)

    /// Skip to a specific step by ID (override next_step_rules).
    case skipTo(stepId: String)

    /// Skip to a specific step, merging data.
    case skipToWithData(stepId: String, data: [String: Any])

    /// Stay on the current step without advancing and without showing an error.
    /// Use this when your hook handled the user's action (e.g., sent a password
    /// reset email, displayed a success popup yourself) and you want the user to
    /// remain on the same step.
    ///
    /// - Parameter message: Optional non-error message to display as a success
    ///   toast/banner. Pass `nil` to stay silently — your code handles all UI.
    ///   Pass a non-empty string and the SDK renders it in success styling
    ///   (distinct from `.block`'s error styling).
    case stay(message: String? = nil)
}

/// Optional config override for dynamic step content.
public struct StepConfigOverride {
    /// Override field values (for form steps — pre-fill fields).
    public var fieldDefaults: [String: Any]?

    /// Override title text.
    public var title: String?

    /// Override subtitle text.
    public var subtitle: String?

    /// Override CTA text.
    public var ctaText: String?

    /// SPEC-448 §B — options supplied by the HOST APP, keyed by block id.
    ///
    /// The app reads its own backend with its own client, auth and cache, and hands the list over.
    /// No network, no credentials and no retry semantics inside this SDK — which is the point:
    /// a customer whose list lives behind their own auth cannot be served by our fetcher.
    ///
    /// `[blockId: [InputOption]]`. A block not named here keeps its authored options.
    public var fieldOptions: [String: [InputOption]]?

    /// SPEC-452 — the host's data for THIS step, addressable from the console as `{{hook_data.…}}`.
    ///
    /// This is not another override: nothing here replaces a field. It is a read-only namespace the
    /// renderer's existing resolver reads, so the AUTHOR decides what is dynamic (by typing
    /// `{{hook_data.tour.price}}` in the console, or setting a block `binding` to `hook_data.…`) and
    /// the host only supplies the values. That is why it is not the `layoutOverrides` mistake
    /// documented below — an unbounded bag that can overwrite any part of a step. The reachable
    /// surface is exactly the resolver's whitelist, and a path no author referenced does nothing.
    ///
    /// It exists because a screen that must show live data ON ARRIVAL — a recommendation card, a
    /// booking summary, an audio preview — has no interaction to trigger
    /// `ElementInteractionResult.fieldConfigPatches`, which fires only after a tap. `hook_data` was
    /// designed for this (it is one of the six roots `resolveDotPath` accepts) and had no producer:
    /// every `{{hook_data.x}}` in every flow resolved to nothing on both platforms.
    ///
    /// Values are plain JSON-ish (`String`, number, `Bool`, arrays, nested dictionaries); paths walk
    /// dictionaries and index arrays, so `hook_data.recommendations.0.imageUrl` works.
    public var dataContext: [String: Any]?

    /// SPEC-448 §B — `layoutOverrides` was REMOVED here.
    ///
    /// It was declared on all four SDKs and bridged by the wrappers, and no renderer ever read it:
    /// a host could set it and nothing happened. Making it work was the wrong fix — a bag that can
    /// overwrite any part of a step is unbounded, untestable, and a promise we would have to keep
    /// forever. `fieldOptions` gives the one real use case a typed home instead.
    ///
    /// Removing a public field is normally breaking; here nothing ever read it, so no host can
    /// depend on its behaviour.
    /// SPEC-451 — the route a `map` block draws, supplied by the HOST APP, keyed by block id.
    ///
    /// The third and last route source, and the only one that can answer "where is this delivery
    /// right now": authored stops are fixed at publish time, and a template variable can only carry
    /// what the flow already knows. The app calls its own routing service with its own client and
    /// hands the result over. No network, no credentials and no map-provider SDK inside ours.
    ///
    /// Typed rather than a free-form `field_config` patch on purpose — see the `layoutOverrides`
    /// note above. A route has a shape, so it gets a type.
    ///
    /// `[blockId: MapRouteOverride]`. A block not named here keeps its authored route.
    public var mapRoutes: [String: MapRouteOverride]?

    public init(
        fieldDefaults: [String: Any]? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        ctaText: String? = nil,
        fieldOptions: [String: [InputOption]]? = nil,
        dataContext: [String: Any]? = nil,
        mapRoutes: [String: MapRouteOverride]? = nil
    ) {
        self.fieldDefaults = fieldDefaults
        self.title = title
        self.subtitle = subtitle
        self.ctaText = ctaText
        self.fieldOptions = fieldOptions
        self.dataContext = dataContext
        self.mapRoutes = mapRoutes
    }

    /// SPEC-451 — the one public way to turn a wrapper bridge's raw `[blockId: [polyline, stops]]`
    /// into typed route overrides.
    ///
    /// Public and in the core for the same reason `decodeFieldOptions` is: a second decoder written
    /// inside a wrapper would compile happily while quietly diverging from this one.
    ///
    /// Returns nil for anything unusable, so a malformed bridge payload leaves the block's authored
    /// route standing rather than blanking the map.
    public static func decodeMapRoutes(_ raw: Any?) -> [String: MapRouteOverride]? {
        guard let byBlock = raw as? [String: Any] else { return nil }
        var out: [String: MapRouteOverride] = [:]
        for (blockId, value) in byBlock {
            guard let route = value as? [String: Any] else { continue }
            let stops: [MapRouteStop] = ((route["stops"] as? [Any]) ?? []).compactMap { s in
                guard let stop = s as? [String: Any] else { return nil }
                let lat = (stop["lat"] as? Double) ?? (stop["lat"] as? Int).map(Double.init)
                let lng = (stop["lng"] as? Double) ?? (stop["lng"] as? Int).map(Double.init)
                guard let la = lat, let ln = lng, la.isFinite, ln.isFinite else { return nil }
                return MapRouteStop(lat: la, lng: ln, title: stop["title"] as? String)
            }
            let polyline = (route["polyline"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Neither a line nor a place is not a route — drop it rather than blanking the map.
            if polyline == nil && stops.isEmpty { continue }
            out[blockId] = MapRouteOverride(polyline: polyline, stops: stops)
        }
        return out.isEmpty ? nil : out
    }
}

/// SPEC-451 — a route handed to a `map` block at runtime.
///
/// `polyline` is Google's encoded-polyline format, which is what every routing service returns and
/// what Mapbox's `path` overlay takes. Supplying it draws the real road geometry; supplying only
/// `stops` draws straight lines between them. Both together is the normal case: the line follows
/// the roads and the pins mark the stops.
public struct MapRouteOverride {
    public let polyline: String?
    public let stops: [MapRouteStop]

    public init(polyline: String? = nil, stops: [MapRouteStop] = []) {
        self.polyline = polyline
        self.stops = stops
    }
}

/// One point on a host-supplied route.
public struct MapRouteStop {
    public let lat: Double
    public let lng: Double
    public let title: String?

    public init(lat: Double, lng: Double, title: String? = nil) {
        self.lat = lat
        self.lng = lng
        self.title = title
    }
}

// MARK: - Element interaction (SPEC-419 EPIC-11 — backend-interactive elements)

/// Result of `onElementInteraction` — lets the host push state back into the live step from its backend
/// (e.g. user taps a calendar day → backend confirms → update the rendered element without leaving the step).
public struct ElementInteractionResult {
    /// Per-block `field_config` patches to merge + re-render. Keyed by blockId → (key → value).
    public var fieldConfigPatches: [String: [String: Any]]?
    /// Patches to merge into the step's `inputValues` (keyed by field_id).
    public var inputValuePatches: [String: Any]?
    /// #657 — replacement options, keyed by blockId. The same shape `StepConfigOverride.fieldOptions`
    /// takes at render time.
    ///
    /// Without this the refresh action could not change the thing it exists to change: a select's
    /// options live in `block.field_options`, and `fieldConfigPatches` merges into `field_config` —
    /// a different field the renderer never reads for options. A "Show 4 more" button could fire the
    /// hook and then have nothing to hand back.
    public var fieldOptions: [String: [InputOption]]?
    /// When true, advance to the next step after handling this interaction.
    public var advance: Bool

    public init(
        fieldConfigPatches: [String: [String: Any]]? = nil,
        inputValuePatches: [String: Any]? = nil,
        fieldOptions: [String: [InputOption]]? = nil,
        advance: Bool = false
    ) {
        self.fieldConfigPatches = fieldConfigPatches
        self.inputValuePatches = inputValuePatches
        self.fieldOptions = fieldOptions
        self.advance = advance
    }
}

/// The merged result of applying an `ElementInteractionResult` to a step's live state.
public struct AppliedInteraction {
    public let inputValues: [String: Any]
    public let fieldConfigOverrides: [String: [String: Any]]
    /// #657 — per-block replacement options the renderer layers at read time, like the config
    /// overrides beside it.
    public let fieldOptionsOverrides: [String: [InputOption]]
    public let advance: Bool
}

/// SPEC-419 EPIC-11 — pure application of an `ElementInteractionResult` to a step's live state. Merges
/// `inputValuePatches` over `inputValues` and exposes per-block `fieldConfigPatches` as overrides the renderer
/// layers at READ TIME (ContentBlock is immutable — the override layer keeps Android/iOS at parity). The caller
/// acts on `AppliedInteraction.advance`. Pure + unit-tested.
public func applyInteractionResult(_ result: ElementInteractionResult, inputValues: [String: Any]) -> AppliedInteraction {
    var iv = inputValues
    if let patches = result.inputValuePatches {
        for (k, v) in patches { iv[k] = v }
    }
    return AppliedInteraction(
        inputValues: iv,
        fieldConfigOverrides: result.fieldConfigPatches ?? [:],
        fieldOptionsOverrides: result.fieldOptions ?? [:],
        advance: result.advance
    )
}

// MARK: - Permission handling (SPEC-421)

/// SPEC-421 — optional host override for an onboarding permission step. Returned from
/// `onPermissionRequest`. `.handledByHost` means the host already resolved the permission
/// (or wants to inject a result) — the SDK writes the result + emits analytics uniformly and
/// does NOT show the OS prompt. `.proceed` (or `nil`) lets the SDK run the native OS flow.
public enum PermissionHandling: Equatable {
    case proceed
    case handledByHost(granted: Bool)
}

// MARK: - Delegate protocol

/// Delegate for receiving onboarding flow lifecycle events.
public protocol AppDNAOnboardingDelegate: AnyObject {
    // Observe-only callbacks (unchanged)
    func onOnboardingStarted(flowId: String)
    func onOnboardingStepChanged(flowId: String, stepId: String, stepIndex: Int, totalSteps: Int)
    func onOnboardingCompleted(flowId: String, responses: [String: Any])
    func onOnboardingDismissed(flowId: String, atStep: Int)

    // SPEC-083: Async hook called BEFORE advancing from a step.
    func onBeforeStepAdvance(
        flowId: String,
        fromStepId: String,
        stepIndex: Int,
        stepType: String,
        responses: [String: Any],
        stepData: [String: Any]?
    ) async -> StepAdvanceResult

    // SPEC-083: Optional hook to modify step config before rendering.
    func onBeforeStepRender(
        flowId: String,
        stepId: String,
        stepIndex: Int,
        stepType: String,
        responses: [String: Any]
    ) async -> StepConfigOverride?

    // SPEC-419 EPIC-11: Async hook fired DURING render when an interactive element acts (calendar day tap,
    // otp digit, memory flip, dark-mode toggle, health connect…). Return a result to push backend state into
    // the live step. `blockId`/`action`/`value` identify the interaction; `inputValues` is the live snapshot.
    func onElementInteraction(
        flowId: String,
        stepId: String,
        blockId: String,
        action: String,
        value: String?,
        inputValues: [String: Any]
    ) async -> ElementInteractionResult?

    // SPEC-421: Runtime permission hooks for onboarding permission steps.
    // Optional pre-hook — return `.handledByHost(granted:)` to short-circuit the OS prompt,
    // or `.proceed`/`nil` to let the SDK run the native flow.
    func onPermissionRequest(_ permissionType: String) async -> PermissionHandling?
    // Observe-only result callback after the permission is resolved (host, status, or prompt).
    func onPermissionResult(flowId: String, stepId: String, permissionType: String, granted: Bool)
}

/// Default empty implementations so delegates can be partial.
public extension AppDNAOnboardingDelegate {
    func onOnboardingStarted(flowId: String) {}
    func onOnboardingStepChanged(flowId: String, stepId: String, stepIndex: Int, totalSteps: Int) {}
    func onOnboardingCompleted(flowId: String, responses: [String: Any]) {}
    func onOnboardingDismissed(flowId: String, atStep: Int) {}

    func onBeforeStepAdvance(
        flowId: String,
        fromStepId: String,
        stepIndex: Int,
        stepType: String,
        responses: [String: Any],
        stepData: [String: Any]?
    ) async -> StepAdvanceResult {
        return .proceed
    }

    func onBeforeStepRender(
        flowId: String,
        stepId: String,
        stepIndex: Int,
        stepType: String,
        responses: [String: Any]
    ) async -> StepConfigOverride? {
        return nil
    }

    func onElementInteraction(
        flowId: String,
        stepId: String,
        blockId: String,
        action: String,
        value: String?,
        inputValues: [String: Any]
    ) async -> ElementInteractionResult? {
        return nil
    }

    // SPEC-421 defaults: no host handling, observe-only result is a no-op.
    func onPermissionRequest(_ permissionType: String) async -> PermissionHandling? { nil }
    func onPermissionResult(flowId: String, stepId: String, permissionType: String, granted: Bool) {}
}
