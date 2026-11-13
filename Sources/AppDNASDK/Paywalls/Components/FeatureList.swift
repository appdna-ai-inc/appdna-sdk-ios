import SwiftUI

/// Checkmark feature list for paywalls.
/// Supports plain string features and rich structured items with icons, images, and excluded state.
struct FeatureList: View {
    /**
     The page this list is drawn on, so a colour nobody authored follows the DOCUMENT
     rather than the phone.

     `.primary` and `.secondary` are system colours: black in light appearance, white in dark. A
     paywall forces no colour scheme, so a document that sets a dark page and is opened on a
     light-appearance phone asked for black text on a dark background — and the other way round.
     Measured, by rendering this section on both pages in both appearances:

         white page, dark appearance    0 ink of 1,131,840 px
         dark page,  light appearance   0 ink of 1,131,840 px

     Zero. The feature list — the reason most paywalls exist — was not on the screen for any user
     whose phone setting disagreed with the author's background. The same fix was already in place
     for the plan tiles and the header; this is the same defect in the sections it did not reach.
     */
    @SwiftUI.Environment(\.paywallBackgroundHex) private var pageBackgroundHex: String?

    let features: [String]

    /*
     * A feature row is TAPPABLE, and reports `.featureSelected`.
     *
     * Rows were decorative until now, which is why `featureSelected` had no emitter on either
     * platform. The owner asked for all four cases, so the rows gain a tap.
     *
     * 🔴 `.onTapGesture`, NOT a `Button` or a drag-capable gesture. A paywall's feature list sits
     * inside a ScrollView, and this repo has already shipped a tap handler that swallowed every
     * gesture in a step on both platforms (the keyboard-dismiss handler). A tap gesture coexists
     * with the scroll's drag; a Button would also change the rows' appearance and give them a
     * pressed state they are not designed for.
     *
     * Nothing visual changes: a row looks and reads exactly as it did.
     */
    var onFeatureSelected: (() -> Void)? = nil
    var richItems: [PaywallGenericItem]? = nil
    var columns: Int = 1
    var gap: CGFloat = 12
    /// Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil
    /// Direct icon color override from section.data.icon_color — takes priority
    /// over sectionStyle.elements["icon"].textStyle.color. Exposed in the console
    /// Content tab for easier access than the Style tab.
    var iconColorOverride: String? = nil
    /// Direct text color from section.data.item_text_color — takes priority
    /// over sectionStyle.elements["item_text"].text_style.color. Mirrors the
    /// icon_color / iconColorOverride pattern so a Content-tab value always
    /// wins when both are set.
    var itemTextColorOverride: String? = nil
    /// A feature item's optional second line, and its own type.
    ///
    /// Section-level rather than per-item, exactly like `item_text_color` and `item_font_size`
    /// above. A subtitle was REMOVED from these items in April because AI-generated ones made
    /// paywalls visually inconsistent; per-item styling would reopen that door, while one setting
    /// for the section keeps every subtitle in a paywall looking alike. The TEXT stays per item.
    var subtitleColorOverride: String? = nil
    var subtitleFontSize: CGFloat? = nil
    /// `rounded` (default, unchanged), `circle`, or `square`.
    var itemImageShape: String? = nil
    /// The cross on an EXCLUDED item. Authorable for the same reason every other colour here is.
    var itemExcludedColor: String? = nil
    /// Circle background behind each feature icon (screenshot 10 effect)
    var iconBgColor: String? = nil
    var iconBgOpacity: CGFloat = 0.15
    var iconBgSize: CGFloat = 32

    /// Resolved per-item text style with the Content-tab color override baked
    /// in. Must merge the override BEFORE calling `applyTextStyle`, because
    /// `Text.foregroundColor` is baked in when the style is applied — a
    /// later `.foregroundColor` modifier on the wrapping Group is a no-op.
    private var itemTextStyle: TextStyleConfig? {
        // Console saves under "item_text" key; fall back to legacy "item" key for older configs
        let base = sectionStyle?.elements?["item_text"]?.textStyle
            ?? sectionStyle?.elements?["item"]?.textStyle
        if let hex = itemTextColorOverride, !hex.isEmpty {
            var merged = base ?? TextStyleConfig(
                font_family: nil, font_size: nil, font_weight: nil, color: nil,
                alignment: nil, line_height: nil, letter_spacing: nil,
                opacity: nil, text_transform: nil
            )
            merged.color = hex
            return merged
        }
        return base
    }
    private var iconColor: Color? {
        // Priority: section.data.icon_color (Content tab) > style.elements.icon.textStyle.color (Style tab)
        if let hex = iconColorOverride, !hex.isEmpty {
            return Color(hex: hex)
        }
        if let hex = sectionStyle?.elements?["icon"]?.textStyle?.color {
            return Color(hex: hex)
        }
        return nil
    }

