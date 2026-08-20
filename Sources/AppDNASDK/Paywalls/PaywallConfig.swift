import Foundation

/// Codable structs matching SPEC-002 Firestore PaywallConfig schema.
struct PaywallConfig: Codable {
    let id: String?
    let name: String?
    let layout: PaywallLayout?
    private let _sections: [PaywallSection]?
    let plans: [PaywallPlan]?
    let cta: PaywallCTA?
    let dismiss: PaywallDismiss?
    let background: PaywallBackground?
    let placement: String?
    let placement_label: String?
    let version: Int?
    // SPEC-084: Design tokens
    let animation: AnimationConfig?
    let localizations: [String: [String: String]]?
    let default_locale: String?
    // SPEC-085: Rich media
    let haptic: HapticConfig?
    let particle_effect: ParticleEffect?
    // Post-purchase actions
    let post_purchase: PostPurchaseConfig?
    // Audience-based targeting
    let audience_rules: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, layout, _sections = "sections", plans, cta, dismiss, background
        case placement, placement_label, version
        case animation = "animation_config"
        case localizations, default_locale
        case haptic, particle_effect, post_purchase
        case audience_rules
    }

    /// Sections resolved from top-level or inside layout (non-optional for renderer compat)
    var sections: [PaywallSection] {
        _sections ?? layout?.sections ?? []
    }
}

struct PaywallLayout: Codable {
    let type: String? // "stack", "grid", "carousel"
    let spacing: CGFloat?
    let padding: CGFloat?
    let footer_padding: CGFloat?  // Bottom padding for CTA/footer zone (default 8)
    let sections: [PaywallSection]?
    let background: PaywallBackground?
    let global_style: AnyCodable?
    /// One of 12 plan display styles: vertical_stack, horizontal_scroll, radio_list, pill_selector,
    /// segmented_toggle, comparison_cards, feature_matrix, pricing_table, timeline, tier_ladder,
    /// interactive_slider, mini_cards. Falls back to `type` mapping when nil.
    let plan_display_style: String?
}

struct PaywallSection: Codable {
    let _type: String?
    let id: String?
    private let _data: PaywallSectionData?
    private let _config: PaywallSectionData?
    // SPEC-084: Per-section styling
    let style: SectionStyleConfig?
    /// When true, this section fades out and collapses to 0 height as the user scrolls.
    let collapse_on_scroll: Bool?

    /// Non-optional accessor defaulting to "unknown" when Firestore omits the field.
    var type: String { _type ?? "unknown" }

    /// Section data — server writes as "config", SDK historically used "data". Accept both.
    var data: PaywallSectionData? { _data ?? _config }

    enum CodingKeys: String, CodingKey {
        case _type = "type"
        case id
        case _data = "data"
        case _config = "config"
        case style
        case collapse_on_scroll
    }
}

struct PaywallSectionData: Codable {
    // Header
    let title: String?
    let subtitle: String?
    let imageUrl: String?
    /// Header graphic alignment: "leading" | "center" (default) | "trailing".
    let imageAlignment: String?
    /// Max height for the header graphic (default 200).
    let imageMaxHeight: CGFloat?
    let title_style: TextStyleConfig?
    let subtitle_style: TextStyleConfig?

    // Features
    let features: [String]?

    // Plans
    let plans: [PaywallPlan]?

    // CTA
    let cta: PaywallCTA?

    // Social proof
    let rating: Double?
    let reviewCount: Int?
    let testimonial: String?
    let subType: String?       // "app_rating", "countdown", "trial_badge"
    let countdownSeconds: Int?
    let text: String?
    let restoreText: String?        // CTA section: restore purchase text
    let showRestore: Bool?          // CTA section: show restore button
    let restorePosition: String?    // CTA section: "above" | "below" (default: "below")
    let restoreTextColor: String?   // CTA section: restore link text color (hex)
    let restoreFontSize: Double?    // CTA section: restore link font size

    // Guarantee
    let guaranteeText: String?

    // Image section
    let height: CGFloat?
    let cornerRadius: CGFloat?

    // Spacer section
    let spacerHeight: CGFloat?

    // Testimonial section
    let quote: String?
    let authorName: String?
    let authorRole: String?
    let avatarUrl: String?

