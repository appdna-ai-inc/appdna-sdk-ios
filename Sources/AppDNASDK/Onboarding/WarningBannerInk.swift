import Foundation

/// The ink an unstyled `warning_banner` draws its message and subtitle in.
///
/// The banner's default fill is its accent at 14% opacity, so what shows through is almost entirely the
/// surface behind it. The message used to default to `#FFFFFF` whatever that surface was: on a light
/// step the amber tint composites to about `#FEF1DD`, and white on it measures 1.11:1 — invisible.
///
/// The rule, shared with Android and driven by the `warning_banner_default_ink` fixture:
/// an authored `text_color` wins; else the ink is picked from the banner's own `bg_color` when one is
/// authored (it is opaque, so it is what the text sits on); else from what is behind the banner. A
/// dark surface keeps the white every published banner on a dark step already draws.
enum WarningBannerInk {
    static let lightInkHex = "#FFFFFF"
    static let darkInkHex = "#111827"

    static func resolve(
        textColor: String?, bgColor: String?,
        behind: GoogleMapsAttribution.Backdrop, darkAppearance: Bool
    ) -> String {
        if let t = textColor?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        let surface: GoogleMapsAttribution.Backdrop
        if let bg = bgColor?.trimmingCharacters(in: .whitespaces), !bg.isEmpty,
           !["transparent", "clear"].contains(bg.lowercased()) {
            surface = .plain(hex: bg)
        } else {
            surface = behind
        }
        return GoogleMapsAttribution.needsLightInk(on: surface, darkAppearance: darkAppearance) ? lightInkHex : darkInkHex
    }
}
