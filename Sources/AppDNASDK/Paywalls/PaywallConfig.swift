import Foundation

/// Codable structs matching Firestore PaywallConfig schema.
struct PaywallConfig: Codable {
    let id: String?
    let name: String?
    var layout: PaywallLayout?
    private var _sections: [PaywallSection]?
    var plans: [PaywallPlan]?
    let cta: PaywallCTA?
    let dismiss: PaywallDismiss?
    let background: PaywallBackground?
    let placement: String?
    let placement_label: String?
    let version: Int?
    // Design tokens
    let animation: AnimationConfig?
    let localizations: [String: [String: String]]?
    let default_locale: String?
    // Rich media
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

    /**
     #923 — a copy with the STORE's price on every plan, wherever that plan lives.

     The root `plans` array, the top-level `sections`, and `layout.sections` are three places a
     paywall's plans can be written, and the renderer reads whichever is present. Applying to one
     of them is the same as applying to none on a document that used another — which is exactly
     what the first version did, and what `StorePriceRenderTests` caught by comparing what the
     view actually drew.

     An empty map returns `self` untouched: a failed or timed-out lookup must change nothing.
     */
    func applyingStorePrices(_ prices: [String: String]) -> PaywallConfig {
        guard !prices.isEmpty else { return self }
        func priced(_ list: [PaywallPlan]?) -> [PaywallPlan]? {
            list?.map { plan in
                var copy = plan
                copy.resolvedStorePrice = plan.productId.flatMap { prices[$0] }
                return copy
            }
        }
        func priced(_ list: [PaywallSection]?) -> [PaywallSection]? {
            list?.map { section in
                guard section.type == "plans", let plans = section.data?.plans else { return section }
                var copy = section
                copy.setPlans(priced(plans))
                return copy
            }
        }
        var out = self
        out.plans = priced(plans)
        out._sections = priced(_sections)
        out.layout?.sections = priced(layout?.sections)
        return out
    }

    /**
     #933 — a copy with the STORE's ISO billing period on every plan, wherever that plan lives.

     🔴 Deliberately the same THREE assignments as `applyingStorePrices`, including `_sections` and
     `layout?.sections`. #923's first version of the price substitution mapped only the root `plans`
     array, while every real paywall carries its plans in `layout.sections[].config.plans` — so the
     feature passed its fixture, passed its live-StoreKit test, and reached nothing on screen.
     Walking fewer places here would repeat that exactly.
     */
    func applyingStorePeriods(_ periods: [String: String]) -> PaywallConfig {
        guard !periods.isEmpty else { return self }
        func timed(_ list: [PaywallPlan]?) -> [PaywallPlan]? {
            list?.map { plan in
                var copy = plan
                copy.resolvedStorePeriod = plan.productId.flatMap { periods[$0] }
                return copy
            }
        }
        func timed(_ list: [PaywallSection]?) -> [PaywallSection]? {
            list?.map { section in
                guard section.type == "plans", let plans = section.data?.plans else { return section }
                var copy = section
                copy.setPlans(timed(plans))
                return copy
            }
        }
        var out = self
        out.plans = timed(plans)
        out._sections = timed(_sections)
        out.layout?.sections = timed(layout?.sections)
        return out
    }
}

struct PaywallLayout: Codable {
    let type: String? // "stack", "grid", "carousel"
    let spacing: CGFloat?
    let padding: CGFloat?
    let footer_padding: CGFloat?  // Bottom padding for CTA/footer zone (default 8)
    // #919 — a section with a bad field costs that section, not the whole paywall.
    @LenientArray var sections: [PaywallSection]?
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
    private var _data: PaywallSectionData?
    private var _config: PaywallSectionData?
    // Per-section styling
    let style: SectionStyleConfig?
    /// When true, this section fades out and collapses to 0 height as the user scrolls.
    let collapse_on_scroll: Bool?
    /**
     #884 — which zone this section lives in: "body" (scrolls) or "bottom" (pinned with the CTA).

     Until now only the `cta` section, and a `legal` placed after it, could be pinned — so a
     paywall's plan tiles scrolled away while the button that buys them stayed. On a short screen
     that leaves the user choosing between options they cannot see.

     Absent means "body", so every paywall written before this renders exactly as it did.
     */
    let zone: String?