    // SPEC-085: Rich media in paywall sections
    let lottieUrl: String?
    let lottieLoop: Bool?
    let lottieSpeed: Double?
    let lottieHeight: CGFloat?
    let videoUrl: String?
    let videoThumbnailUrl: String?
    let videoHeight: CGFloat?
    let riveUrl: String?
    let riveStateMachine: String?

    // SPEC-089d: Countdown section
    let variant: String?           // digital | circular | flip | bar
    let durationSeconds: Int?
    let targetDatetime: String?
    let showDays: Bool?
    let showHours: Bool?
    let showMinutes: Bool?
    let showSeconds: Bool?
    let labels: [String: String]?
    let onExpireAction: String?    // hide | show_expired_text | auto_advance
    let expiredText: String?
    let accentColor: String?
    let backgroundColor: String?
    let fontSize: CGFloat?
    let alignment: String?

    // SPEC-089d: Legal section
    let color: String?
    let links: [PaywallLink]?

    // SPEC-089d: Divider section
    let thickness: CGFloat?
    let lineStyle: String?         // solid | dashed | dotted
    let marginTop: CGFloat?
    let marginBottom: CGFloat?
    let marginHorizontal: CGFloat?
    let labelText: String?
    let labelColor: String?
    let labelBgColor: String?
    let labelFontSize: CGFloat?

    // SPEC-089d: Sticky footer section
    let ctaText: String?
    let ctaBgColor: String?
    let ctaTextColor: String?
    let ctaCornerRadius: CGFloat?
    let ctaHeight: CGFloat?
    let ctaFontSize: CGFloat?
    /// CTA text font weight (console "Font Weight" = cta_font_weight): normal | medium | semibold | bold.
    /// Applied only when no Style-tab button text_style weight is set. Parity with Android + the preview.
    let ctaFontWeight: String?
    let secondaryText: String?
    let secondaryAction: String?   // restore | link
    let secondaryUrl: String?
    let legalText: String?
    let blurBackground: Bool?
    let padding: CGFloat?

    // SPEC-089d: Carousel section
    let pages: [PaywallCarouselPage]?
    let autoScroll: Bool?
    let autoScrollIntervalMs: Int?
    let showIndicators: Bool?
    let indicatorColor: String?
    let indicatorActiveColor: String?

    // SPEC-089d: Timeline / Icon grid items (shared JSON key "items")
    let items: [PaywallGenericItem]?
    let lineColor: String?
    let completedColor: String?
    let currentColor: String?
    let upcomingColor: String?
    let showLine: Bool?
    let compact: Bool?

    // SPEC-089d: Icon grid / comparison table columns
    // Int for icon_grid (column count), [String] for comparison_table (column labels)
    let columns: AnyCodable?
    let iconSize: CGFloat?
    let iconColor: String?
    /// Direct text color for feature list items — takes priority over
    /// `style.elements.item_text.text_style.color`. Exposed in the console
    /// Content tab so users don't have to drop into the Style tab.
    let itemTextColor: String?
    let iconBgColor: String?       // Circle bg behind feature icons (screenshot 10)
    let iconBgOpacity: CGFloat?    // Circle opacity (default 0.15)
    let iconBgSize: CGFloat?       // Circle diameter (default 32)
    let spacing: CGFloat?

    // SPEC-089d: Comparison table section
    let tableColumns: [PaywallTableColumn]?
    let tableRows: [PaywallTableRow]?
    let checkColor: String?
    let crossColor: String?
    let highlightColor: String?
    let borderColor: String?

    // SPEC-089d: Promo input section
    let placeholder: String?
    let buttonText: String?
    let successText: String?
    let errorText: String?

    // SPEC-089d: Toggle section
    let label: String?
    let description: String?
    let defaultValue: Bool?
    let onColor: String?
    let offColor: String?
    let labelColorVal: String?
    let descriptionColor: String?
    let icon: String?
    let affectsPrice: Bool?

    // SPEC-089d: Reviews carousel section
    let reviews: [PaywallReview]?
    let showRatingStars: Bool?
    let starColor: String?

    // Section layout/orientation
    let layout: String?              // testimonial: card/quote/minimal; countdown: boxed/inline/banner
    let orientation: String?         // timeline: vertical/horizontal

    // Plan display style (per-section override)
    let planDisplayStyle: String?

    // Show flags for plan enrichment
    let showPlanIcons: Bool?
    let showPlanImages: Bool?
    let showPlanSubtitles: Bool?
    let showPlanFeatures: Bool?
    let showSavings: Bool?

