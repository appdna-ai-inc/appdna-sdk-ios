import Foundation

/**
 WHETHER Google's four-colour mark needs a white chip behind it.

 🔴 The official mark is red, yellow, green and BLUE, and the Google provider's default
 button fill is `#4285F4`. On that fill the blue arm and crossbar vanish into the button and the
 mark reads as a "C": intact at 4×, illegible at render size. Google's own "Sign in with Google"
 guidelines put the mark on a white surface — a white button, or a white circular chip when the
 button itself is coloured — so this is off-guideline as well as unreadable, and it is the shape
 an integrator's reviewer notices.

 The rule, and each clause is a decision rather than a default:

 - a MONOCHROME `icon_style` is an explicit author choice and Google's guidelines allow a white or
   black mark on a coloured button, so it keeps the letterform and gets no chip;
 - an OUTLINED or MINIMAL button has no fill of its own, so the surface behind the mark is the
   step's and the author owns it — a chip there would be the SDK overruling a design it cannot
   see;
 - a FILLED button gets the chip when its own background is too dark to read a blue arm against.

 `0.5` is the same relative-luminance threshold the SDK already uses to pick status-bar icons, and
 `#FFFFFF` (1.0) and `#4285F4` (≈0.25) sit either side of it by a wide margin — the boundary is
 not load-bearing for any real brand colour.

 Shared with Android via `google_mark_chip`, because "which surface is light enough" is exactly
 the kind of rule two platforms state differently: `collapse_on_scroll`,
 `background_full_bleed` and the celebration palette each drifted that way.
 */
public enum GoogleMarkChip {

    /// Relative luminance at or above which a surface can carry the mark unaided.
    public static let lightEnough: Double = 0.5

    /// `#RRGGBB` → WCAG relative luminance, or nil when it is not a colour.
    public static func luminance(_ hex: String?) -> Double? {
        guard var h = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 8 { h = String(h.prefix(6)) }   // #RRGGBBAA — the alpha is not a colour
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        func channel(_ c: Int) -> Double {
            let s = Double(c) / 255.0
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = channel((v >> 16) & 0xFF), g = channel((v >> 8) & 0xFF), b = channel(v & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /**
     - Parameters:
       - buttonStyle: `filled` | `outlined` | `minimal`
       - backgroundHex: the button's RESOLVED background, authored or brand default
       - iconStyle: the provider's `icon_style`, if any
     */
    public static func isNeeded(buttonStyle: String?, backgroundHex: String?, iconStyle: String?) -> Bool {
        if let iconStyle, iconStyle.hasPrefix("monochrome") { return false }
        let style = buttonStyle ?? "filled"
        if style == "outlined" || style == "minimal" { return false }
        // An unreadable background is not an argument for drawing a chip over a design nobody
        // chose: with nothing to measure, the brand default is what gets drawn, and that IS dark.
        guard let l = luminance(backgroundHex) else { return true }
        return l < lightEnough
    }
}
