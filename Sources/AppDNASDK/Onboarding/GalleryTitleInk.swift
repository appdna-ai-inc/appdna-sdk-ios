import Foundation

/// The colour of a `media_gallery` title: the authored `gallery_title_color`, else the unstyled ink for what
/// is behind the gallery — `light` (white) on a dark surface, `dark` (the platform's default text ink) on a
/// light one. Shared with Android and driven by the `media_gallery_title_ink` fixture. iOS defaulted to white
/// everywhere (invisible on a light step) while Android used the theme's dark ink everywhere.
enum GalleryTitleInk {
    static func resolve(authored: String?, behind: GoogleMapsAttribution.Backdrop, darkAppearance: Bool) -> String {
        if let a = authored?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a }
        return GoogleMapsAttribution.needsLightInk(on: behind, darkAppearance: darkAppearance) ? "light" : "dark"
    }
}
