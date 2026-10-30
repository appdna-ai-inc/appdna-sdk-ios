import Foundation

/**
 The brand colours a social-login provider falls back to when an author sets none.

 🔴 These were written out TWICE on this platform once the chip rule needed a measurable
 background: once as `Color`s in the renderer and once as hexes beside them. Two copies of a
 constant table is how `#24292E` and `#24292F` ended up one character apart across platforms, and
 `check:authorability` reads a bare hex in a renderer as a colour an author cannot reach — which
 is true of a brand default and useless to say, because the author's control is the provider's
 own `bg_color` and this list is its fallback.

 So the table lives here, in `Core/`, and the renderer builds its `Color` from it. One list, one
 place, and the sweep is left to find the literals it exists to find.

 `nil` means "no fill" — an outlined or minimal button draws the step's own surface.
 */
public enum SocialBrandDefaults {

    /// The resolved background for a provider, or `nil` when the style has no fill.
    public static func backgroundHex(type: String, style: String, blockAccent: String? = nil, blockBg: String? = nil, brandAccent: String? = nil) -> String? {
        if style == "outlined" || style == "minimal" { return nil }
        switch type {
        case "apple": return "#000000"
        case "google": return "#4285F4"
        case "facebook": return "#1877F2"
        case "github": return "#24292F"
        default:
            if let hex = blockAccent, !hex.isEmpty { return hex }
            if let hex = blockBg, !hex.isEmpty { return hex }
            return brandAccent ?? "#6366F1"
        }
    }
}