    /// Non-optional accessor defaulting to "unknown" when Firestore omits the field.
    var type: String { _type ?? "unknown" }

    /// Section data — server writes as "config", SDK historically used "data". Accept both.
    var data: PaywallSectionData? { _data ?? _config }

    /// #923 — replace this section's plans, in whichever of the two keys carries them.
    ///
    /// 🔴 A paywall's plans live in `layout.sections[].config.plans`, not at the document root, and
    /// the renderer reads them from there (`config.sections.first(type: "plans")?.data?.plans ??
    /// config.plans`). The first version of the store-price substitution mapped ONLY the root
    /// array, so on every real paywall the lookup ran, resolved, and reached nothing. It took
    /// rendering the view and comparing pixels to see it — the fixture and the live-StoreKit test
    /// both passed throughout, because neither of them draws.
    mutating func setPlans(_ newPlans: [PaywallPlan]?) {
        if _data != nil { _data?.plans = newPlans }
        if _config != nil { _config?.plans = newPlans }
    }

    enum CodingKeys: String, CodingKey {
        case _type = "type"
        case id
        case _data = "data"
        case _config = "config"
        case style
        case collapse_on_scroll
        case zone
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
    var plans: [PaywallPlan]?

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
    let restoreTextColor: String?   // CTA section: restore link text color
    /// #651 — Restore's own fill + radius, the pair the CTA already has.
    let restoreBgColor: String?
    let restoreCornerRadius: Double?
    /// The gap between the CTA button and the Restore link. Was a
    /// hardcoded `VStack(spacing: 8)` here, `Spacer(8.dp)` on Android and `mt-2` in the preview,
    /// with no way to author it. Unset keeps 8 on every surface.
    let restoreGap: CGFloat?
    /// What the CTA and the restore link DO. Unset keeps today's
    /// behaviour exactly: the CTA purchases, the restore link restores.
    let ctaAction: String?
    let restoreAction: String?
    /// Additional buttons, rendered under the CTA in order.
    let extraButtons: [PaywallExtraButton]?
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

    // Rich media in paywall sections
    let lottieUrl: String?
    let lottieLoop: Bool?
    let lottieSpeed: Double?
    let lottieHeight: CGFloat?
    let videoUrl: String?
    let videoThumbnailUrl: String?
    let videoHeight: CGFloat?
    let riveUrl: String?
    let riveStateMachine: String?

    // Countdown section
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

    // Legal section
    let color: String?
    let links: [PaywallLink]?

    // Divider section
    let thickness: CGFloat?
    /// A DIVIDER's line style, and it maps from the bare key `style` — which the console also
    /// uses for a per-element style MAP on header / features / plans / legal sections. #919: four
    /// sections of one ACTIVE paywall threw here and iOS dropped the whole paywall; Android read
    /// null and rendered. Lenient now: an object yields nil and the divider takes its default.
    @LenientScalar var lineStyle: String?         // solid | dashed | dotted
    let marginTop: CGFloat?
    let marginBottom: CGFloat?
    let marginHorizontal: CGFloat?
    let labelText: String?
    let labelColor: String?
    let labelBgColor: String?
    let labelFontSize: CGFloat?

    // Sticky footer section
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
    /// The sticky footer's Subtitle was drawn at a HARDCODED 10pt on both
    /// natives and in the preview, honouring no authored size or colour. The console's
    /// "Subtitle Style" controls had been removed with a note to re-add them "once natives+preview
    /// support per-legal typography" — this is that support. Unset keeps 10pt / `.secondary`, so
    /// no published paywall changes.
    let legalFontSize: CGFloat?
    let legalTextColor: String?
    let blurBackground: Bool?
    let padding: CGFloat?

