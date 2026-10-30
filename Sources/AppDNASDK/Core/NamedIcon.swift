import Foundation

/// What a BARE ICON STRING on a paywall item means.
///
/// 🔴 A NAME IS NOT AN EMOJI AND IS NOT AN SF SYMBOL. The console writes `icon: "check"` on a
/// features item, and before this each platform guessed differently and both guessed wrong:
///
///   * iOS drew `Image(systemName: "check")` — not an SF Symbol (`checkmark` is), so NOTHING drew
///     and the icon vanished silently;
///   * Android drew the string as TEXT, so a user read the word **"check"** five times down the
///     page where the feature list should be.
///
/// `resolveIcon` cannot be used directly here: given a bare `String` it answers
/// `library: "emoji"`, which is right for "✅" and is exactly the Android defect for "check".
///
/// So a bare name is resolved against the mapping tables that already exist, in one place, and the
/// answer is an `IconReference` the shared `IconView` knows how to draw — including its documented
/// fallback ladder (emoji, then a question-mark circle) for a name nothing maps.
enum NamedIcon {

    /// An `IconReference` for a bare icon string, or nil when there is nothing to draw.
    ///
    /// An emoji stays an emoji. A name that either table knows becomes that library's reference.
    /// A name NEITHER table knows still becomes a `lucide` reference rather than an emoji one,
    /// because `IconView`'s lucide arm falls back to the emoji table and then to a visible
    /// placeholder — whereas the emoji arm would print the name as prose, which is the defect.
    static func reference(_ raw: String?, color: String? = nil, size: Double? = nil) -> IconReference? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEmojiGlyph(name) {
            return IconReference(library: "emoji", name: name, color: color, size: size)
        }
        if IconMapping.lucideToSFSymbol[name] != nil || IconMapping.lucideToEmoji[name] != nil {
            return IconReference(library: "lucide", name: name, color: color, size: size)
        }
        if IconMapping.materialToSFSymbol[name] != nil || IconMapping.materialToEmoji[name] != nil {
            return IconReference(library: "material", name: name, color: color, size: size)
        }
        return IconReference(library: "lucide", name: name, color: color, size: size)
    }

    /// Whether the string is an emoji glyph rather than a name. Mirrors Android `isEmojiGlyph`.
    static func isEmojiGlyph(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first else { return false }
        // Anything outside ASCII that is a symbol or sits in an emoji plane. A NAME is ASCII
        // letters and hyphens, so this separates the two without a table.
        return first.value > 127 && (first.properties.isEmoji || first.value >= 0x1F000)
    }
}