    // Multi-card section
    let cards: [PaywallCardItem]?
    let cardColumns: Int?

    // Feature columns/gap (items come from existing 'items' field, parsed as PaywallFeatureItem)
    let featureColumns: Int?
    let featureGap: CGFloat?

    // CTA gradient
    let ctaGradient: PaywallGradient?

    // Plan card/badge styling (Gap 11)
    let cardCornerRadius: CGFloat?
    let cardPadding: CGFloat?
    let cardGap: CGFloat?
    let cardHeight: CGFloat?     // Minimum plan-card height in pt (console card_height; applied as minHeight)
    let cardShadow: AnyCodable?  // Bool or String ("none", "sm", "md", "lg")
    let badgePosition: String?       // top_left, top_right, inline, inside (default)
    let badgeStyle: String?          // capsule, rectangle, rounded
    let badgeBgColor: String?
    let badgeTextColor: String?
    let badgeBorderColor: String?    // Border color for badge
    let badgeBorderWidth: CGFloat?   // Border width for badge
    let badgeIcon: String?           // SF Symbol or emoji before badge text
    let badgeFontSize: CGFloat?      // Badge text size in pt (default 11 = .caption2)
    let subtitlePosition: String?    // "below_name", "below_price" (default), "above_price"
    let showDivider: Bool?           // Divider between price and features
    let dividerColor: String?        // Divider color
    let selectedBorderColor: String?
    let selectedBgColor: String?
    let selectedTextColor: String?      // Text color applied to all plan text elements when selected
    let unselectedBorderColor: String?  // Border color for non-selected cards (defaults to a subtle gray)
    let unselectedBgColor: String?      // Background color for non-selected cards (supports "transparent")
    let selectedScale: CGFloat?
    /// Color of the struck-through original price (plans[].original_price_display).
    let strikethroughColor: String?
    /// SPEC-438 (#548) — size of the struck original price, and the gap between it and the
    /// current price. Previously hardcoded, so authors had no control over either.
    let strikethroughFontSize: CGFloat?
    let strikethroughGap: CGFloat?
    /// SPEC-438 (#548) — `inline` (default, unchanged) or `headline_stacked`: a large
    /// current price with the struck was-price and the real charged total beneath it.
    let priceLayout: String?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, features, plans, cta, rating, testimonial, text, quote, height
        case restoreText = "restore_text"
        case showRestore = "show_restore"
        case restorePosition = "restore_position"
        case restoreTextColor = "restore_text_color"
        case restoreFontSize = "restore_font_size"
        case title_style, subtitle_style
        case imageUrl = "image_url"
        case imageAlignment = "image_alignment"
        case imageMaxHeight = "image_max_height"
        case reviewCount = "review_count"
        case guaranteeText = "guarantee_text"
        case subType = "sub_type"
        case countdownSeconds = "countdown_seconds"
        case cornerRadius = "corner_radius"
        case spacerHeight = "spacer_height"
        case authorName = "author_name"
        case authorRole = "author_role"
        case avatarUrl = "avatar_url"
        case lottieUrl = "lottie_url"
        case lottieLoop = "lottie_loop"
        case lottieSpeed = "lottie_speed"
        case lottieHeight = "lottie_height"
        case videoUrl = "video_url"
        case videoThumbnailUrl = "video_thumbnail_url"
        case videoHeight = "video_height"
        case riveUrl = "rive_url"
        case riveStateMachine = "rive_state_machine"
        case variant
        case durationSeconds = "duration_seconds"
        case targetDatetime = "target_datetime"
        case showDays = "show_days"
        case showHours = "show_hours"
        case showMinutes = "show_minutes"
        case showSeconds = "show_seconds"
        case labels
        case onExpireAction = "on_expire_action"
        case expiredText = "expired_text"
        case accentColor = "accent_color"
        case backgroundColor = "background_color"
        case fontSize = "font_size"
        case alignment, color, links, thickness
        case lineStyle = "style"
        case marginTop = "margin_top"
        case marginBottom = "margin_bottom"
        case marginHorizontal = "margin_horizontal"
        case labelText = "label_text"
        case labelColor = "label_color"
        case labelBgColor = "label_bg_color"
        case labelFontSize = "label_font_size"
        case ctaText = "cta_text"
        case ctaBgColor = "cta_bg_color"
        case ctaTextColor = "cta_text_color"
        case ctaCornerRadius = "cta_corner_radius"
        case ctaHeight = "cta_height"
        case ctaFontSize = "cta_font_size"
        case ctaFontWeight = "cta_font_weight"
        case secondaryText = "secondary_text"
        case secondaryAction = "secondary_action"
        case secondaryUrl = "secondary_url"
        case legalText = "legal_text"
        case blurBackground = "blur_background"
        case padding, pages
        case autoScroll = "auto_scroll"
        case autoScrollIntervalMs = "auto_scroll_interval_ms"
        case showIndicators = "show_indicators"
        case indicatorColor = "indicator_color"
        case indicatorActiveColor = "indicator_active_color"
        case items
        case lineColor = "line_color"
        case completedColor = "completed_color"
        case currentColor = "current_color"
        case upcomingColor = "upcoming_color"
        case showLine = "show_line"
        case compact, columns
        case iconSize = "icon_size"
        case iconColor = "icon_color"
        case itemTextColor = "item_text_color"
        case iconBgColor = "icon_bg_color"
        case iconBgOpacity = "icon_bg_opacity"
        case iconBgSize = "icon_bg_size"
        case spacing
        case tableColumns = "table_columns"
        case tableRows = "rows"
        case checkColor = "check_color"
        case crossColor = "cross_color"
        case highlightColor = "highlight_color"
        case borderColor = "border_color"
        case placeholder
        case buttonText = "button_text"
        case successText = "success_text"
        case errorText = "error_text"
        case label, description
        case defaultValue = "default_value"
        case onColor = "on_color"
        case offColor = "off_color"
        case labelColorVal = "toggle_label_color"
        case descriptionColor = "description_color"
        case icon
        case affectsPrice = "affects_price"
        case reviews
        case showRatingStars = "show_rating_stars"
        case starColor = "star_color"
        case cardCornerRadius = "card_corner_radius"
        case cardPadding = "card_padding"
        case cardGap = "card_gap"
        case cardHeight = "card_height"
        case cardShadow = "card_shadow"
        case badgePosition = "badge_position"
        case badgeStyle = "badge_style"
        case badgeBgColor = "badge_bg_color"
        case badgeTextColor = "badge_text_color"
        case badgeBorderColor = "badge_border_color"
        case badgeBorderWidth = "badge_border_width"
        case badgeIcon = "badge_icon"
        case badgeFontSize = "badge_font_size"
        case subtitlePosition = "subtitle_position"
        case showDivider = "show_divider"
        case dividerColor = "divider_color"
        case selectedBorderColor = "selected_border_color"
        case selectedBgColor = "selected_bg_color"
        case selectedTextColor = "selected_text_color"
        case unselectedBorderColor = "unselected_border_color"
        case unselectedBgColor = "unselected_bg_color"
        case selectedScale = "selected_scale"
        case strikethroughColor = "strikethrough_color"
        case strikethroughFontSize = "strikethrough_font_size"
        case strikethroughGap = "strikethrough_gap"
        case priceLayout = "price_layout"
        case layout, orientation
        case planDisplayStyle = "plan_display_style"
        case showPlanIcons = "show_plan_icons"
        case showPlanImages = "show_plan_images"
        case showPlanSubtitles = "show_plan_subtitles"
        case showPlanFeatures = "show_plan_features"
        case showSavings = "show_savings"
        case cards
        case cardColumns = "card_columns"
        case featureColumns = "feature_columns"
        case featureGap = "feature_gap"
        case ctaGradient = "cta_gradient"
    }
}

