import Foundation
import UIKit

/// Theme variants for light / dark mode.
///
/// Generic wrapper that allows ANY theme-shaped Codable to be specified
/// either as a flat object (legacy — treated as light) or as a
/// light/dark pair. The `light` variant is the complete baseline and is
/// required; `dark` is optional sparse overrides that merge on top of
/// light at render time — any field not set in dark falls back to the
/// light value (mirrors iOS asset catalogs' "Dark Appearance" pattern).
///
/// Resolution happens at render time via SwiftUI's `@Environment(\.colorScheme)`
/// so the SDK auto-adapts when the user toggles system dark mode.
///
/// Back-compat: legacy messages / surveys that stored a flat theme
/// object are decoded into `light` with `dark = nil`. No migration
/// needed on existing customer data.
public struct ThemeSet<T: Codable>: Codable {
    public let light: T
    public let dark: T?

    public init(light: T, dark: T? = nil) {
        self.light = light
        self.dark = dark
    }

    public init(from decoder: Decoder) throws {
        // Try themed decode first — look for `light` / `dark` keys.
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.light) {
            self.light = try container.decode(T.self, forKey: .light)
            self.dark = try container.decodeIfPresent(T.self, forKey: .dark)
            return
        }
        // Fall back to flat — treat the whole payload as the light variant.
        self.light = try T(from: decoder)
        self.dark = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(light, forKey: .light)
        try container.encodeIfPresent(dark, forKey: .dark)
    }

    /// Pick the variant to render with. Does NOT merge — callers that
    /// want sparse overrides (the default behavior for themes with
    /// optional fields) should call `merged(for:)` instead.
    public func variant(for style: UIUserInterfaceStyle) -> T {
        if style == .dark, let dark = dark { return dark }
        return light
    }

    enum CodingKeys: String, CodingKey { case light, dark }
}

/// Render-time resolver for themes where every field is optional.
/// Pairs with the conventional pattern: every style property on the
/// inner `T` is `Optional`, `dark` specifies only what differs, and
/// `resolved(for:)` returns a fully-populated theme by preferring the
/// dark value and falling back to light. Types that need this behavior
/// implement `SparseMergeable` so callers can write `theme.resolved(for:)`
/// without per-type resolver code.
public protocol SparseMergeable {
    /// Merge overrides (self) onto a baseline. Implementations should
    /// prefer overrides' non-nil values over baseline's.
    func merged(onto baseline: Self) -> Self
}

extension ThemeSet where T: SparseMergeable {
    /// Preferred resolver for themes with optional fields. Returns
    /// `dark.merged(onto: light)` in dark mode, `light` otherwise.
    public func resolved(for style: UIUserInterfaceStyle) -> T {
        if style == .dark, let dark = dark {
            return dark.merged(onto: light)
        }
        return light
    }
}
