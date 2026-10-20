import Foundation

/*
 * 🔴 IT LIVES IN `Core/`, BESIDE THE OVERLAY THAT DRAWS IT, and that is deliberate.
 *
 * `check:authorability` sweeps the block, paywall and screen renderers asking "could an author
 * have set this colour?", and a seven-hex fallback list answers no — correctly, and uselessly:
 * the author's control is `particle_effect.colors`, one call away, and the list is its DEFAULT.
 * Putting the rule in `Onboarding/` made the sweep read 12 of these as controls nobody can reach.
 * The particle overlay has always lived in `Core/` for the same reason — it is not a block.
 */

/**
 WHICH COLOURS a celebration draws when a document authors none.

 🔴 #1040 — the two overlays disagreed, and nothing could see it. `ConfettiOverlay.swift` returned
 SwiftUI's semantic colours (`.red` is #FF3B30) and `ConfettiOverlay.kt` returned Compose's named
 constants (`Color.Red` is #FF0000) for four of the six, so every `fireworks` and every plain
 `confetti` with no authored `colors` — the default the editor produces — drew pure RGB on Android
 and Apple's palette on iOS. Four of seven values differed on the commonest type.

 An earlier Android pass had already committed to the HIG values in its own comment and converted
 only the three EXPLICIT hexes, leaving the four named constants. That is the shape this fixes:
 the values are now written out, in one place per platform, and `celebration_palette` asserts the
 two lists are identical rather than trusting two comments to agree.

 The hexes below are what SwiftUI's semantic colours resolve to in the light appearance, which is
 what the renderer drew before this type existed — so no authored document changes.
 */
public enum CelebrationPalette {

    /// The palette for a type, as an array of `#RRGGBB` strings.
    public static func fallback(type: String?) -> [String] {
        switch type ?? "confetti" {
        case "hearts": return ["#FF3B30", "#FF2D55", "#FF6B9D"]
        case "snow": return ["#FFFFFF", "#F2F2F2", "#E6E6E6"]
        case "sparkle": return ["#FFCC00", "#FF9500", "#FFD700"]
        case "fireworks": return ["#FF3B30", "#007AFF", "#34C759", "#FFCC00", "#AF52DE", "#FF9500"]
        default: return ["#FF3B30", "#007AFF", "#34C759", "#FFCC00", "#AF52DE", "#FF9500", "#FF2D55"]
        }
    }

    /// What a celebration actually draws: the authored colours, or the type's fallback.
    public static func colors(type: String?, authored: [String]?) -> [String] {
        if let authored, !authored.isEmpty { return authored }
        return fallback(type: type)
    }

    /**
     The glyph a type draws, or `""` for a filled circle.

     🔴 The two platforms branched on different questions. iOS asked `type == "confetti"` and drew
     a circle, else a glyph — so an UNKNOWN type (a document from a newer console, a typo) drew a
     bullet CHARACTER. Android asked whether its glyph table had an entry and drew a circle
     otherwise, so the same document drew a circle. Neither answer is wrong; having two is.
     Unknown falls back to the circle, which is what `confetti` — the default — already draws.
     */
    public static func glyph(type: String?) -> String {
        switch type ?? "confetti" {
        case "hearts": return "\u{2764}\u{FE0F}"
        case "snow": return "\u{2744}\u{FE0F}"
        case "sparkle": return "\u{2728}"
        case "fireworks": return "\u{1F386}"
        default: return ""
        }
    }
}