// MARK: - Multi-card item

struct PaywallCardItem: Codable {
    let title: String?
    let subtitle: String?
    let text: String?
    let image_url: String?
    let cta_text: String?
    let icon: String?
    let bg_color: String?
    let text_color: String?
    let border_color: String?
    let corner_radius: CGFloat?
}

struct PaywallPlanTrial: Codable {
    let duration_days: Int?
    let label: String?
}

/// SPEC-438 (#544) — the plan subtitle rendered as a coloured pill rather than plain text.
/// Authored on the product (Monetization → Products) and copied onto the plan when the
/// product is selected, so one promotion is set once and every paywall inherits it.
struct PaywallDescriptionBadge: Codable {
    let enabled: Bool?
    let bg_color: String?
    let text_color: String?
    let corner_radius: CGFloat?
}

struct PaywallPlan: Codable, Identifiable {
    private let _id: String?
    let productId: String?

    /// Stable identity — prefer explicit id, fall back to product_id
    var id: String { _id ?? productId ?? UUID().uuidString }
    let name: String?
    let label: String?
    let price: String?
    let price_display: String?
    let period: String?
    let badge: String?
    private let trialDuration: String?   // Legacy: "trial_duration" string
    let trial: PaywallPlanTrial?         // New: {duration_days, label} object
    let isDefault: Bool?
    let sort_order: Int?
    let description: String?
    let features: [String]?
    let savings_text: String?
    let cta_text: String?
    let icon: String?
    let image_url: String?
    /// Struck-through "old" price shown beside `displayPrice`. Section-level
    /// `strikethrough_color` controls its color.
    let original_price_display: String?
    /// SPEC-438 (#548) — the real charged total, shown under a per-period headline price
    /// when the section's `price_layout` is `headline_stacked`. Authored on the product.
    let price_total_display: String?
    /// SPEC-438 (#544) — render `description` as a coloured pill instead of plain text.
    let description_badge: PaywallDescriptionBadge?