    // Carousel section
    let pages: [PaywallCarouselPage]?
    let autoScroll: Bool?
    let autoScrollIntervalMs: Int?
    let showIndicators: Bool?
    let indicatorColor: String?
    let indicatorActiveColor: String?

    // Timeline / Icon grid items (shared JSON key "items")
    let items: [PaywallGenericItem]?
    let lineColor: String?
    let completedColor: String?
    let currentColor: String?
    let upcomingColor: String?
    let showLine: Bool?
    let compact: Bool?

    // Icon grid / comparison table columns
    // Int for icon_grid (column count), [String] for comparison_table (column labels)
    let columns: AnyCodable?
    let iconSize: CGFloat?
    let iconColor: String?
    /// Direct text color for feature list items — takes priority over
    /// `style.elements.item_text.text_style.color`. Exposed in the console
    /// Content tab so users don't have to drop into the Style tab.
    let itemTextColor: String?
    /// #591 — the feature subtitle's own type, and the shape an item image is clipped to. Section-
    /// level for the same reason `itemTextColor` is: one setting keeps every subtitle in a paywall
    /// looking alike, which is the concern that got subtitles removed from these items in April.
    let itemSubtitleColor: String?
    let itemSubtitleFontSize: CGFloat?
    let itemImageShape: String?
    /// The cross drawn on an EXCLUDED feature item. Authorable — a fixed red is unreadable on a red paywall.
    let itemExcludedColor: String?
    let iconBgColor: String?       // Circle bg behind feature icons (screenshot 10)
    let iconBgOpacity: CGFloat?    // Circle opacity (default 0.15)
    let iconBgSize: CGFloat?       // Circle diameter (default 32)
    let spacing: CGFloat?

    // Comparison table section
    let tableColumns: [PaywallTableColumn]?
    let tableRows: [PaywallTableRow]?
    let checkColor: String?
    let crossColor: String?
    let highlightColor: String?
    let borderColor: String?

    // Promo input section
    let placeholder: String?
    let buttonText: String?
    let successText: String?
    let errorText: String?

    // Toggle section
    let label: String?
    let description: String?
    let defaultValue: Bool?
    let onColor: String?
    let offColor: String?
    let labelColorVal: String?
    let descriptionColor: String?
    let icon: String?
    let affectsPrice: Bool?

    // Reviews carousel section
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
    /// Size of the struck original price, and the gap between it and the
    /// current price. Previously hardcoded, so authors had no control over either.
    let strikethroughFontSize: CGFloat?
    let strikethroughGap: CGFloat?
    /// `inline` (default, unchanged) or `headline_stacked`: a large
    /// current price with the struck was-price and the real charged total beneath it.
    let priceLayout: String?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, features, plans, cta, rating, testimonial, text, quote, height
        case restoreText = "restore_text"
        case showRestore = "show_restore"
        case restorePosition = "restore_position"
        case restoreTextColor = "restore_text_color"
        case restoreBgColor = "restore_bg_color"
        case restoreCornerRadius = "restore_corner_radius"
        case restoreGap = "restore_gap"
        case ctaAction = "cta_action"
        case restoreAction = "restore_action"
        case extraButtons = "extra_buttons"
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
        case legalFontSize = "legal_font_size"
        case legalTextColor = "legal_text_color"
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
        case itemSubtitleColor = "item_subtitle_color"
        case itemSubtitleFontSize = "item_subtitle_font_size"
        case itemImageShape = "item_image_shape"
        case itemExcludedColor = "item_excluded_color"
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

/// The plan subtitle rendered as a coloured pill rather than plain text.
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
    /**
     #923 — whether this plan's price comes from the STORE or from `price_display`.

     🔴 The DEFAULT IS THE STORE, so this is an opt-OUT and `nil` means "ask". It exists for a plan
     that deliberately shows a marketing price — a struck-through "was $19.99", a price the app
     subsidises, a plan with no store product behind it — and `false` wins even over a store that
     answered.
     */
    let use_store_price: Bool?
    /**
     #923 — the store's localized price for this plan's product, filled in by the PRESENTER just
     before the screen is built, or nil when the lookup failed, timed out or did not know the
     product.

     A `var` that is never decoded, rather than a rebuilt struct: `PaywallPlan` has thirty fields
     and a field-by-field rebuild is how `StepConfigOverrideMerger` silently deleted `chat_config`.
     Read only through `displayPrice`, so every render site on every layout follows at once.
     */
    var resolvedStorePrice: String?
    /**
     #933 — the STORE's ISO billing period for this plan's product (`P1M`, `P1Y`), filled in by the
     presenter beside `resolvedStorePrice`. Never authored and never published: it is what StoreKit
     told this device, normalised to the spelling Play reports directly.
     */
    var resolvedStorePeriod: String?
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
    /**
     #933 — the period drawn beside the price, phrased in the device's language.

     🔴 AN AUTHORED `period` WINS. Additive on purpose: an author who typed "mo" keeps "mo", so no
     published paywall changes appearance, while a plan that authored nothing — 0 of 81 in
     production — gains a correct period instead of none. The store's value is structural (`P1M`),
     so it is phrased through `BillingPeriodPhrase` rather than printed.
     */
    var displayPeriod: String? {
        if let authored = period?.trimmingCharacters(in: .whitespaces), !authored.isEmpty {
            return authored
        }
        return BillingPeriodPhrase.suffix(resolvedStorePeriod, locale: Locale.current.identifier)
    }

