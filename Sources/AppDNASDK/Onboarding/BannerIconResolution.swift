import Foundation

/**
 WHICH mark a warning/info banner draws, and at what size.

 🔴 #1005 — reported against a rebuild of a real app's info banner, which carries the app's own
 icon. The console offered ten emoji presets and a box to paste any other emoji, which makes the
 capability visible (that was the #601 fix) and is still not a way to set a brand's mark. So an
 image can now be uploaded, and the precedence has to be identical on both platforms: an uploaded
 URL wins, an empty one falls back to the authored glyph, and an unauthored glyph falls back to the
 variant's own icon — which the caller passes in, because the variant table lives with the colours.

 The SIZE is here too, and it is the part that would otherwise drift. 18 is what the glyph has
 always drawn at and has to stay the default, or every published banner silently restyles; but an
 uploaded PNG at 18pt is unreadable, so the same number has to be settable and has to apply to
 both. One function, driven by `banner_icon_resolution`, so iOS and Android cannot disagree — which
 is exactly what `collapse_on_scroll` (#993), `label_bg_color` and `blur_background` each did.
 */
public enum BannerIconResolution {

    /// What the renderer should draw.
    public enum Mark: Equatable {
        /// Nothing — the author hid the icon.
        case none
        /// An uploaded image at this URL.
        case image(String)
        /// A text glyph (an emoji, or the variant's default).
        case glyph(String)
    }

    /// The size the glyph has always drawn at. Also the default for an uploaded image, so that
    /// nothing changes until an author sets one.
    public static let defaultSize: Double = 18

    /// `size` is clamped to the range the console's control offers, so a hand-written document
    /// cannot produce a 2000pt icon that pushes the message off the card.
    public static func size(_ authored: Double?) -> Double {
        guard let authored, authored > 0 else { return defaultSize }
        return min(max(authored, 8), 96)
    }

    public static func mark(hidden: Bool, iconURL: String?, glyph: String?, variantDefault: String) -> Mark {
        if hidden { return .none }
        if let iconURL, !iconURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .image(iconURL)
        }
        if let glyph, !glyph.isEmpty { return .glyph(glyph) }
        return .glyph(variantDefault)
    }
}