    /// Display name — try label first (Firestore), then name (legacy)
    var displayName: String { label ?? name ?? "" }
    /// Display price — try price_display first (Firestore), then price (legacy)
    var displayPrice: String { price_display ?? price ?? "" }
    /// Trial display — an authored `trial.label` wins verbatim; a bare
    /// `trialDuration` ("7-day") is enriched to "7-day free trial" (Round-30:
    /// the " free trial" suffix used to live at the PlanCard render site only,
    /// so grid cards read "7-day free trial" while every other layout showed
    /// "7-day", and an authored label got a double "Free week free trial").
    /// Now centralised so all layouts + Android render the identical string.
    var trialLabel: String? { trial?.label ?? trialDuration.map { "\($0) free trial" } }

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case name, label, price, period, badge, price_display, sort_order
        case trial, description, features, savings_text, cta_text, icon, image_url
        case original_price_display
        case price_total_display
        case description_badge
        case productId = "product_id"
        case trialDuration = "trial_duration"
        case isDefault = "is_default"
    }

    /// Hand-written so a NUMERIC `price` cannot destroy the whole paywall.
    ///
    /// `price` / `price_display` are display strings here, but a paywall document is not always
    /// written by the console: experiment variant payloads, older documents and any non-console
    /// publisher can carry `"price": 49.99` as a JSON number. `PaywallConfig` is decoded
    /// all-or-nothing (`RemoteConfigManager.decodeTypedConfig` → `JSONDecoder.decode`), so ONE
    /// type-mismatched scalar in ONE plan threw, the whole document decoded to `nil`, and the paywall
    /// silently never rendered. Android's map-based parser has always shrugged this off. Coerce the
    /// scalar instead of discarding the paywall; every other field keeps its strict type.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self._id = try c.decodeIfPresent(String.self, forKey: ._id)
        self.productId = try c.decodeIfPresent(String.self, forKey: .productId)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.price = PaywallPlan.looseString(c, .price)
        self.price_display = PaywallPlan.looseString(c, .price_display)
        self.period = try c.decodeIfPresent(String.self, forKey: .period)
        self.badge = try c.decodeIfPresent(String.self, forKey: .badge)
        self.trialDuration = PaywallPlan.looseString(c, .trialDuration)
        self.trial = try c.decodeIfPresent(PaywallPlanTrial.self, forKey: .trial)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        self.sort_order = try c.decodeIfPresent(Int.self, forKey: .sort_order)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.features = try c.decodeIfPresent([String].self, forKey: .features)
        self.savings_text = try c.decodeIfPresent(String.self, forKey: .savings_text)
        self.cta_text = try c.decodeIfPresent(String.self, forKey: .cta_text)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.image_url = try c.decodeIfPresent(String.self, forKey: .image_url)
        // Loose-decode so a numeric anchor price (e.g. 19.99) can't nil the whole paywall.
        self.original_price_display = PaywallPlan.looseString(c, .original_price_display)
        self.price_total_display = PaywallPlan.looseString(c, .price_total_display)
        // Same defensive stance as every other optional here: a malformed badge object
        // must cost the author their pill, never the whole paywall.
        self.description_badge = try? c.decodeIfPresent(PaywallDescriptionBadge.self, forKey: .description_badge)
    }

    /// A JSON string, or a number rendered as one. Nil when absent (never throws — the caller has
    /// already decided that a stringly-typed field is not worth a paywall for).
    private static func looseString(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        }
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
        return nil
    }
}

