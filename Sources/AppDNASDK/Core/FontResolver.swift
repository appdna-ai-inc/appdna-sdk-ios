import SwiftUI

/// Resolves platform-native font names from the cross-platform font value stored in config.
/// Only fonts natively available on iOS are supported — no custom font downloading.
enum FontResolver {

    /// Maps a cross-platform font identifier to a native iOS font family name.
    /// A `font_family` value may also be a hosted custom-font URL (.ttf/.otf) — in that
    /// case `FontLoader` downloads + registers it and we return its PostScript name (or
    /// fall back to the system font until the download completes).
    static func resolve(_ fontFamily: String?) -> String {
        guard let family = fontFamily else { return ".AppleSystemUIFont" }

        if FontLoader.isCustomFontURL(family) {
            return FontLoader.registeredName(forURL: family) ?? ".AppleSystemUIFont"
        }

        switch family {
        // System
        case "system", "-apple-system", "BlinkMacSystemFont":
            return ".AppleSystemUIFont"
        case "system-serif":
            return "New York"
        case "system-mono":
            return "SF Mono"
        // Sans-Serif
        case "helvetica-neue", "Helvetica Neue":
            return "Helvetica Neue"
        case "avenir", "Avenir":
            return "Avenir"
        case "avenir-next", "Avenir Next":
            return "Avenir Next"
        case "futura", "Futura":
            return "Futura"
        case "gill-sans", "Gill Sans":
            return "Gill Sans"
        case "verdana", "Verdana":
            return "Verdana"
        case "arial", "Arial":
            return "Arial"
        case "trebuchet", "Trebuchet MS":
            return "Trebuchet MS"
        // Serif
        case "georgia", "Georgia":
            return "Georgia"
        case "times", "Times New Roman":
            return "Times New Roman"
        case "palatino", "Palatino":
            return "Palatino"
        case "baskerville", "Baskerville":
            return "Baskerville"
        case "didot", "Didot":
            return "Didot"
        case "bodoni", "Bodoni 72":
            return "Bodoni 72"
        case "optima", "Optima":
            return "Optima"
        // Monospace
        case "courier-new", "Courier New":
            return "Courier New"
        case "menlo", "Menlo":
            return "Menlo"
        // Display
        case "copperplate", "Copperplate":
            return "Copperplate"
        case "chalkboard", "Chalkboard SE":
            return "Chalkboard SE"
        case "noteworthy", "Noteworthy":
            return "Noteworthy"
        case "snell", "Snell Roundhand":
            return "Snell Roundhand"
        case "sf-compact", "SF Compact Text":
            return "SF Compact Text"
        case "cochin", "Cochin":
            return "Cochin"
        case "iowan", "Iowan Old Style":
            return "Iowan Old Style"
        case "courier", "Courier":
            return "Courier"
        case "papyrus", "Papyrus":
            return "Papyrus"
        case "marker-felt", "Marker Felt":
            return "Marker Felt"
        case "academy-engraved", "Academy Engraved LET":
            return "Academy Engraved LET"
        // Google Fonts → fallback to system (not available natively)
        default:
            return ".AppleSystemUIFont"
        }
    }

    /// Returns a SwiftUI Font from config-supplied text style fields.
    static func font(family: String?, size: Double?, weight: Int?) -> Font {
        let resolved = resolve(family)
        let fontSize = CGFloat(size ?? 16)
        let fontWeight = swiftUIWeight(weight ?? 400)

        if resolved == ".AppleSystemUIFont" {
            return .system(size: fontSize, weight: fontWeight)
        }
        return .custom(resolved, size: fontSize).weight(fontWeight)
    }

    private static func swiftUIWeight(_ weight: Int) -> Font.Weight {
        switch weight {
        case ...199: return .ultraLight
        case 200...299: return .thin
        case 300...399: return .light
        case 400...499: return .regular
        case 500...599: return .medium
        case 600...699: return .semibold
        case 700...799: return .bold
        case 800...899: return .heavy
        default: return .black
        }
    }
}
