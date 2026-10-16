import SwiftUI

/**
 #891 — a text colour nobody authored, resolved from the BACKGROUND rather than from the phone.

 A paywall's defaults assumed a background instead of reading one. The unselected plan tile used
 `.primary` and the header title used `.primary` too — system colours, black in light appearance
 and white in dark — while the paywall itself forces no colour scheme. So a paywall authored with a
 dark background, opened on a phone set to light appearance, drew BLACK text on it. Android made
 the opposite assumption in the same places (`MaterialTheme.colorScheme.onSurface` for the header,
 a hard-coded `Color.White` on the tiles), so one published document produced two different screens,
 and on one of them the words were gone.

 The rule here is the server's, so the three agree: try `#111827`, then `#FFFFFF`, take the first
 that passes WCAG AA against the background, and if neither does, take whichever is further away.
 `src/lib/ui/editors/design-controls/readable-text.ts` is the same ladder minus the brand palette,
 which an SDK does not have.

 Driven by the `paywall_default_text_colour` shared fixture on both platforms.
 */
enum PaywallTextDefaults {
    static let dark = "#111827"
    static let light = "#FFFFFF"

    /// The hex a default text colour should take on `background`, or `light` when it cannot parse.
    static func readableHex(on background: String?) -> String {
        guard let bg = background, let bgL = luminance(bg) else { return light }
        let darkRatio = contrast(luminance(dark)!, bgL)
        let lightRatio = contrast(luminance(light)!, bgL)
        if darkRatio >= 4.5 { return dark }
        if lightRatio >= 4.5 { return light }
        return lightRatio >= darkRatio ? light : dark
    }

    /// The same answer as a `Color`, for a renderer to apply directly.
    static func readable(on background: String?) -> Color {
        Color(hex: readableHex(on: background))
    }

    /// A translucent tile over a page: what the eye actually sees, so the text is judged on THAT.
    static func composite(_ foreground: String?, over background: String?, alpha: Double) -> String? {
        guard let fg = foreground, let bg = background,
              let f = channels(fg), let b = channels(bg) else { return background }
        let mix = { (a: Double, c: Double) in a * alpha + c * (1 - alpha) }
        return String(
            format: "#%02X%02X%02X",
            Int((mix(f.0, b.0) * 255).rounded()),
            Int((mix(f.1, b.1) * 255).rounded()),
            Int((mix(f.2, b.2) * 255).rounded()),
        )
    }

    // MARK: - WCAG

    private static func channels(_ hex: String) -> (Double, Double, Double)? {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count >= 6, let v = UInt32(h.prefix(6), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    private static func luminance(_ hex: String) -> Double? {
        guard let (r, g, b) = channels(hex) else { return nil }
        let lin = { (c: Double) in c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }
}