    var body: some View {
        /*
         🔴 BOTH keys are drawn, and this used to be an `if/else` that drew only one.

         A `features` section may carry the plain `features` string array, the structured `items`
         array, or both. Android already rendered both, deliberately — its own comment gives
         the reason: "Both keys can be present on an older document, and rendering only one of them
         would trade this bug for its mirror image." iOS drew `items` when present and SILENTLY
         DROPPED every plain string beside them, so the same published document showed N+M rows on
         Android and M on iOS.

         The console only writes `items` today and older documents only carry `features`, so the
         two agree on everything authored through it — which is precisely why nobody saw this. It is
         a document carrying both (an older save, or a generated one) that diverges, and on that
         document iOS was the platform losing content an author had set.

         Plain strings first: they are the older key, so they are the rows that were already on the
         screen before `items` was added to the same section.
         */
        VStack(alignment: .leading, spacing: gap) {
            if !features.isEmpty {
                ForEach(features, id: \.self) { feature in
                    HStack(spacing: 12) {
                        featureIcon()
                        itemText(feature)
                    }
                    // The whole row, not just the text: a tap target the width of one word is a
                    // tap target nobody hits.
                    .contentShape(Rectangle())
                    .onTapGesture { onFeatureSelected?() }
                }
            }
            if let items = richItems, !items.isEmpty {
                if columns > 1 {
                    // Multi-column grid
                    let gridColumns = Array(repeating: GridItem(.flexible(), spacing: gap), count: columns)
                    LazyVGrid(columns: gridColumns, spacing: gap) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            richItemRow(item)
                                .contentShape(Rectangle())
                                .onTapGesture { onFeatureSelected?() }
                        }
                    }
                } else {
                    // Single column rich items
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        richItemRow(item)
                            .contentShape(Rectangle())
                            .onTapGesture { onFeatureSelected?() }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    /// The item's authored container style, from `item_text` or its `item` alias, exactly
    /// as the text style resolves.
    private var itemElementStyle: ElementStyleConfig? {
        sectionStyle?.elements?["item_text"]?.container ?? sectionStyle?.elements?["item"]?.container
    }

    @ViewBuilder
    private func itemText(_ text: String) -> some View {
        Group {
            if let ts = itemTextStyle {
                // Merged over the unstyled `.body` row (#1800), so a colour-only style (or the
                // Content-tab `item_text_color`, which arrives here as one) keeps the row's size.
                Text(text).applyTextStyle(ts, defaults: TextStyleDefaults(
                    font: .body, size: 17, weight: 400,
                    color: PaywallTextDefaults.readable(on: pageBackgroundHex)))
            } else if let hex = itemTextColorOverride, !hex.isEmpty {
                Text(text).font(.body).foregroundColor(Color(hex: hex))
            } else {
                // Off the PAGE, not off the phone. See the note on `pageBackgroundHex`.
                Text(text).font(.body).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
            }
        }
        .applyElementStyle(itemElementStyle)
    }

    @ViewBuilder
    private func richItemRow(_ item: PaywallGenericItem) -> some View {
        let isIncluded = item.included ?? true
        HStack(spacing: 12) {
            // Icon: custom emoji/SF Symbol, or default check/cross — with optional circle bg
            featureIcon(item: item, isIncluded: isIncluded)

            // Title, and the subtitle under it when the author wrote one. `.top` alignment
            // rather than the row's default centring: with two lines of text against a single icon,
            // centring floats the icon against the gap between them.
            VStack(alignment: .leading, spacing: 2) {
                itemText(item.displayText ?? "")
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: subtitleFontSize ?? 12))
                        .foregroundColor(
                            // The subtitle's `.secondary` had the same problem as the
                            // title's `.primary`; 70% of the page's ink is this repo's `secondary`.
                            subtitleColorOverride.flatMap { $0.isEmpty ? nil : Color(hex: $0) }
                                ?? PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isIncluded ? 1.0 : 0.4)
    }

    /// The shape an uploaded feature image is clipped to.
    ///
    /// `AnyShape` rather than a `switch` returning three different `.clipShape` calls: SwiftUI's
    /// `clipShape` takes one concrete `Shape`, so branching at the call site would need the whole
    /// image expression duplicated three times.
    private var imageClipShape: AnyShape {
        switch itemImageShape {
        case "circle": return AnyShape(Circle())
        case "square": return AnyShape(Rectangle())
        default: return AnyShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    /// Renders a feature icon with optional circle background (screenshot 10).
    @ViewBuilder
    private func featureIcon(item: PaywallGenericItem? = nil, isIncluded: Bool = true) -> some View {
        let icon: some View = Group {
            if let emoji = item?.emoji, !emoji.isEmpty {
                Text(emoji).font(.body)
            } else if let ref = NamedIcon.reference(item?.icon) {
                /*
                 THROUGH THE RESOLVER, not `Image(systemName:)`. The console writes
                 `icon: "check"`, which is a LUCIDE name and not an SF Symbol (`checkmark` is), so
                 this drew nothing at all and the icon vanished silently. `IconView` maps the name
                 through the lucide/material tables and falls back to an emoji and then a visible
                 placeholder, so an unmapped name is SEEN rather than lost.
                 */
                IconView(ref: ref, size: 17)
                    .foregroundColor(iconColor ?? (isIncluded
                        ? Color(hex: (AppDNA.brandAccentHex ?? "#6366F1"))
                        : Color(hex: itemExcludedColor ?? "#EF4444")))
            } else if let imageUrl = item?.image_url, let url = URL(string: imageUrl) {
                BundledAsyncImage(url: url) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 20, height: 20)
                .clipShape(imageClipShape)
            } else {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isIncluded
                        ? (iconColor ?? Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                        : Color(hex: itemExcludedColor ?? "#EF4444").opacity(0.5))
                    .font(.body)
            }
        }

        // The icon's authored container, applied to whichever of the two shapes is drawn.
        // The authored circle background stays its own thing: an author can have both.
        Group {
            if let bgHex = iconBgColor {
                ZStack {
                    Circle()
                        .fill(Color(hex: bgHex).opacity(iconBgOpacity))
                        .frame(width: iconBgSize, height: iconBgSize)
                    icon
                }
                .frame(width: iconBgSize, height: iconBgSize)
            } else {
                icon
            }
        }
        .applyElementStyle(sectionStyle?.elements?["icon"]?.container)
    }
}
