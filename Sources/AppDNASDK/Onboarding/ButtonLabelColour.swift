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
}
