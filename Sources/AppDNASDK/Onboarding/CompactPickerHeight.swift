import CoreGraphics

/*
 #1052 — HOW TALL A COMPACT DATE PILL IS, as one rule both platforms call.

 iOS has read `field_style.height` as a `sm | md | lg` shorthand since the compact picker shipped,
 alongside a numeric `field_config.input_height` that takes precedence. Android read neither, and
 no console control wrote either — so a real iOS capability was reachable by nobody and ignored by
 the other platform. Three surfaces, three answers.

 The rule lives here rather than inside the view for the reason #998's `LikertScaleRule` does: a
 clamp written twice in two languages agrees until one of them is edited (#1037), and the shared
 behavioural fixture has to call the same function the renderer calls or it only agrees with
 itself.

 🔴 The wheel and graphical variants set their own height and ignore all of this. Only the compact
 pill asks.
 */
public enum CompactPickerHeight {
    /// What the pill measures when nothing is authored.
    public static let unset: CGFloat = 44

    /// `sm` · `md` · `lg`, matched case-insensitively. Anything else is unauthored.
    public static func semantic(_ token: String?) -> CGFloat? {
        switch token?.lowercased() {
        case "sm": return 36
        case "md": return 44
        case "lg": return 56
        default: return nil
        }
    }

    /**
     The height to draw.

     A NUMBER wins over the token, because `field_config.input_height` is the more specific of the
     two and that is the precedence iOS already shipped. A number that is absurd is ignored rather
     than drawn: a pill cannot usefully be 2 points or 2000, and a config that says so is a
     mistake, not an instruction.
     */
    public static func resolve(numeric: Double?, token: String?) -> CGFloat {
        if let n = numeric, n >= 20, n <= 200 { return CGFloat(n) }
        return semantic(token) ?? unset
    }
}
