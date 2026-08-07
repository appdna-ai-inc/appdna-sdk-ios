import SwiftUI

/// Main renderer for a server-driven screen. Composes sections from the registry
/// based on the ScreenConfig, applies layout (scroll/fixed/pager), and handles
/// dismiss controls, navigation bar, particle effects, and haptics.
internal struct ScreenRenderer: View {
    let config: ScreenConfig
    @ObservedObject var context: ScreenContextHolder
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        let visibleSections = (config.sections ?? []).filter { section in
            guard let condition = section.visibility_condition else { return true }
            return ConditionEvaluator.evaluateCondition(
                type: condition.type ?? "always",
                variable: condition.variable,
                value: condition.value?.value,
                context: context.sectionContext.buildEvaluationContext()
            )
        }

        let nonStickySections = visibleSections.filter { ($0.type ?? "unknown") != "sticky_footer" && ($0.type ?? "unknown") != "paywall_sticky_footer" }
        let stickySection = visibleSections.first(where: { ($0.type ?? "unknown") == "sticky_footer" || ($0.type ?? "unknown") == "paywall_sticky_footer" })

        ZStack(alignment: .bottom) {
            // Background
            backgroundView

            VStack(spacing: 0) {
                // Navigation bar
                if let navBar = config.nav_bar {
                    navigationBar(navBar)
                }

                // Main content
                switch config.layout?.type ?? "scroll" {
                case "scroll":
                    ScrollView(.vertical, showsIndicators: config.layout?.scroll_indicator ?? false) {
                        VStack(spacing: CGFloat(config.layout?.spacing ?? 16)) {
                            ForEach(nonStickySections) { section in
                                sectionView(section)
                            }
                        }
                        .padding(CGFloat(config.layout?.padding ?? 0))
                    }

                case "fixed":
                    VStack(spacing: CGFloat(config.layout?.spacing ?? 16)) {
                        ForEach(nonStickySections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(CGFloat(config.layout?.padding ?? 0))

                case "pager":
                    TabView {
                        ForEach(nonStickySections) { section in
                            sectionView(section)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                default:
                    ScrollView {
                        VStack(spacing: CGFloat(config.layout?.spacing ?? 16)) {
                            ForEach(nonStickySections) { section in
                                sectionView(section)
                            }
                        }
                        .padding(CGFloat(config.layout?.padding ?? 0))
                    }
                }

                // Sticky footer
                if let sticky = stickySection {
                    sectionView(sticky)
                        .background(.ultraThinMaterial)
                }
            }

            // Particle effects
            if let effect = config.particle_effect, effect.on_present == true {
                ConfettiOverlay(effect: ParticleEffect(
                    type: effect.type ?? "confetti",
                    trigger: "on_appear",
                    duration_ms: effect.duration_ms ?? 3000,
                    intensity: effect.intensity ?? "medium",
                    colors: nil
                ))
            }
        }
        // Dismiss controls
        .overlay(alignment: dismissAlignment) {
            if config.dismiss?.enabled == true {
                dismissButton
            }
        }
        // Safe area
        .ignoresSafeArea(config.layout?.safe_area == false ? .all : [])
        // Haptic on present
        .onAppear {
            if let haptic = config.haptic, haptic.on_present == true,
               let hapticType = HapticType(rawValue: haptic.type ?? "light") {
                HapticEngine.trigger(hapticType)
            }
        }
    }

    // MARK: - Section Rendering

    @ViewBuilder
    private func sectionView(_ section: ScreenSection) -> some View {
        let content = SectionRegistry.shared.render(section: section, context: context.sectionContext)
            .applySectionStyle(section.style)

        if let anim = section.entrance_animation, (anim.type ?? "none") != "none" {
            EntranceAnimationWrapper(animation: EntranceAnimation(
                type: anim.type,
                duration_ms: anim.duration_ms,
                delay_ms: anim.delay_ms,
                easing: anim.easing,
                spring_damping: anim.spring_damping,
                animation_delay_ms: nil,   // onboarding-only sequencing fields; not used by Screens
                animation_order: nil
            )) {
                AnyView(content)
            }
        } else {
            content
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        if let bg = config.background {
            switch bg.type {
            case "gradient":
                if let gradient = bg.gradient, let start = gradient.start, let end = gradient.end {
                    LinearGradient(
                        colors: [Color(hex: start), Color(hex: end)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
            case "image":
                if let url = bg.image_url, let imageUrl = URL(string: url) {
                    BundledAsyncImage(url: imageUrl) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                    .ignoresSafeArea()
                }
            default: // solid
                if let color = bg.color {
                    Color(hex: color)
                        .opacity(bg.opacity ?? 1.0)
                        .ignoresSafeArea()
                }
            }
        }
    }

    // MARK: - Navigation Bar

    @ViewBuilder
    private func navigationBar(_ navBar: NavBarConfig) -> some View {
        HStack {
            if navBar.show_back == true {
                Button(action: { context.sectionContext.onAction(.back) }) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .foregroundColor(.primary)
                }
            }

            if let title = navBar.title {
                Text(title)
                    .font(.headline)
                Spacer()
            } else {
                Spacer()
            }

            if navBar.show_close == true {
                Button(action: { context.sectionContext.onAction(.dismiss) }) {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(navBar.background_color.flatMap { Color(hex: $0) } ?? Color.clear)
    }

    // MARK: - Dismiss Button

    private var dismissAlignment: Alignment {
        let position = config.dismiss?.position ?? "top_right"
        return position == "top_left" ? .topLeading : .topTrailing
    }

    @ViewBuilder
    private var dismissButton: some View {
        Button(action: { context.sectionContext.onAction(.dismiss) }) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .padding(16)
    }
}

// MARK: - Section Style Modifier

extension View {
    @ViewBuilder
    func applySectionStyle(_ style: SectionStyle?) -> some View {
        if let s = style {
            let radius = CGFloat(s.border_radius ?? 0)
            self
                .padding(.top, CGFloat(s.margin_top ?? 0))
                .padding(.bottom, CGFloat(s.margin_bottom ?? 0))
                .background(sectionBackground(s, radius: radius))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(
                            Color(hex: s.border_color ?? "transparent"),
                            lineWidth: CGFloat(s.border_width ?? 0)
                        )
                )
                .shadow(
                    color: Color(hex: s.shadow?.color ?? "transparent"),
                    radius: CGFloat(s.shadow?.blur ?? 0) / 2,
                    x: CGFloat(s.shadow?.x ?? 0),
                    y: CGFloat(s.shadow?.y ?? 0)
                )
                .padding(.top, CGFloat(s.padding_top ?? 0))
                .padding(.trailing, CGFloat(s.padding_right ?? 0))
                .padding(.bottom, CGFloat(s.padding_bottom ?? 0))
                .padding(.leading, CGFloat(s.padding_left ?? 0))
                .opacity(s.opacity ?? 1.0)
        } else {
            self
        }
    }

    @ViewBuilder
    private func sectionBackground(_ s: SectionStyle, radius: CGFloat) -> some View {
        if let gradient = s.background_gradient, let start = gradient.start, let end = gradient.end {
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(
                    colors: [Color(hex: start), Color(hex: end)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
        } else if let bgColor = s.background_color {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(hex: bgColor))
        } else {
            EmptyView()
        }
    }
}

// MARK: - Context Holder (ObservableObject for state changes)

internal class ScreenContextHolder: ObservableObject {
    @Published var sectionContext: SectionContext

    init(context: SectionContext) {
        self.sectionContext = context
    }
}
