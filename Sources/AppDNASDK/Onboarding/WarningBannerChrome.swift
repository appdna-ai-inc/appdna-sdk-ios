import Foundation

/// One background on a warning banner.
///
/// The banner draws its own card, and the Design panel's background, border and corner radius land
/// in `block_style`, which every block wraps itself in. Drawing both put a tinted card inside a
/// filled, rounded wrapper. `block_style` now styles the card, and the banner's own settings win
/// where both are set. With no `block_style` this draws exactly what the banner drew before.
///
/// Twin of Android `WarningBannerChrome` and the console's `resolveWarningBannerChrome`; shared
/// fixture `dto_parsing/warning_banner_chrome_resolution`.
enum WarningBannerChrome {
    enum CardFill: String { case own, tint, none }

    struct Resolved {
        let radius: Double
        let cardFill: CardFill
        let cardBorder: Bool
        let wrapperFill: Bool
        let wrapperBorder: Bool
        let wrapper: BlockStyle?
    }

    static func resolve(block: ContentBlock) -> Resolved {
        resolve(blockStyle: block.block_style, bgColor: block.bg_color, cornerRadius: cfgDouble(block.field_config?["banner_corner_radius"]), borderWidth: cfgDouble(block.field_config?["banner_border_width"]))
    }

    static func resolve(blockStyle: BlockStyle?, bgColor: String?, cornerRadius: Double?, borderWidth: Double?) -> Resolved {
        let radius = cornerRadius ?? blockStyle?.border_radius ?? 12
        let hasOwnFill = !isTransparent(bgColor)
        let styleFill = blockStyle?.background_gradient != nil || !isTransparent(blockStyle?.background_color)
        let wrapperFill = !hasOwnFill && styleFill
        let styleBorder = (blockStyle?.border_width ?? 0) > 0
        let wrapperBorder = borderWidth == nil && styleBorder

        var wrapper = blockStyle
        wrapper?.border_radius = radius
        if !wrapperFill {
            wrapper?.background_color = nil
            wrapper?.background_gradient = nil
        }
        if !wrapperBorder {
            wrapper?.border_width = nil
            wrapper?.border_color = nil
            wrapper?.border_style = nil
        }
        return Resolved(
            radius: radius,
            cardFill: hasOwnFill ? .own : (wrapperFill ? .none : .tint),
            cardBorder: !wrapperBorder,
            wrapperFill: wrapperFill,
            wrapperBorder: wrapperBorder,
            wrapper: wrapper
        )
    }

    private static func isTransparent(_ color: String?) -> Bool {
        guard let c = color?.lowercased(), !c.isEmpty else { return true }
        return c == "transparent" || c == "#00000000"
    }
}

/// What a standalone `toggle` reads from `field_config`. Each colour falls back to what the toggle
/// drew before, and `action` names the element interaction the host receives when it is switched.
/// Twin of Android `ToggleSettings`; shared fixture `dto_parsing/toggle_settings_resolution`.
struct ToggleSettings {
    let onColor: String?
    let labelColor: String?
    let descriptionColor: String?
    let action: String?

    init(fc: [String: AnyCodable]?) {
        func nonEmpty(_ raw: Any?) -> String? {
            guard let s = raw as? String, !s.isEmpty else { return nil }
            return s
        }
        onColor = nonEmpty(fc?["toggle_on_color"]?.value)
        labelColor = nonEmpty(fc?["toggle_label_color"]?.value)
        descriptionColor = nonEmpty(fc?["toggle_description_color"]?.value)
        action = nonEmpty(fc?["toggle_action"]?.value)
    }
}
