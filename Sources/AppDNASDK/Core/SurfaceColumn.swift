// SurfaceColumn.swift
//
// THE CONTENT COLUMN OF A PRESENTED SURFACE, AND THE SIZE EVERY LAYOUT RULE RESOLVES AGAINST.
//
// An onboarding step, a paywall, a full-screen message and a survey lay their content out in one
// centred column, `min(available width, maxWidth)`. Their background keeps filling the whole
// surface. Below `maxWidth` (every phone in portrait) the column IS the available width, so
// nothing moves; on a wide window (a large display, a landscape phone, iPad, an unfolded
// two-screen phone) the text and buttons stop stretching edge to edge.
//
// The second job: the width- and height-relative rules (the step's side inset, a full-bleed
// background cancelling it, a percentage width or height, the wheel's side padding) used to read
// `UIScreen.main.bounds`. That is the size of a screen, not of the space the surface has — wrong
// in Split View, in a resized scene, and on a device with two displays, where Apple calls the main
// screen ambiguous. They now read the measured column through `\.appdnaSurfaceSize`, which is
// updated when the window resizes, so a fold, an unfold or a rotation re-lays out the content in
// place. The column is a frame, never a branch on size, so no view changes identity and no
// answer, selection or scroll position is lost when the size changes.
//
// © 2026 AppDNA AI, Inc.

import SwiftUI
import UIKit

public enum SurfaceColumn {
    /// The widest the content column grows, in points. Shared with Android (dp) and the console
    /// preview through the `layout/surface_column` fixture.
    public static let maxWidth: CGFloat = 560

    /// The column for `available` points of width. 0 (nothing measured yet) stays 0.
    public static func width(available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        return min(available, maxWidth)
    }

    /// The horizontal space either side of a centred column.
    public static func gutter(available: CGFloat) -> CGFloat {
        max(0, (available - width(available: available)) / 2)
    }
}

/// The size layout rules resolve against: the column's width and the surface's height. `.zero`
/// means nothing has measured yet; readers fall back through `SurfaceMetrics`.
private struct AppDNASurfaceSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    var appdnaSurfaceSize: CGSize {
        get { self[AppDNASurfaceSizeKey.self] }
        set { self[AppDNASurfaceSizeKey.self] = newValue }
    }
}

enum SurfaceMetrics {
    /// The measured surface size where there is one, else the window's.
    static func size(_ measured: CGSize) -> CGSize {
        let fallback = windowBounds.size
        return CGSize(
            width: measured.width > 0 ? measured.width : SurfaceColumn.width(available: fallback.width),
            height: measured.height > 0 ? measured.height : fallback.height
        )
    }

    static func width(_ measured: CGSize) -> CGFloat { size(measured).width }
    static func height(_ measured: CGSize) -> CGFloat { size(measured).height }

    /**
     The bounds of the window the SDK is drawing in, for code with no measured size (a particle
     field, a slide-in offset). The key window of the foreground scene, else any window, else the
     main screen — the last only when no scene exists at all.
     */
    static var windowBounds: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first {
            return window.bounds
        }
        if let scene { return scene.coordinateSpace.bounds }
        return UIScreen.main.bounds
    }
}

// MARK: - The split (two panes)

/// Column or two panes; shared fixture `dto_parsing/surface_layout`.
public enum SurfaceLayoutMode: String {
    case column, split
}

public enum SurfaceLayout {
    /// A split needs at least this much usable width.
    public static let splitMinWidth: CGFloat = 720
    /// A split container grows to at most this; each pane is half of it.
    public static let splitMaxWidth: CGFloat = 1040

    /// `split` only for a regular-width window at least 720 wide and wider than tall (Apple's
    /// arrangement rule, and the pose where a book fold's crease is vertical); else `column`.
    public static func mode(width: CGFloat, height: CGFloat, regular: Bool) -> SurfaceLayoutMode {
        regular && width >= splitMinWidth && width > height ? .split : .column
    }

    /// The width the content occupies: the split container when the surface splits, else the column.
    public static func containerWidth(available: CGFloat, splits: Bool) -> CGFloat {
        guard available > 0 else { return 0 }
        return splits ? min(available, splitMaxWidth) : SurfaceColumn.width(available: available)
    }

    /// The block types that make up an onboarding step's hero. A map is not one: it fills the surface.
    static let heroBlockTypes: Set<String> = ["image", "video", "lottie", "rive", "media_gallery", "carousel"]

    /**
     How many of `zone`'s leading blocks are the step's hero, and whether the step splits.

     `top`, `center` are the step's VISIBLE top and centre zones. The hero is the leading run of hero
     types in the first non-empty one; the step splits only if something else is left in the two.
     */
    static func onboardingSplit(topTypes: [String], centerTypes: [String]) -> (hero: Int, splits: Bool) {
        let source = topTypes.isEmpty ? centerTypes : topTypes
        let hero = source.prefix(while: { heroBlockTypes.contains($0) }).count
        let rest = topTypes.count + centerTypes.count - hero
        return (hero, hero > 0 && rest > 0)
    }

