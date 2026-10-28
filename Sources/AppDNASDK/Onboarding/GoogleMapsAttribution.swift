import SwiftUI
import UIKit

/// Google's attribution for Google Maps Platform content shown without a Google map.
///
/// Google's Places and Geocoding policies require it wherever their data is shown without a Google
/// map: *"It must always be clear to end users which content is provided by Google Maps."* The SDK
/// shows Google data in three places, and each one attributes it:
///
/// - **a location dropdown listing Google suggestions** draws the logo under the rows
///   (`LocationSuggestionSearch.showsGoogleLogo`);
/// - **a location field whose answer came from Google** keeps the logo beside the field after the
///   dropdown closes, and again when the answer is restored (`LocationAnswer.carriesPlaceId`);
/// - **an onboarding step whose text templates a Google answer** draws a small "Google Maps" text
///   credit in the step's container (`GoogleCredit`).
///
/// The logo is Google's own asset, unmodified (`Resources/appdna_google_maps_logo_*.png`; provenance in
/// `NOTICE.md`), drawn per Google's attribution guidelines
/// (https://developers.google.com/maps/documentation/geocoding/policies):
/// 16 pt high (16–19 dp allowed), 10 pt clear space left, right and top and 5 pt below, the plain
/// variant on a plain surface and the outlined variant on a busy one, and the accessibility label
/// "Google Maps". Where the asset cannot be loaded, the text "Google Maps" is drawn instead, which the
/// guidelines allow when a logo does not fit.
enum GoogleMapsAttribution {

    /// The accessibility label and the text attribution Google's guidelines name.
    static let label = "Google Maps"

    /// The logo's height. Google allows 16–19 dp; the smallest keeps a dropdown compact.
    static let logoHeight: CGFloat = 16
    /// Google's minimum clear space around the logo.
    static let clearSpaceSides: CGFloat = 10
    static let clearSpaceBottom: CGFloat = 5

    /// One of the four variants Google publishes.
    enum Variant: String, CaseIterable {
        /// Plain gray — a plain light surface.
        case gray = "appdna_google_maps_logo_gray"
        /// Plain white — a plain dark surface.
        case white = "appdna_google_maps_logo_white"
        /// Dark letters with a light outline — a busy surface in light appearance.
        case lightOutline = "appdna_google_maps_logo_light_outline"
        /// White letters with a dark outline — a busy surface in dark appearance.
        case darkOutline = "appdna_google_maps_logo_dark_outline"
    }

    /// What is behind the attribution.
    enum Backdrop: Equatable {
        /// A solid surface. `hex` is its colour when known (an authored dropdown colour, a colour
        /// background); nil means the system background, which follows the appearance.
        case plain(hex: String?)
        /// An image, a gradient, an animation or a translucent surface: Google asks for the outlined
        /// logo there.
        case busy
    }

    /// A step's background as a backdrop: a colour is plain, anything else authored is busy, and no
    /// background is the system one.
    static func backdrop(of background: BackgroundStyleConfig?) -> Backdrop {
        guard let background else { return .plain(hex: nil) }
        switch background.type ?? (background.color != nil ? "color" : nil) {
        case "color": return .plain(hex: background.color)
        case nil: return .plain(hex: nil)
        default: return .busy
        }
    }

    /// The variant for a backdrop. A known plain colour decides by its own luminance; the system
    /// background and a busy one follow the appearance.
    static func variant(on backdrop: Backdrop, darkAppearance: Bool) -> Variant {
        switch backdrop {
        case .plain(let hex):
            if let l = GoogleMarkChip.luminance(hex) { return l >= GoogleMarkChip.lightEnough ? .gray : .white }
            return darkAppearance ? .white : .gray
        case .busy:
            return darkAppearance ? .darkOutline : .lightOutline
        }
    }

    /// The colour of the text attribution: one of the three Google names (white, `#1F1F1F`,
    /// `#5E5E5E`). Gray on a light surface, white on a dark or busy one; on a busy surface the view
    /// adds a shadow so the white stays legible over a light part of an image.
    static func textColorHex(on backdrop: Backdrop, darkAppearance: Bool) -> String {
        variant(on: backdrop, darkAppearance: darkAppearance) == .gray ? "#5E5E5E" : "#FFFFFF"
    }

    private static var cache: [Variant: UIImage] = [:]
    private static let cacheLock = NSLock()

    /// The variant's image from the SDK's resource bundle, or nil when the bundle lacks it (a host that
    /// strips package resources): the views then draw the text attribution.
    static func image(_ variant: Variant) -> UIImage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[variant] { return hit }
        guard let url = AppDNAResources.bundle?.url(forResource: variant.rawValue, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              // The files are Google's 4x renders; reading them at scale 4 makes their point size the
              // size Google drew them for.
              let image = UIImage(data: data, scale: 4) else { return nil }
        cache[variant] = image
        return image
    }
}

/// The "Google Maps" logo with Google's clear space, or the text attribution when the asset is missing.
struct GoogleMapsLogoView: View {
    let backdrop: GoogleMapsAttribution.Backdrop
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let variant = GoogleMapsAttribution.variant(on: backdrop, darkAppearance: dark)
        Group {
            if let image = GoogleMapsAttribution.image(variant) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: GoogleMapsAttribution.logoHeight)
            } else {
                GoogleMapsTextAttribution(backdrop: backdrop)
            }
        }
        .padding(.top, GoogleMapsAttribution.clearSpaceSides)
        .padding(.horizontal, GoogleMapsAttribution.clearSpaceSides)
        .padding(.bottom, GoogleMapsAttribution.clearSpaceBottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GoogleMapsAttribution.label)
        .accessibilityIdentifier("appdna.google_maps_attribution")
    }
}

/// The text attribution: "Google Maps", small, in one of the colours Google names.
struct GoogleMapsTextAttribution: View {
    let backdrop: GoogleMapsAttribution.Backdrop
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let hex = GoogleMapsAttribution.textColorHex(on: backdrop, darkAppearance: dark)
        let text = Text(GoogleMapsAttribution.label)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(hex: hex))
        Group {
            // The shadow only where it is needed: white over an image or gradient. On a plain surface
            // the text carries no effect at all.
            if backdrop == .busy {
                text.shadow(color: Color.black.opacity(0.6), radius: 2)
            } else {
                text
            }
        }
        .accessibilityLabel(GoogleMapsAttribution.label)
        .accessibilityIdentifier("appdna.google_maps_text_attribution")
    }
}

// MARK: - What is behind a location field

private struct GoogleAttributionBackdropKey: EnvironmentKey {
    static let defaultValue: GoogleMapsAttribution.Backdrop = .plain(hex: nil)
}

extension EnvironmentValues {
    /// What is behind a location field on this surface — the onboarding step's background. A field
    /// that keeps the Google logo beside it after a tap draws the variant for it.
    var googleAttributionBackdrop: GoogleMapsAttribution.Backdrop {
        get { self[GoogleAttributionBackdropKey.self] }
        set { self[GoogleAttributionBackdropKey.self] = newValue }
    }
}