    /// Struck-through "old" price shown beside `displayPrice`. Section-level
    /// `strikethrough_color` controls its color.
    let original_price_display: String?
    /// The real charged total, shown under a per-period headline price
    /// when the section's `price_layout` is `headline_stacked`. Authored on the product.
    let price_total_display: String?
    /// Render `description` as a coloured pill instead of plain text.
    let description_badge: PaywallDescriptionBadge?
    /// #588 — this plan's price colour. Beats the section's `elements.price` style and the
    /// selected/unselected text colour, because the whole point is to make ONE tier's price stand
    /// out from the others; anything that could override it would defeat it.
    let price_color: String?
    /// #587 — this plan's subtitle type. Section-level `elements.description` styles every plan
    /// identically, which is the opposite of what an author wants when one tier should read
    /// differently.
    let subtitle_color: String?
    let subtitle_font_size: Double?
    let subtitle_align: String?
    /// #589 — `card` (default) or `text_only`: name and price on one centred line, with no border,
    /// background, badge, subtitle or selection control. Still selectable — it is a plan.
    let display_mode: String?
    let text_only_font_size: Double?
    let text_only_color: String?

    /// Display name — try label first (Firestore), then name (legacy)
    var displayName: String { label ?? name ?? "" }
    /// Display price — try price_display first (Firestore), then price (legacy)
    /// Display price — the STORE's, falling back to what the author typed (#923).
    ///
    /// Every layout reads this one property, which is why the substitution lives here rather than
    /// at the eight render sites that would each have had to remember it.
    var displayPrice: String {
        StorePriceSubstitution.resolve(
            authoredPrice: price_display ?? price,
            productId: productId,
            useStorePrice: use_store_price,
            storePrice: resolvedStorePrice
        ).priceDisplay
    }

