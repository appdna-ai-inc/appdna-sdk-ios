import SwiftUI

/**
 The ✕ that closes an onboarding flow, with its authored style.

 🔴 Every value here was hardcoded: `Image(systemName: "xmark")` at size 14 in `.secondary`
 inside a 44×44 frame, with the row inset 8pt from the screen edge. The report named all of it —
 "its size, its background color and the color of the X cannot be set, and it is pushed as far as
 possible into the top-right corner, which makes it hard to tap".

 The 44×44 frame STAYS whatever the glyph size is: it is the minimum tappable target Apple's own
 guidance asks for, and an author shrinking the glyph must not shrink the hit area with it. A
 background colour is drawn inside that frame at the glyph's own size plus padding, so a small ✕ on
 a circle still has a full-size target around it.
 */
struct DismissGlyph: View {
    let style: DismissButtonStyle?
    var fallbackSize: CGFloat?
    var fallbackColor: Color?

    init(style: DismissButtonStyle?, fallbackSize: CGFloat? = nil, fallbackColor: Color? = nil) {
        self.style = style
        self.fallbackSize = fallbackSize
        self.fallbackColor = fallbackColor
    }

    private var size: CGFloat { style?.icon_size ?? fallbackSize ?? 14 }
    private var colour: Color {
        if let hex = style?.icon_color, !hex.isEmpty { return Color(hex: hex) }
        return fallbackColor ?? .secondary
    }
    private var background: Color? {
        guard let hex = style?.bg_color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        Group {
            if let glyph = style?.icon, !glyph.isEmpty {
                Text(glyph).font(.system(size: size, weight: .semibold)).foregroundColor(colour)
            } else {
                Image(systemName: "xmark").font(.system(size: size, weight: .semibold)).foregroundColor(colour)
            }
        }
        .padding(background == nil ? 0 : size * 0.5)
        .background(
            Group {
                if let bg = background {
                    RoundedRectangle(cornerRadius: style?.bg_radius ?? size)
                        .fill(bg)
                }
            }
        )
        // The tap target never shrinks with the glyph.
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}
