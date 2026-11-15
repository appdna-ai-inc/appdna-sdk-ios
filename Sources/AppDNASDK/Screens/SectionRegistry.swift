import SwiftUI

/// Protocol that all section renderers must conform to.
internal protocol SectionRenderer {
    @ViewBuilder
    static func render(section: ScreenSection, context: SectionContext) -> AnyView
}

/// Type-erased wrapper for section renderers.
internal struct AnySectionRenderer {
    let render: (ScreenSection, SectionContext) -> AnyView

    init<T: SectionRenderer>(_ type: T.Type) {
        self.render = { section, context in
            T.render(section: section, context: context)
        }
    }
}

/// Central registry mapping section type strings to native renderers.
/// Unknown types render as empty (no crash). New section types are registered
/// by `registerBuiltInSections()`, which `shared` runs when first touched.
internal class SectionRegistry {
    /// Filled with every built-in and module section renderer the first time it is touched, so a screen can never
    /// render through an empty registry, whichever entry reaches it first (`previewScreen`, a slot, an interception,
    /// `showScreen`). Nothing in the SDK used to fill it outside the tests, and every section rendered as nothing.
    static let shared: SectionRegistry = makeFilled()

    /// A registry holding every built-in and module section renderer — what `shared` is.
    static func makeFilled() -> SectionRegistry {
        let registry = SectionRegistry()
        registry.registerBuiltInSections()
        registry.registerModuleSections()
        return registry
    }

    private var renderers: [String: AnySectionRenderer] = [:]

    func register<T: SectionRenderer>(_ type: String, renderer: T.Type) {
        renderers[type] = AnySectionRenderer(renderer)
    }

    func render(section: ScreenSection, context: SectionContext) -> AnyView {
        if let sectionType = section.type, let renderer = renderers[sectionType] {
            return renderer.render(section, context)
        }

        // Fallback: if section has "blocks" in data, try content_blocks renderer
        if section.data?["blocks"] != nil {
            if let cbRenderer = renderers["content_blocks"] {
                return cbRenderer.render(section, context)
            }
        }

        // Unknown section type → empty
        return AnyView(EmptyView())
    }

    func hasRenderer(for type: String) -> Bool {
        renderers[type] != nil
    }

    /// Register all built-in section types. `shared` calls it when it is first touched (`makeFilled`).
    func registerBuiltInSections() {
        // Generic sections
        register("content_blocks", renderer: ContentBlocksSectionRenderer.self)
        register("hero", renderer: HeroSectionRenderer.self)
        register("spacer", renderer: SpacerSectionRenderer.self)
        register("divider", renderer: DividerSectionRenderer.self)
        register("cta_footer", renderer: CTAFooterSectionRenderer.self)
        register("sticky_footer", renderer: StickyFooterSectionRenderer.self)

        // Media sections
        register("image_section", renderer: ImageSectionRenderer.self)
        register("video_section", renderer: VideoSectionRenderer.self)
        register("lottie_section", renderer: LottieSectionRenderer.self)
        register("rive_section", renderer: RiveSectionRenderer.self)
    }
}