struct PaywallCTAStyle: Codable {
    let bg_color: String?
    let text_color: String?
    let corner_radius: Double?
    let height: Double?
    let font_size: Double?
    let padding_vertical: Double?
}

struct PaywallCTA: Codable {
    let text: String?
    let styleObj: PaywallCTAStyle?
    let bg_color: String?
    let text_color: String?
    let corner_radius: Double?
    let height: Double?
    let font_size: Double?
    let padding_vertical: Double?

    /// Resolved bg_color — from style object, direct field, or default
    var resolvedBgColor: String { styleObj?.bg_color ?? bg_color ?? (AppDNA.brandAccentHex ?? "#6366F1") }
    /// Resolved text_color — from style object, direct field, or default
    var resolvedTextColor: String { styleObj?.text_color ?? text_color ?? "#FFFFFF" }
    /// Resolved corner_radius — from style object, direct field, or default
    var resolvedCornerRadius: Double { styleObj?.corner_radius ?? corner_radius ?? 12.0 }
    /// Resolved height — from style object, direct field, or default (52)
    var resolvedHeight: Double { styleObj?.height ?? height ?? 52.0 }
    /// Resolved font_size — from style object, direct field, or nil (uses system .headline)
    var resolvedFontSize: Double? { styleObj?.font_size ?? font_size }
    /// Resolved vertical padding — from style object, direct field, or default (16)
    var resolvedPaddingVertical: Double { styleObj?.padding_vertical ?? padding_vertical ?? 16.0 }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        bg_color = try container.decodeIfPresent(String.self, forKey: .bg_color)
        text_color = try container.decodeIfPresent(String.self, forKey: .text_color)
        corner_radius = try container.decodeIfPresent(Double.self, forKey: .corner_radius)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        font_size = try container.decodeIfPresent(Double.self, forKey: .font_size)
        padding_vertical = try container.decodeIfPresent(Double.self, forKey: .padding_vertical)
        // Try decoding style as object first, then as string (ignore string variant)
        styleObj = try? container.decodeIfPresent(PaywallCTAStyle.self, forKey: .styleObj)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(bg_color, forKey: .bg_color)
        try container.encodeIfPresent(text_color, forKey: .text_color)
        try container.encodeIfPresent(corner_radius, forKey: .corner_radius)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(font_size, forKey: .font_size)
        try container.encodeIfPresent(padding_vertical, forKey: .padding_vertical)
        try container.encodeIfPresent(styleObj, forKey: .styleObj)
    }

    enum CodingKeys: String, CodingKey {
        case text, bg_color, text_color, corner_radius
        case height, font_size, padding_vertical
        case styleObj = "style"
    }
}

struct PaywallDismiss: Codable {
    let allowed: Bool?
    private let _style: String?  // Firestore sends "style"
    private let _type: String?   // Legacy "type" fallback
    let delaySeconds: Int?
    let text: String?

    /// Dismiss style — server writes "style", legacy used "type". Accept both.
    var style: String { _style ?? _type ?? "x_button" }
    /// Whether dismiss is allowed — defaults to true for backward compat.
    var isAllowed: Bool { allowed ?? true }

    enum CodingKeys: String, CodingKey {
        case allowed, text
        case _style = "style"
        case _type = "type"
        case delaySeconds = "delay_seconds"
    }
}

struct PaywallGradientStop: Codable {
    let color: String?
    let position: Double?
}

struct PaywallGradient: Codable {
    let type: String?       // "linear", "radial"
    let angle: Double?
    let stops: [PaywallGradientStop]?
}

struct PaywallBackground: Codable {
    let type: String? // "color", "gradient", "image", "video"
    let value: String? // hex color, gradient def, image URL, or video URL (legacy)
    let color: String? // hex color (Firestore format)
    let colors: [String]?
    let gradient: PaywallGradient?
    let image_url: String?
    let image_fit: String?  // "cover", "contain", "fill"
    let overlay: String?    // hex color overlay
    // SPEC-085: Video background
    let video_url: String?
    let video_poster_url: String?
    let video_muted: Bool?
    let video_loop: Bool?
}

// MARK: - SPEC-089d: Codable sub-types for new paywall sections

