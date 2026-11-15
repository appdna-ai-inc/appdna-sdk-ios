import Foundation

/**
 WHICH of Facebook's two official marks a Social Login button draws.

 The Facebook provider drew a bold letter "f": not the mark, and Meta's brand guidelines say
 outright "don't use just the 'f' from our logo". The SDK now ships Meta's official logo pack
 files, unmodified, and picks between the two expressions Meta publishes:

 - **primary**: the Facebook Blue circle with a white "f", for light surfaces;
 - **secondary**: the white circle with a transparent "f", for a Facebook Blue or dark surface.

 Each clause is a decision rather than a default:

 - `monochrome_light` asks for a white icon, and the secondary mark IS the white mark;
 - `monochrome_dark` asks for a black icon, but Meta allows the logo only in Facebook Blue or
   white ("do not recolor our logo"), so it gets the primary mark, the closest compliant one;
 - an OUTLINED or MINIMAL button has no fill of its own, so the primary mark is drawn as Meta's
   primary use, and the author owns the surface behind it;
 - a FILLED button gets the secondary mark when its own background is dark (the same 0.5
   relative-luminance line `GoogleMarkChip` uses). The default Facebook fill `#1877F2` is dark,
   so the default button draws Meta's own secondary use, a white logo on Facebook Blue. An
   absent or unreadable background means that default is what gets drawn.

 Shared with Android and the console via the `facebook_mark_variant` fixture.
 */
public enum FacebookMark {
    public enum Variant: String {
        case primary
        case secondary

        /// The bundled file, byte-identical to Meta's logo pack.
        public var resourceName: String { "appdna_facebook_mark_\(rawValue)" }
    }

    /// Drawn size in points. Meta's digital minimum is 16px wide.
    public static let size: Double = 20
    /// Meta: "at least half a logo distance away from any other content".
    public static let spacing: Double = size / 2

    public static func variant(buttonStyle: String?, backgroundHex: String?, iconStyle: String?) -> Variant {
        if iconStyle == "monochrome_light" { return .secondary }
        if iconStyle == "monochrome_dark" { return .primary }
        let style = buttonStyle ?? "filled"
        if style == "outlined" || style == "minimal" { return .primary }
        guard let l = GoogleMarkChip.luminance(backgroundHex) else { return .secondary }
        return l < GoogleMarkChip.lightEnough ? .secondary : .primary
    }
}
