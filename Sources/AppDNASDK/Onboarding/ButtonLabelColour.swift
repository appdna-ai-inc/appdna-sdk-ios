import Foundation

/**
 WHICH authored colour a button's label draws in, in ONE place both platforms can be held to.

 🔴 The two renderers disagreed, and the Kotlin documented the disagreement as if it were parity.
 On iOS the button's own `text_color` already beat the generic Typography colour, because the
 "Text" picker sits beside "Background" on the button panel and a control that loses silently is a
 control that does not exist. Android kept a later `style = effectiveStyle.copy(color = block.style
 ?.color ?: textColor)`, so `style.color` won there — the opposite rule, in a comment that still
 described iOS's OLD behaviour. A button with both set rendered in two different colours on the two
 platforms, and the console could not tell an author which one they would get.

 It is a function rather than two inline expressions so a shared fixture can drive the REAL
 decision on both platforms instead of re-implementing it (CLAUDE.md Rule 25: a test that
 re-implements the thing under test can only ever agree with it).

 Returns `nil` when neither is authored, which means "leave the variant's own content colour
 alone" — on iOS `.foregroundColor(nil)` RESETS rather than inherits, so the caller must branch on
 nil rather than pass it.
 */
public enum ButtonLabelColour {

    /// - Parameters:
    ///   - textColor: the button panel's own "Text" picker (`block.text_color`).
    ///   - styleColor: the Typography panel's "Color" (`block.style.color`).
    /// - Returns: the hex to draw the label in, or `nil` to leave the variant's colour in charge.
    public static func resolve(textColor: String?, styleColor: String?) -> String? {
        // Specificity decides, the rule used everywhere else here: the control that sits ON the
        // element beats the generic one. An EMPTY string is not an authored colour — the console
        // writes "" when a picker is cleared.
        if let textColor, !textColor.isEmpty { return textColor }
        if let styleColor, !styleColor.isEmpty { return styleColor }
        return nil
    }

    /// The colour the label actually draws in: `text_color ?? style.color ?? the variant's default` —
    /// the fill colour for `outline` and `text` buttons, white for a filled one.
    ///
    /// A Typography `style` WITHOUT a colour is not a colour. iOS let `applyTextStyle` bake `.primary`
    /// into the label in that case, which beat the variant default — near-black text on a dark fill in a
    /// light appearance, while Android drew white. Both renderers draw the label in THIS.
    static func label(textColor: String?, styleColor: String?, variant: String, fillHex: String) -> String {
        if let authored = resolve(textColor: textColor, styleColor: styleColor) { return authored }
        return variant == "outline" || variant == "text" ? fillHex : "#FFFFFF"
    }
}


/**
 WHETHER a block's own background reaches the screen edges, and the inset it has to cancel to do it.

 🔴 "the shared background behind the buttons never reaches the screen edges, even with the
 width set to 100%". It could not: `element_width: 100%` is 100% of the CONTENT COLUMN, and the
 column is inset by the step's horizontal padding. A background that has to pass that inset is a
 different thing from a width, which is why it needs its own control rather than a bigger number.

 The inset is 20 — the step's own horizontal content padding, and the same value the map's full
 bleed cancels (`map_full_bleed`). It is named here so the two platforms and the console preview
 cannot drift to three different numbers.
 */
public enum BlockFullBleed {
    /**
     The step's horizontal content padding, which a full-bleed background has to cancel.

     🔴 IT IS RESPONSIVE, and a constant was wrong. The first version used 20 — the number the map's
     own full bleed cancels — and the device showed the background still inset by about eleven
     points, because `ThreeZoneStepLayout` insets content by `max(24, screenWidth * 0.08)`: 31.4pt
     on a 393pt iPhone, not 20. A full bleed that cancels the wrong number is a full bleed that does
     not reach the edge, which is the defect it was written to fix.

     The layout reads this function too, so the two cannot drift apart again. Android computes the
     same thing from its own `screenWidthDp`.
     */
    public static func stepHorizontalInset(screenWidth: Double) -> Double {
        max(24, screenWidth * 0.08)
    }

    /// `field_config.background_full_bleed`, read the same way on both platforms.
    public static func isOn(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        // The console writes a boolean; a string sneaks in through hand-authored config and an
        // import, and "true" meaning false is the kind of silence this codebase keeps paying for.
        if let s = value as? String { return s == "true" || s == "1" }
        if let n = value as? Double { return n != 0 }
        return false
    }

    // MARK: Per-side bleed

    /// The most a side can reach by an authored value, in points.
    public static let maxBleed: Double = 400

    /// One side as authored: the screen edge, or a number of points (0 = not at all).
    public enum Side: Equatable {
        case edge
        case points(Double)
    }

    /// How far the background reaches past the block on each side, in points.
    public struct Insets: Equatable {
        public var top: Double
        public var right: Double
        public var bottom: Double
        public var left: Double
        public static let zero = Insets(top: 0, right: 0, bottom: 0, left: 0)
        public var isZero: Bool { top == 0 && right == 0 && bottom == 0 && left == 0 }
    }

    static let sideKeys: [String: String] = [
        "top": "background_bleed_top", "bottom": "background_bleed_bottom",
        "left": "background_bleed_left", "right": "background_bleed_right",
    ]

    /**
     One side as authored, or `nil` when the side is not authored at all (the caller then applies
     its fallback). Anything that is neither `"edge"` nor a positive number is an AUTHORED 0: an
     explicit value must beat `background_full_bleed`, or an author could never take one side back
     off. Mirrors `src/lib/onboarding/block-bleed.ts` `bleedSide` and Android.
     */
    static func side(_ raw: Any?) -> Side? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let s = raw as? String, s == "edge" { return .edge }
        var n = Double.nan
        if raw is Bool {
            n = .nan
        } else if let d = raw as? Double {
            n = d
        } else if let i = raw as? Int {
            n = Double(i)
        } else if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            n = t.isEmpty ? .nan : (Double(t) ?? .nan)
        }
        guard n.isFinite, n > 0 else { return .points(0) }
        return .points(min(n, maxBleed))
    }

    /// The side the renderer applies, after the `background_full_bleed` fallback for left and right.
    static func effectiveSide(_ fieldConfig: [String: Any]?, _ name: String) -> Side {
        if let authored = side(fieldConfig?[sideKeys[name] ?? ""]) { return authored }
        if (name == "left" || name == "right") && isOn(fieldConfig?["background_full_bleed"]) { return .edge }
        return .points(0)
    }

    /// Whether the top or bottom reaches an edge, so the renderer has to measure where the block sits.
    public static func needsMeasuredEdge(_ fieldConfig: [String: Any]?) -> Bool {
        effectiveSide(fieldConfig, "top") == .edge || effectiveSide(fieldConfig, "bottom") == .edge
    }

    /**
     How far the background reaches on each side. `"edge"` is the step's horizontal inset on the
     left and right, and the MEASURED distance from the block's slot to the surface edge on the top
     and bottom. Pinned by the shared fixture `dto_parsing/block_background_bleed`.
     */
    public static func resolve(fieldConfig: [String: Any]?, stepInset: Double, edgeTop: Double, edgeBottom: Double) -> Insets {
        func value(_ name: String, _ edge: Double) -> Double {
            switch effectiveSide(fieldConfig, name) {
            case .edge: return max(0, edge)
            case .points(let p): return p
            }
        }
        return Insets(
            top: value("top", edgeTop),
            right: value("right", stepInset),
            bottom: value("bottom", edgeBottom),
            left: value("left", stepInset)
        )
    }
}