struct PaywallLink: Codable {
    let label: String?
    let url: String?
    let action: String?  // "restore", "url", etc.
}

struct PaywallCarouselPage: Codable, Identifiable {
    let id: String?
    let children: [PaywallSection]?

    enum CodingKeys: String, CodingKey {
        case id, children
    }
}

/// Generic item used by timeline and icon_grid sections.
/// Timeline uses: id, title, subtitle, icon, status
/// Icon grid uses: icon, label, description
struct PaywallGenericItem: Codable {
    let id: String?
    let title: String?
    let subtitle: String?
    let icon: String?
    let status: String?       // completed | current | upcoming (timeline)
    let label: String?         // icon_grid
    let description: String?   // icon_grid
    let text: String?          // features
    let image_url: String?     // features
    let included: Bool?        // features (false = excluded)
    let emoji: String?         // features
    let color: String?         // timeline item color

    /// Display text — try text, title, label
    var displayText: String? { text ?? title ?? label }
}

struct PaywallTableColumn: Codable {
    let label: String?
    let highlighted: Bool?
}

struct PaywallTableRow: Codable {
    let feature: String?
    let values: [String]?
}

struct PaywallReview: Codable, Identifiable {
    let text: String?
    let author: String?
    let rating: Double?
    let avatarUrl: String?
    let avatarEmoji: String?
    let date: String?

    var id: String { (author ?? "unknown") + ((text ?? "").prefix(20).description) }

    enum CodingKeys: String, CodingKey {
        case text, author, rating, date
        case avatarUrl = "avatar_url"
        case avatarEmoji = "avatar_emoji"
    }
}

// MARK: - Public types

/// Context passed when presenting a paywall.
public struct PaywallContext {
    public let placement: String
    public let experiment: String?
    public let variant: String?
    /// SPEC-070-B PN row 4 (D-s) — arbitrary per-presentation attributes. Merged into the
    /// `paywall_view` event's properties, so they are queryable in the warehouse alongside
    /// `paywall_id` and `placement`. Keys colliding with a reserved property are dropped and warned
    /// about, never silently overwritten.
    ///
    /// This does NOT feed the `{{custom.*}}` template namespace: `TemplateContext` is a fixed struct
    /// sourced from global singletons and has no arbitrary-key bag. That path is deferred.
    public let customData: [String: Any]?

    /// Reserved `paywall_view` property names. `customData` may not shadow them.
    internal static let reservedEventKeys: Set<String> = ["paywall_id", "placement"]

    public init(
        placement: String,
        experiment: String? = nil,
        variant: String? = nil,
        customData: [String: Any]? = nil
    ) {
        self.placement = placement
        self.experiment = experiment
        self.variant = variant
        self.customData = customData
    }
}

/// The `PaywallContext` the PLACEMENT path hands to `PaywallManager`.
///
/// 🔴 Extracted from `AppDNA.presentPaywall(placement:…)`, where it was built inline from THREE of
/// `PaywallContext`'s four fields — and the fourth, `customData`, is the only one `PaywallManager`
/// merges into the `paywall_view` event's properties. So per-presentation attributes reached the
/// warehouse from an Android host (which passes the context straight through) and silently never from
/// an iOS one: same JS, same call, half the data, no error and no log.
///
/// The rebuild itself is necessary — `placement` is an argument of the placement API, and a caller may
/// pass a context whose own placement disagrees with it. What was not necessary was forgetting a field.
/// It lives here, named, so a test can assert that every field survives; an inline initializer inside a
/// `DispatchQueue.main.async` closure is unreachable from one, which is why nothing caught this.
internal enum PlacementPaywallContext {
    static func make(placement: String, from context: PaywallContext?) -> PaywallContext {
        PaywallContext(
            placement: placement,
            experiment: context?.experiment,
            variant: context?.variant,
            customData: context?.customData
        )
    }
}

/// Reason a paywall was dismissed.
public enum DismissReason: String {
    case purchased
    case dismissed
    case tappedOutside
    case programmatic
}

/// Action taken by the user on a paywall.
public enum PaywallAction: String {
    case ctaTapped = "cta_tapped"
    case featureSelected = "feature_selected"
    case planChanged = "plan_changed"
    case linkTapped = "link_tapped"
    case custom = "custom"
}

