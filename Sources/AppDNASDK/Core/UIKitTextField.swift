import SwiftUI
import UIKit

/// SwiftUI wrapper around `UITextField` that exposes the one property SwiftUI's
/// native `TextField` can't set: `keyboardAppearance`.
///
/// SwiftUI's `TextField` uses an internal UIKit input view whose appearance is
/// tied to the trait collection of the presenting view controller. If the host
/// app (or a third-party keyboard) tints the keyboard with a brand color, there
/// is no way to override it via SwiftUI modifiers alone. This wrapper gives
/// each field explicit control over `keyboardAppearance` (`.light` / `.dark` /
/// `.default`) without touching the rest of the app.
///
/// API surface kept minimal and mirror-compatible with the call sites in
/// `FormInputBlockViews.swift` — only the fields we actually need are forwarded.
struct UIKitTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
    var isSecure: Bool = false
    var textContentType: UITextContentType? = nil
    var autocorrection: Bool = true
    var autocapitalization: UITextAutocapitalizationType = .sentences
    var returnKeyType: UIReturnKeyType = .done
    var font: UIFont? = nil
    var textColor: UIColor? = nil
    var tintColor: UIColor? = nil
    var placeholderColor: UIColor? = nil
    /// Binding for focus. When this is set and the value is true, the field
    /// becomes first responder; when false, it resigns.
    var isFocused: Binding<Bool>? = nil
    /// Called when the user taps Return/Done on the keyboard.
    var onReturn: (() -> Void)? = nil
    /// Called on every editing change (after the text binding updates).
    var onEditingChanged: ((Bool) -> Void)? = nil
    /// Called after every text change the user makes, with whether the input method still has marked
    /// text (an IME composition) — so a commit that leaves the text as it was is reported too.
    var onCompositionChange: ((Bool) -> Void)? = nil
    /// A text set from the binding (not typed) clears the field's undo history, so shake-to-undo cannot
    /// bring back text the app replaced. UIKit drops it on such a set too on current iOS; this does not
    /// rely on that.
    var clearsUndoOnProgrammaticSet: Bool = false

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.delegate = context.coordinator
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textFieldDidChange(_:)),
            for: .editingChanged
        )
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyNonReactive(tf: tf)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        // Update text only if out of sync — avoids cursor jump on every keystroke
        Self.setText(text, of: tf, clearingUndo: clearsUndoOnProgrammaticSet)
        // Apply placeholder with optional color via attributedPlaceholder
        if let placeholderColor = placeholderColor {
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: placeholderColor]
            let attr = NSAttributedString(string: placeholder, attributes: attrs)
            if tf.attributedPlaceholder != attr {
                tf.attributedPlaceholder = attr
            }
        } else if tf.placeholder != placeholder {
            tf.placeholder = placeholder
        }
        if tf.keyboardType != keyboardType {
            tf.keyboardType = keyboardType
        }
        if tf.keyboardAppearance != keyboardAppearance {
            tf.keyboardAppearance = keyboardAppearance
        }
        if tf.isSecureTextEntry != isSecure {
            tf.isSecureTextEntry = isSecure
        }
        if tf.textContentType != textContentType {
            tf.textContentType = textContentType
        }
        let newAutocorrect: UITextAutocorrectionType = autocorrection ? .yes : .no
        if tf.autocorrectionType != newAutocorrect {
            tf.autocorrectionType = newAutocorrect
        }
        if tf.autocapitalizationType != autocapitalization {
            tf.autocapitalizationType = autocapitalization
        }
        if tf.returnKeyType != returnKeyType {
            tf.returnKeyType = returnKeyType
        }
        if let font = font, tf.font != font {
            tf.font = font
        }
        if let textColor = textColor, tf.textColor != textColor {
            tf.textColor = textColor
        }
        if let tintColor = tintColor, tf.tintColor != tintColor {
            tf.tintColor = tintColor
        }

        // Apply focus from the binding
        if let isFocused = isFocused {
            DispatchQueue.main.async {
                if isFocused.wrappedValue && !tf.isFirstResponder {
                    tf.becomeFirstResponder()
                } else if !isFocused.wrappedValue && tf.isFirstResponder {
                    tf.resignFirstResponder()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A text set from the binding: only when it differs from what the field holds. `clearingUndo`: the
    /// field's undo history goes with the text it replaced — the undo actions UIKit recorded for the
    /// user's typing would otherwise restore that text.
    static func setText(_ text: String, of tf: UITextField, clearingUndo: Bool) {
        guard tf.text != text else { return }
        tf.text = text
        if clearingUndo { tf.undoManager?.removeAllActions() }
    }

    private func applyNonReactive(tf: UITextField) {
        tf.text = text
        if let placeholderColor = placeholderColor {
            tf.attributedPlaceholder = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: placeholderColor]
            )
        } else {
            tf.placeholder = placeholder
        }
        tf.keyboardType = keyboardType
        tf.keyboardAppearance = keyboardAppearance
        tf.isSecureTextEntry = isSecure
        tf.textContentType = textContentType
        tf.autocorrectionType = autocorrection ? .yes : .no
        tf.autocapitalizationType = autocapitalization
        tf.returnKeyType = returnKeyType
        if let font = font { tf.font = font }
        if let textColor = textColor { tf.textColor = textColor }
        if let tintColor = tintColor { tf.tintColor = tintColor }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: UIKitTextField

        init(_ parent: UIKitTextField) {
            self.parent = parent
        }

        @objc func textFieldDidChange(_ tf: UITextField) {
            let newText = tf.text ?? ""
            if parent.text != newText {
                parent.text = newText
            }
            parent.onCompositionChange?(tf.markedTextRange != nil)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused?.wrappedValue = true
            parent.onEditingChanged?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused?.wrappedValue = false
            parent.onEditingChanged?(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn?()
            textField.resignFirstResponder()
            return true
        }
    }
}

// MARK: - Helpers to map config strings to UIKit enums

extension UIKeyboardAppearance {
    /// Parses `"default"` / `"light"` / `"dark"` (or nil) into a UIKit appearance.
    static func from(_ raw: String?) -> UIKeyboardAppearance {
        switch raw?.lowercased() {
        case "light": return .light
        case "dark":  return .dark
        default:      return .default
        }
    }
}
