import Foundation

/// A row's own fill, as the console's Row Background control authors it: `field_config.bg_color` and
/// `field_config.background_opacity`. Shared with Android and driven by the `row_background_fill` fixture.
///
/// nil means no fill (absent or empty `bg_color`). The opacity defaults to 1, is clamped to 0...1, and
/// MULTIPLIES the colour's own alpha: `#2563EB80` at 0.5 is a quarter-opaque fill on both platforms.
enum RowFill {
    static func resolve(_ cfg: [String: AnyCodable]?) -> (hex: String, opacity: Double)? {
        guard let raw = cfg?["bg_color"]?.value as? String else { return nil }
        let hex = raw.trimmingCharacters(in: .whitespaces)
        guard !hex.isEmpty else { return nil }
        let opacity = min(max(cfgDouble(cfg?["background_opacity"]) ?? 1, 0), 1)
        return (hex, opacity)
    }
}