/// Delegate for paywall lifecycle events.
public protocol AppDNAPaywallDelegate: AnyObject {
    func onPaywallPresented(paywallId: String)
    func onPaywallAction(paywallId: String, action: PaywallAction)
    func onPaywallPurchaseStarted(paywallId: String, productId: String)
    func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo)
    func onPaywallPurchaseFailed(paywallId: String, error: Error)
    /// Typed variant of `onPaywallPurchaseFailed`. `errorType` is a stable, non-localized
    /// discriminator ("userCancelled", "networkError", "verificationFailed", …) — `error` alone is
    /// untyped, so a host (and every cross-platform wrapper) could not tell a user cancel from a card
    /// decline. Its default implementation forwards to the two-argument one, so hosts that only
    /// implement the old method keep working unchanged.
    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String)
    /// Full variant — THIS is the method the SDK calls. `productId` is the product the user was
    /// trying to buy; without it a paywall selling two products reported "a purchase failed" with no
    /// way to tell WHICH, so a host could not retry the right one or attribute the failure. It is
    /// `nil` only when the failure happened before a product was resolved (e.g. the paywall config
    /// itself was missing). Defaults forward down the chain — `productId` → `errorType` → the
    /// original two-argument method — so every existing conformer keeps compiling and keeps working.
    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?)
    func onPaywallDismissed(paywallId: String)
    /// AC-037: Validate a promo code entered by the user. Call the completion handler with `true` if valid, `false` otherwise.
    func onPromoCodeSubmit(paywallId: String, code: String, completion: @escaping (Bool) -> Void)
    /// Post-purchase: SDK wants the host app to open a deep link URL.
    func onPostPurchaseDeepLink(paywallId: String, url: String)
    /// Post-purchase: SDK wants the host app to continue to the next onboarding step.
    func onPostPurchaseNextStep(paywallId: String)
    /// Restore-purchase lifecycle: fired when the user taps the Restore button on the paywall
    /// and the SDK begins restoring entitlements via StoreKit 2.
    func onPaywallRestoreStarted(paywallId: String)
    /// Restore-purchase lifecycle: fired after the SDK successfully restores. `productIds`
    /// is the list of previously-purchased product identifiers returned by StoreKit. Hosts
    /// that need full transaction details can call `AppDNA.billing.restorePurchases()` to
    /// receive `[ServerEntitlement]` directly.
    func onPaywallRestoreCompleted(paywallId: String, productIds: [String])
    /// Restore-purchase lifecycle: fired when the restore call throws (network failure, no
    /// previous purchases, StoreKit error, etc.). The paywall stays visible.
    func onPaywallRestoreFailed(paywallId: String, error: Error)
}

/// Default empty implementations so delegates can opt into specific callbacks.
public extension AppDNAPaywallDelegate {
    func onPaywallPresented(paywallId: String) {}
    func onPaywallAction(paywallId: String, action: PaywallAction) {}
    func onPaywallPurchaseStarted(paywallId: String, productId: String) {}
    func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {}
    func onPaywallPurchaseFailed(paywallId: String, error: Error) {}
    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String) {
        onPaywallPurchaseFailed(paywallId: paywallId, error: error)
    }
    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
        onPaywallPurchaseFailed(paywallId: paywallId, error: error, errorType: errorType)
    }
    func onPaywallDismissed(paywallId: String) {}
    func onPromoCodeSubmit(paywallId: String, code: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func onPostPurchaseDeepLink(paywallId: String, url: String) {}
    func onPostPurchaseNextStep(paywallId: String) {}
    func onPaywallRestoreStarted(paywallId: String) {}
    func onPaywallRestoreCompleted(paywallId: String, productIds: [String]) {}
    func onPaywallRestoreFailed(paywallId: String, error: Error) {}
}

// MARK: - Post-Purchase Config

public struct PostPurchaseConfig: Codable {
    public let on_success: PostPurchaseSuccessConfig?
    public let on_failure: PostPurchaseFailureConfig?
}

public struct PostPurchaseSuccessConfig: Codable {
    public let action: String  // "dismiss", "show_message", "deep_link", "next_step"
    public let message: String?
    public let delay_ms: Int?
    public let deep_link_url: String?
    public let confetti: Bool?
    public let lottie_url: String?
}

public struct PostPurchaseFailureConfig: Codable {
    public let action: String  // "show_error", "retry", "dismiss"
    public let message: String?
    public let retry_text: String?
    public let allow_dismiss: Bool?
}
