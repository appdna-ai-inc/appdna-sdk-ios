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

    /// A step's background as a backdrop: what the step host actually draws for it
    /// (`StyleEngine.backgroundView`). A colour is plain — `#FFFFFF` when none is authored, which is
    /// what the host draws then; an image, gradient or animation is busy. A background with no `type`
    /// (even one holding a colour) and a transparent one draw nothing, so the system background shows:
    /// plain, with no colour of its own.
    static func backdrop(of background: BackgroundStyleConfig?) -> Backdrop {
        guard let background else { return .plain(hex: nil) }
        switch background.type {
        case "color":
            let color = background.color ?? "#FFFFFF"
            return color == "transparent" || color == "clear" ? .plain(hex: nil) : .plain(hex: color)
        case nil, "transparent", "clear", "none": return .plain(hex: nil)
        default: return .busy
        }
    }

    /// What a content block draws behind its own content: its own fill, else what is behind it. In
    /// order from the content outwards — a row's `bg_color`, the block's `block_style` fill, its
    /// container fill (`container_bg_color`, `blur_background`). A gradient, a blur or a translucent
    /// fill is busy. A field inside a filled container, or a filled field, picks its logo from THIS.
    static func backdrop(ofBlock block: ContentBlock, behind: Backdrop) -> Backdrop {
        let cfg = block.field_config
        func double(_ key: String) -> Double? { cfgDouble(cfg?[key]) }
        func visible(_ hex: String?) -> String? {
            guard let hex, !hex.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let l = hex.lowercased()
            return l == "transparent" || l == "clear" ? nil : hex
        }
        if block.type == .row, let bg = visible(cfg?["bg_color"]?.value as? String) {
            return (double("background_opacity") ?? 1) < 1 ? .busy : .plain(hex: bg)
        }
        if let style = block.block_style {
            if style.background_gradient != nil { return .busy }
            if let bg = visible(style.background_color) { return (style.opacity ?? 1) < 1 ? .busy : .plain(hex: bg) }
        }
        if (cfg?["blur_background"]?.value as? Bool) == true { return .busy }
        if let bg = visible(cfg?["container_bg_color"]?.value as? String), bg.lowercased() != "#ffffff" {
            return (double("container_opacity") ?? double("background_opacity") ?? 1) < 1 ? .busy : .plain(hex: bg)
        }
        return behind
    }

    /// What the flow host draws behind a step (`stepFullScreenBackground`), in its order: the step's
    /// background; a chat step's own colour; a chat step's dark default; else the system background.
    /// The attribution's variant is picked from THIS, not from the appearance alone — a chat step is
    /// dark in a light appearance.
    static func backdrop(ofStep config: StepConfig, type: OnboardingStep.StepType) -> Backdrop {
        if let background = config.background { return backdrop(of: background) }
        if let chat = config.chat_config?.style?.background_color { return .plain(hex: chat) }
        if type == .interactive_chat { return .plain(hex: interactiveChatBackground) }
        return .plain(hex: nil)
    }

    /// The flow host's default behind an `interactive_chat` step.
    static let interactiveChatBackground = "#0F172A"

    /// What a Screen draws behind its sections (`ScreenRenderer.backgroundView`): a gradient or an image
    /// is busy, as is a translucent colour; a colour is plain; nothing authored is the system background.
    static func backdrop(ofScreen background: BackgroundConfig?) -> Backdrop {
        guard let background else { return .plain(hex: nil) }
        switch background.type {
        case "gradient":
            return background.gradient?.start != nil && background.gradient?.end != nil ? .busy : .plain(hex: nil)
        case "image":
            return background.image_url != nil ? .busy : .plain(hex: nil)
        default:
            guard let color = background.color else { return .plain(hex: nil) }
            return (background.opacity ?? 1) < 1 ? .busy : .plain(hex: color)
        }
    }

    /// What a Screen section draws behind its content: its own fill, else what is behind it.
    static func backdrop(ofSection style: SectionStyle?, behind: Backdrop) -> Backdrop {
        guard let style else { return behind }
        if style.background_gradient?.start != nil, style.background_gradient?.end != nil { return .busy }
        if let color = style.background_color { return .plain(hex: color) }
        return behind
    }

    /// What a location dropdown draws behind its rows, and so behind the logo under them: its authored
    /// fill (`dropdown_bg_color`), else `unstyled` (what an unstyled dropdown draws). A fill drawn
    /// translucent (`dropdown_opacity` below 1, or an alpha below `FF`) is busy. A fill that draws
    /// nothing — `transparent`, `clear`, a fully transparent colour, or a value no colour parser reads
    /// (both platforms draw those clear) — shows what is `behind` the dropdown.
    static func backdrop(ofDropdownFill hex: String?, opacity: Double, behind: Backdrop, unstyled: Backdrop) -> Backdrop {
        guard let raw = hex?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return opacity < 1 ? .busy : unstyled
        }
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        let isHex = (digits.count == 6 || digits.count == 8) && digits.allSatisfy(\.isHexDigit)
        guard isHex else { return behind }
        let alpha = digits.count == 8 ? Int(digits.suffix(2), radix: 16) ?? 255 : 255
        if alpha == 0 { return behind }
        return opacity < 1 || alpha < 255 ? .busy : .plain(hex: raw)
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

    /// Whether content drawn on `backdrop` needs light ink: a dark plain surface, or a busy one (a
    /// gradient, an image, an animation). The same light-or-dark call the logo variant makes, for other
    /// views that pick an unstyled default from what is behind them. The Kotlin twin is
    /// `GoogleMapsAttribution.needsLightInk(on, darkAppearance)`.
    static func needsLightInk(on backdrop: Backdrop, darkAppearance: Bool) -> Bool {
        backdrop == .busy || variant(on: backdrop, darkAppearance: darkAppearance) == .white
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

/// Hands a block's content what is drawn behind it (`GoogleMapsAttribution.backdrop(ofBlock:behind:)`),
/// reading what is behind the block at the block's own place in the tree — so a container's children
/// see the container's fill.
struct GoogleAttributionBlockBackdrop: ViewModifier {
    let block: ContentBlock
    @SwiftUI.Environment(\.googleAttributionBackdrop) private var behind

    func body(content: Content) -> some View {
        content.environment(\.googleAttributionBackdrop, GoogleMapsAttribution.backdrop(ofBlock: block, behind: behind))
    }
}

extension EnvironmentValues {
    /// What is behind a location field on this surface — the onboarding step's background, an option
    /// sheet's own background, a filled container. A field that keeps the Google logo beside it after
    /// a tap draws the variant for it.
    var googleAttributionBackdrop: GoogleMapsAttribution.Backdrop {
        get { self[GoogleAttributionBackdropKey.self] }
        set { self[GoogleAttributionBackdropKey.self] = newValue }
    }
}