    /**
     A paywall's pitch: the indexes (into `sections`, in drawing order) of every scrolling section before
     the first scrolling `plans` section — or, when every `plans` section is pinned (the generator pins
     them to the bottom zone), every scrolling section. `pinned` says which sections sit in the pinned
     zone (the CTA, the sticky footer, a bottom-zone section, a pinned legal). It splits only with plans
     and a pitch.
     */
    static func paywallSplit(types: [String], pinned: [Bool]) -> (pitch: [Int], splits: Bool) {
        guard types.contains("plans") else { return ([], false) }
        let end = types.indices.first(where: { types[$0] == "plans" && !pinned[$0] }) ?? types.count
        let pitch = (0..<end).filter { !pinned[$0] }
        return (pitch, !pitch.isEmpty)
    }

    /// Only a full-screen message with hero media and copy splits; a card never does.
    static func messageSplits(type: String, hasHero: Bool, hasCopy: Bool) -> Bool {
        type == "fullscreen" && hasHero && hasCopy
    }
}

private struct AppDNASurfaceModeKey: EnvironmentKey {
    static let defaultValue: SurfaceLayoutMode = .column
}

private struct AppDNASurfaceAvailableKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    /// Whether the window allows a split (a surface still splits only if it has two things to show).
    var appdnaSurfaceMode: SurfaceLayoutMode {
        get { self[AppDNASurfaceModeKey.self] }
        set { self[AppDNASurfaceModeKey.self] = newValue }
    }

    /// The whole usable size, before any column or split container.
    var appdnaSurfaceAvailable: CGSize {
        get { self[AppDNASurfaceAvailableKey.self] }
        set { self[AppDNASurfaceAvailableKey.self] = newValue }
    }
}

/// Raised by a surface that is drawing two panes, so the column widens to the split container.
struct SurfaceSplitsKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/**
 Lays `content` out in the surface column — or, when the window allows a split and the content says
 it is splitting (`SurfaceSplitsKey`), in the split container — and publishes the size to it.

 The decision is a frame width, never a branch, so nothing below changes identity when it flips.
 */
struct SurfaceColumnModifier: ViewModifier {
    @State private var available: CGSize = .zero
    @State private var contentSplits = false
    @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        let mode = SurfaceLayout.mode(
            width: available.width, height: available.height, regular: horizontalSizeClass == .regular
        )
        let container = SurfaceLayout.containerWidth(available: available.width, splits: mode == .split && contentSplits)
        content
            .environment(\.appdnaSurfaceSize, CGSize(width: container, height: available.height))
            .environment(\.appdnaSurfaceMode, mode)
            .environment(\.appdnaSurfaceAvailable, available)
            .onPreferenceChange(SurfaceSplitsKey.self) { contentSplits = $0 }
            .frame(maxWidth: container > 0 ? container : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { available = geo.size }
                        .onChange(of: geo.size) { available = $0 }
                }
            )
    }
}

extension View {
    /// See `SurfaceColumnModifier`.
    func appdnaSurfaceColumn() -> some View { modifier(SurfaceColumnModifier()) }

    /// Caps this content at the plain column when the surface around it is a split container but this
    /// part does not split (a progress bar, a legacy step).
    func appdnaColumnCap() -> some View { modifier(SurfaceColumnCap()) }
}

struct SurfaceColumnCap: ViewModifier {
    @SwiftUI.Environment(\.appdnaSurfaceSize) private var surface
    func body(content: Content) -> some View {
        let column = SurfaceColumn.width(available: surface.width)
        content
            .environment(\.appdnaSurfaceSize, CGSize(width: column, height: surface.height))
            .frame(maxWidth: column > 0 ? column : .infinity)
            .frame(maxWidth: .infinity)
    }
}

/**
 Two panes, or one: `main` is ALWAYS the second child of the same stack, so it keeps its identity
 (its inputs, its scroll position, its pinned zone) when a fold or an unfold adds or removes the
 leading pane. Each pane is told its own width through `\.appdnaSurfaceSize`.

 It splits when the window allows it (`\.appdnaSurfaceMode`, read HERE, below the column modifier
 that sets it) and the surface has something for each pane (`canSplit`). `main` is told which.
 */
struct SurfaceSplitStack<Lead: View, Main: View>: View {
    let canSplit: Bool
    @ViewBuilder let lead: () -> Lead
    @ViewBuilder let main: (_ splits: Bool) -> Main
    @SwiftUI.Environment(\.appdnaSurfaceSize) private var surface
    @SwiftUI.Environment(\.appdnaSurfaceMode) private var mode

    var body: some View {
        let splits = canSplit && mode == .split
        let pane = splits ? surface.width / 2 : surface.width
        HStack(spacing: 0) {
            if splits {
                lead()
                    .environment(\.appdnaSurfaceSize, CGSize(width: pane, height: surface.height))
                    .frame(width: pane > 0 ? pane : nil)
                    .frame(maxHeight: .infinity)
            }
            main(splits)
                .environment(\.appdnaSurfaceSize, CGSize(width: pane, height: surface.height))
                .frame(maxWidth: splits && pane > 0 ? pane : .infinity)
        }
        .preference(key: SurfaceSplitsKey.self, value: splits)
    }
}
