import SwiftUI

/**
 A FORM STEP'S FIELD COLOURS, honoured on iOS.

 `FormFieldStyle` carries `border_color`, `focus_border_color`, `background_color`, `corner_radius`
 and an opaque `error_style` map. Android's `textFieldColorsFor` has read all of them since it
 shipped; iOS's form step used `.textFieldStyle(.roundedBorder)` — the SYSTEM style — and honoured
 **none**. So an author styling a form field saw it work on one platform and not the other, and
 `focus_border_color` / `error_style` were reported as "read by Android, by nothing on iOS".

 🔴 UNAUTHORED FIELDS MUST NOT MOVE. Every iOS form step that exists today draws the system
 rounded border, and this change would otherwise restyle all of them. So the custom chrome applies
 only when the author set SOMETHING — `hasAuthoredChrome` — and everything else keeps
 `.roundedBorder` exactly as before. That is also why the fallback border is a parameter: the text
 area's existing look (grey at 30%) is not the text field's.

 🔴 `error_style` is an opaque map by design — the schema lets an author pass any sub-keys — so it
 is read the way Android reads it: `color` first, then `border_color`. A key neither platform knows
 is ignored rather than guessed at.
 */
extension View {
    func appdnaFieldChrome(
        _ field: FormField,
        focused: Bool,
        hasError: Bool,
        fallbackBorder: Color? = nil
    ) -> some View {
        modifier(AppDNAFieldChrome(
            style: field.style,
            focused: focused,
            hasError: hasError,
            fallbackBorder: fallbackBorder
        ))
    }
}

struct AppDNAFieldChrome: ViewModifier {
    let style: FormFieldStyle?
    let focused: Bool
    let hasError: Bool
    let fallbackBorder: Color?

    /// Whether the author set anything at all. Nothing set → the system style, unchanged.
    private var hasAuthoredChrome: Bool {
        guard let style else { return false }
        return style.border_color != nil
            || style.focus_border_color != nil
            || style.background_color != nil
            || style.corner_radius != nil
            || errorHex != nil
    }

    /// Android reads `color` then `border_color` out of the opaque map; this mirrors it exactly.
    private var errorHex: String? {
        guard let map = style?.error_style?.value as? [String: Any] else { return nil }
        return (map["color"] as? String) ?? (map["border_color"] as? String)
    }

    private var cornerRadius: CGFloat { CGFloat(style?.corner_radius ?? 8) }

    private var borderColor: Color? {
        if hasError, let errorHex { return Color(hex: errorHex) }
        if focused, let focusHex = style?.focus_border_color { return Color(hex: focusHex) }
        if let borderHex = style?.border_color { return Color(hex: borderHex) }
        return fallbackBorder
    }

    func body(content: Content) -> some View {
        if hasAuthoredChrome {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(style?.background_color.map { Color(hex: $0) } ?? Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(borderColor ?? Color.gray.opacity(0.3), lineWidth: focused ? 2 : 1)
                )
        } else if let fallbackBorder {
            // The text area's existing look, kept verbatim.
            content.overlay(
                RoundedRectangle(cornerRadius: 8).stroke(fallbackBorder, lineWidth: 1)
            )
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}
