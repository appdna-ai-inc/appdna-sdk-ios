import SwiftUI

// MARK: - Entry Animation

struct EntryAnimationModifier: ViewModifier {
    let animation: String   // slide_up, fade_in, scale_in, none
    let durationMs: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .offset(y: animation == "slide_up" && !appeared ? SurfaceMetrics.windowBounds.height : 0)
            .opacity((animation == "fade_in" || animation == "slide_up") && !appeared ? 0 : 1)
            .scaleEffect(animation == "scale_in" && !appeared ? 0.8 : 1)
            .animation(.easeOut(duration: Double(durationMs) / 1000), value: appeared)
            .onAppear { appeared = true }
    }
}

// MARK: - Section Stagger Animation

struct SectionStaggerModifier: ViewModifier {
    let animation: String   // fade_in, slide_in_left, slide_in_right, bounce, none
    let delayMs: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(!appeared && animation != "none" ? 0 : 1)
            .offset(x: offsetX)
            .scaleEffect(animation == "bounce" && !appeared ? 0.5 : 1)
            .animation(
                animation == "bounce"
                    ? .spring(response: 0.5, dampingFraction: 0.6)
                    : .easeOut(duration: 0.4),
                value: appeared
            )
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayMs) / 1000) {
                    appeared = true
                }
            }
    }

    private var offsetX: CGFloat {
        guard !appeared else { return 0 }
        switch animation {
        case "slide_in_left": return -100
        case "slide_in_right": return 100
        default: return 0
        }
    }
}

// MARK: - CTA Button Animations

struct PulseEffect: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

struct GlowEffect: ViewModifier {
    @State private var isGlowing = false

    func body(content: Content) -> some View {
        content
            .shadow(color: .accentColor.opacity(isGlowing ? 0.6 : 0), radius: isGlowing ? 15 : 0)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isGlowing)
            .onAppear { isGlowing = true }
    }
}

struct BounceEffect: ViewModifier {
    @State private var isBouncing = false

    func body(content: Content) -> some View {
        content
            .offset(y: isBouncing ? -5 : 0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isBouncing)
            .onAppear { isBouncing = true }
    }
}

struct CTAAnimationModifier: ViewModifier {
    let animation: String   // pulse, glow, bounce, none

    func body(content: Content) -> some View {
        switch animation {
        case "pulse":
            content.modifier(PulseEffect())
        case "glow":
            content.modifier(GlowEffect())
        case "bounce":
            content.modifier(BounceEffect())
        default:
            content
        }
    }
}

// MARK: - Plan Selection Animation

struct PlanSelectionModifier: ViewModifier {
    let animation: String   // scale, border_highlight, glow, none
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(animation == "scale" && isSelected ? 1.03 : 1)
            .shadow(
                color: animation == "glow" && isSelected ? .accentColor.opacity(0.5) : .clear,
                radius: animation == "glow" && isSelected ? 10 : 0
            )
            .overlay(
                animation == "border_highlight" && isSelected
                    ? AnyView(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2.5))
                    : AnyView(EmptyView())
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Dismiss Animation

struct DismissAnimationModifier: ViewModifier {
    let animation: String   // slide_down, fade_out, none
    let isDismissing: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: animation == "slide_down" && isDismissing ? SurfaceMetrics.windowBounds.height : 0)
            .opacity(animation == "fade_out" && isDismissing ? 0 : 1)
            .animation(.easeIn(duration: 0.3), value: isDismissing)
    }
}

// MARK: - Convenience View extensions

extension View {
    func entryAnimation(_ animation: String?, durationMs: Int? = nil) -> some View {
        modifier(EntryAnimationModifier(
            animation: animation ?? "none",
            durationMs: durationMs ?? 400
        ))
    }

    func sectionStagger(_ animation: String?, delayMs: Int? = nil) -> some View {
        modifier(SectionStaggerModifier(
            animation: animation ?? "none",
            delayMs: delayMs ?? 0
        ))
    }

    func ctaAnimation(_ animation: String?) -> some View {
        modifier(CTAAnimationModifier(animation: animation ?? "none"))
    }

    func planSelection(_ animation: String?, isSelected: Bool) -> some View {
        modifier(PlanSelectionModifier(animation: animation ?? "none", isSelected: isSelected))
    }

    func dismissAnimation(_ animation: String?, isDismissing: Bool) -> some View {
        modifier(DismissAnimationModifier(animation: animation ?? "none", isDismissing: isDismissing))
    }
}