    /// Where `displayPrice` came from — `store`, or one of the three authored reasons (#923).
    /// Reported with `paywall_view` so a customer asking why their paywall shows the old price has
    /// an answer in the data rather than a guess.
    var priceSource: String {
        StorePriceSubstitution.resolve(
            authoredPrice: price_display ?? price,
            productId: productId,
            useStorePrice: use_store_price,
            storePrice: resolvedStorePrice
        ).source
    }
    /// Trial display — an authored `trial.label` wins verbatim; a bare
    /// `trialDuration` ("7-day") is enriched to "7-day free trial" (
    /// the " free trial" suffix used to live at the PlanCard render site only,
    /// so grid cards read "7-day free trial" while every other layout showed
    /// "7-day", and an authored label got a double "Free week free trial").
    /// Now centralised so all layouts + Android render the identical string.
    /**
     #933 — an ISO duration in `trial_duration` is PHRASED rather than printed raw.

     `trial_duration` is author-supplied text, and the two stores express a trial period as an ISO
     duration (`P7D`, `P1W`). A config that carries the store's own spelling — an import, a
     hand-edited document or a generator, the same route #959's numeric price arrived by — rendered
     literally as **"P7D free trial"**. `BillingPeriodPhrase` turns that into "7 days free trial";
     anything it cannot parse is printed exactly as authored, so "7-day" is untouched.
    */
    var trialLabel: String? {
        if let label = trial?.label { return label }
        guard let d = trialDuration else { return nil }
        let phrased = BillingPeriodPhrase.duration(d, locale: Locale.current.identifier) ?? d
        return "\(phrased) free trial"
    }

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case name, label, price, period, badge, price_display, sort_order
        case use_store_price
        case trial, description, features, savings_text, cta_text, icon, image_url
        case original_price_display
        case price_total_display
        case description_badge
        case price_color, subtitle_color, subtitle_font_size, subtitle_align
        case display_mode, text_only_font_size, text_only_color
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
        self._id = c.lenient(String.self, ._id)
        self.productId = c.lenient(String.self, .productId)
        self.name = c.lenient(String.self, .name)
        self.label = c.lenient(String.self, .label)
        self.price = PaywallPlan.looseString(c, .price)
        self.price_display = PaywallPlan.looseString(c, .price_display)
        // #923 — absent means "ask the store", so only an explicit `false` opts out.
        self.use_store_price = try? c.decodeIfPresent(Bool.self, forKey: .use_store_price)
        self.resolvedStorePrice = nil
        // #933 — filled by the presenter after the store answers, never decoded: it is not in
        // `CodingKeys` because it is not in the published document.
        self.resolvedStorePeriod = nil
        self.period = c.lenient(String.self, .period)
        self.badge = c.lenient(String.self, .badge)
        self.trialDuration = PaywallPlan.looseString(c, .trialDuration)
        self.trial = try c.decodeIfPresent(PaywallPlanTrial.self, forKey: .trial)
        self.isDefault = c.lenient(Bool.self, .isDefault)
        self.sort_order = c.lenient(Int.self, .sort_order)
        self.description = c.lenient(String.self, .description)
        self.features = try c.decodeIfPresent([String].self, forKey: .features)
        self.savings_text = c.lenient(String.self, .savings_text)
        self.cta_text = c.lenient(String.self, .cta_text)
        self.icon = c.lenient(String.self, .icon)
        self.image_url = c.lenient(String.self, .image_url)
        // Loose-decode so a numeric anchor price (e.g. 19.99) can't nil the whole paywall.
        self.original_price_display = PaywallPlan.looseString(c, .original_price_display)
        self.price_total_display = PaywallPlan.looseString(c, .price_total_display)
        // Same defensive stance as every other optional here: a malformed badge object
        // must cost the author their pill, never the whole paywall.
        self.description_badge = try? c.decodeIfPresent(PaywallDescriptionBadge.self, forKey: .description_badge)
        // #587 / #588 / #589 — per-plan presentation. `try?` throughout for the same reason as the
        // badge above: a malformed override must cost the author that override, never the paywall.
        self.price_color = try? c.decodeIfPresent(String.self, forKey: .price_color)
        self.subtitle_color = try? c.decodeIfPresent(String.self, forKey: .subtitle_color)
        self.subtitle_font_size = PaywallPlan.looseDouble(c, .subtitle_font_size)
        self.subtitle_align = try? c.decodeIfPresent(String.self, forKey: .subtitle_align)
        self.display_mode = try? c.decodeIfPresent(String.self, forKey: .display_mode)
        self.text_only_font_size = PaywallPlan.looseDouble(c, .text_only_font_size)
        self.text_only_color = try? c.decodeIfPresent(String.self, forKey: .text_only_color)
    }

