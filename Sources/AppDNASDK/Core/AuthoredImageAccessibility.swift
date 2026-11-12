import SwiftUI

/// What a screen reader does with an image an author placed: an onboarding image block, a paywall image
/// section, a screen's image section, an in-app message's image, a survey question's image.
///
/// An image whose authored description is blank is DECORATIVE: VoiceOver skips it. An image with a
/// description is one element, read as that description with the image trait. ONE rule; Android's
/// `AuthoredImageAccessibility` is the same, and the shared fixtures `dto_parsing/onboarding_image_alt`,
/// `dto_parsing/paywall_image_alt` and `dto_parsing/screen_image_alt` pin both.
enum AuthoredImageAccessibility {
    /// The description VoiceOver reads, or nil when the image is decorative (blank, whitespace or absent).
    static func label(_ alt: String?) -> String? {
        guard let t = alt?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Applies `AuthoredImageAccessibility` to the whole image view — every phase (loading, failed, drawn), so a
/// decorative image is never announced as a spinner or a placeholder either.
struct AuthoredImageAccessibilityModifier: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(.isImage)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

extension View {
    /// `label` is `AuthoredImageAccessibility.label(_:)`'s answer: nil hides the image from VoiceOver.
    func authoredImageAccessibility(_ label: String?) -> some View {
        modifier(AuthoredImageAccessibilityModifier(label: label))
    }
}
