import Foundation

/// What a block's container style (`field_config.container_*`, `blur_background`) draws, or nil when it draws
/// nothing. Shared with Android (`BlockContainerStyle`) and driven by the `block_container_style` fixture.
///
/// Opt-in: a fill only for a visible `container_bg_color` (not empty, `#ffffff` or `transparent`), a border
/// only with both a positive width and a colour. `container_opacity` wins over `background_opacity`; both
/// default to 1. It applies to every block, nested ones included: a container's children are drawn with it
/// on both platforms.
enum BlockContainerStyle {
    struct Resolved: Equatable {
        let fillHex: String?
        let opacity: Double
        let blur: Bool
        let borderWidth: Double?
        let borderHex: String?
        let cornerRadius: Double
    }

    static func resolve(_ cfg: [String: AnyCodable]?) -> Resolved? {
        let blur = (cfg?["blur_background"]?.value as? Bool) == true
        let bg = cfg?["container_bg_color"]?.value as? String
        let fill: String? = {
            guard let bg, !bg.isEmpty else { return nil }
            let l = bg.lowercased()
            return l == "#ffffff" || l == "transparent" ? nil : bg
        }()
        let bw = cfgDouble(cfg?["container_border_width"]).flatMap { $0 > 0 ? $0 : nil }
        let bc = (cfg?["container_border_color"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        let hasBorder = bw != nil && bc != nil
        guard blur || fill != nil || hasBorder else { return nil }
        return Resolved(
            fillHex: fill,
            opacity: cfgDouble(cfg?["container_opacity"]) ?? cfgDouble(cfg?["background_opacity"]) ?? 1,
            blur: blur,
            borderWidth: hasBorder ? bw : nil,
            borderHex: hasBorder ? bc : nil,
            cornerRadius: cfgDouble(cfg?["container_corner_radius"]) ?? 0)
    }
}