    /// A JSON number, or a numeric string rendered as one — the console writes sizes through a
    /// slider, but an imported or AI-generated paywall can carry `"13"`. Same defensive stance as
    /// `looseString`: never throws, so one stringly-typed size cannot nil the whole paywall.
    private static func looseDouble(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
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
        text = container.lenient(String.self, .text)
        bg_color = container.lenient(String.self, .bg_color)
        text_color = container.lenient(String.self, .text_color)
        corner_radius = container.lenient(Double.self, .corner_radius)
        height = container.lenient(Double.self, .height)
        font_size = container.lenient(Double.self, .font_size)
        padding_vertical = container.lenient(Double.self, .padding_vertical)
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

/// An extra button in the CTA section, beyond the CTA and the restore link.
struct PaywallExtraButton: Codable, Identifiable {
    let text: String?
    /// purchase | restore | dismiss | link. `dismiss` leaves the paywall, which returns the user to
    /// the previous screen — there is deliberately no separate `back`.
    let action: String?
    let url: String?
    let bg_color: String?
    let text_color: String?
    let font_size: Double?
    /// `filled` (default) draws a button; `text` draws a tappable label like the restore link.
    let style: String?
    /// #651 — its own radius; unset inherits the CTA's.
    let corner_radius: Double?

    /// Identifiable for ForEach without requiring the console to mint ids.
    var id: String { "\(text ?? "")|\(action ?? "")|\(url ?? "")" }
}

struct PaywallDismiss: Codable {
    let allowed: Bool?
    private let _style: String?  // Firestore sends "style"
    private let _type: String?   // Legacy "type" fallback
    let delaySeconds: Int?
    let text: String?
    /// Placement, colour and size for the X / back chevron. Unset keeps the
    /// previous hardcoded top-right, `.primary` and 16pt.
    private let _position: String?
    let color: String?
    let size: CGFloat?

    /// "top_left" | "top_right" (default).
    var position: String { _position ?? "top_right" }

    /// Dismiss style — server writes "style", legacy used "type". Accept both.
    var style: String { _style ?? _type ?? "x_button" }
    /// Whether dismiss is allowed — defaults to true for backward compat.
    var isAllowed: Bool { allowed ?? true }

    /// #652 — the Back button is its OWN control, not a style of the close button. A
    /// paywall can want both at once, each with its own placement, colour, size and delay.
    let back: PaywallBackButton?

    enum CodingKeys: String, CodingKey {
        case allowed, text, color, size, back
        case _style = "style"
        case _position = "position"
        case _type = "type"
        case delaySeconds = "delay_seconds"
    }
}

/// #652 — the second dismissal affordance, configured independently of the close button.
struct PaywallBackButton: Codable {
    let enabled: Bool?
    /// `chevron` (default) | `arrow` | `text_link`.
    let style: String?
    private let _position: String?
    let color: String?
    let size: CGFloat?
    let delaySeconds: Int?
    /// Label for `text_link`; ignored by the glyph styles.
    let text: String?

    var isEnabled: Bool { enabled ?? false }
    /// Back defaults to the LEFT — the side a back affordance is expected on, and the side the
    /// close button is not, so both can be shown without overlapping.
    var position: String { _position ?? "top_left" }
    var resolvedStyle: String { style ?? "chevron" }

    enum CodingKeys: String, CodingKey {
        case enabled, style, color, size, text
        case _position = "position"
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
    // Video background
    let video_url: String?
    let video_poster_url: String?
    let video_muted: Bool?
    let video_loop: Bool?
}

// MARK: - Codable sub-types for new paywall sections

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
    /// Arbitrary per-presentation attributes. Merged into the
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
    /// Validate a promo code entered by the user. Call the completion handler with `true` if valid, `false` otherwise.
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
