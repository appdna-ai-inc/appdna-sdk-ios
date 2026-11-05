import SwiftUI

/// Routes to the appropriate message view based on message_type.
/// Interpolates all text fields via TemplateEngine before rendering.
/// Resolves dark-mode overrides based on system color scheme
/// before handing content to sub-views.
struct MessageRenderer: View {
    let messageId: String
    let config: MessageConfig
    let onCTATap: () -> Void
    let onDismiss: () -> Void

    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    /// Interpolated content with template variables resolved.
    /// Preserves the `dark` override object so `resolved(for:)` can use
    /// it downstream.
    private var interpolatedContent: MessageContent {
        let ctx = TemplateEngine.shared.buildContext(surface: .other)
        let e = TemplateEngine.shared
        return MessageContent(
            title: config.content?.title.map { e.interpolate($0, context: ctx) },
            body: config.content?.body.map { e.interpolate($0, context: ctx) },
            image_url: config.content?.image_url,
            cta_text: config.content?.cta_text.map { e.interpolate($0, context: ctx) },
            cta_action: config.content?.cta_action,
            dismiss_text: config.content?.dismiss_text.map { e.interpolate($0, context: ctx) },
            background_color: config.content?.background_color,
            banner_position: config.content?.banner_position,
            auto_dismiss_seconds: config.content?.auto_dismiss_seconds,
            text_color: config.content?.text_color,
            button_color: config.content?.button_color,
            button_text_color: config.content?.button_text_color,
            button_corner_radius: config.content?.button_corner_radius,
            corner_radius: config.content?.corner_radius,
            secondary_cta_text: config.content?.secondary_cta_text.map { e.interpolate($0, context: ctx) },
            font_family: config.content?.font_family,
            title_font_size: config.content?.title_font_size,
            body_font_size: config.content?.body_font_size,
            lottie_url: config.content?.lottie_url,
            rive_url: config.content?.rive_url,
            rive_state_machine: config.content?.rive_state_machine,
            video_url: config.content?.video_url,
            video_thumbnail_url: config.content?.video_thumbnail_url,
            cta_icon: config.content?.cta_icon,
            secondary_cta_icon: config.content?.secondary_cta_icon,
            haptic: config.content?.haptic,
            particle_effect: config.content?.particle_effect,
            blur_backdrop: config.content?.blur_backdrop,
            // a field not copied here never reaches a view (the typography above was lost the same way).
            dismiss_allowed: config.content?.dismiss_allowed,
            dismiss_delay: config.content?.dismiss_delay,
            dark: config.content?.dark
        )
    }

    var body: some View {
        // Apply dark overrides before rendering so sub-views
        // see the final resolved colors/images for the current scheme.
        let content = interpolatedContent.resolved(for: colorScheme)
        switch config.message_type {
        case .banner:
            BannerView(content: content, onCTATap: onCTATap, onDismiss: onDismiss)
        case .modal:
            ModalView(content: content, onCTATap: onCTATap, onDismiss: onDismiss)
        case .fullscreen:
            FullscreenView(content: content, onCTATap: onCTATap, onDismiss: onDismiss)
        case .tooltip:
            TooltipView(content: content, onCTATap: onCTATap, onDismiss: onDismiss)
        case .unknown, .none:
            EmptyView()
        }
    }
}

// MARK: - Dismiss gating, shared by the four message views

extension View {
    /// A close control (the ✕, `dismiss_text`) that is drawn and tappable only while the user may
    /// dismiss. Hidden by opacity rather than removed so a control that appears after
    /// `dismiss_delay` does not shift the message's layout when it does.
    func messageDismissControl(visible: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    /// Flips `unlocked` to true once the policy's delay has passed (no-op when the message is never
    /// dismissable, or is dismissable already).
    func messageDismissUnlock(_ policy: MessageDismissPolicy, _ unlocked: Binding<Bool>) -> some View {
        onAppear {
            guard let after = policy.unlockAfterSeconds else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                withAnimation(.easeIn(duration: 0.2)) { unlocked.wrappedValue = true }
            }
        }
    }
}

// MARK: - The controller a message is presented in

/// ONE construction, used by both hosts (`MessageManager`, `PendingMessageListener`), so how a message
/// may leave the screen cannot differ between a triggered message and a per-user delivery.
enum MessageHosting {
    static func makeHost<V: View>(rootView: V, config: MessageConfig) -> UIHostingController<V> {
        let host = UIHostingController(rootView: rootView)
        host.modalPresentationStyle = config.message_type == .fullscreen ? .fullScreen : .overCurrentContext
        host.modalTransitionStyle = .crossDissolve
        host.view.backgroundColor = .clear
        // A message that may not be dismissed refuses any system dismissal of its controller too (the
        // views already hide the close control and ignore a backdrop tap). Neither style used here is
        // swipeable today; this keeps it true if one ever is.
        host.isModalInPresentation = !MessageDismissPolicy(content: config.content).allowed
        return host
    }
}
