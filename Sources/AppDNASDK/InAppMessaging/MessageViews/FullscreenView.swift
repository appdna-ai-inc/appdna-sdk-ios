import SwiftUI

/// Full-screen takeover message.
struct FullscreenView: View {
    let content: MessageContent
    let onCTATap: () -> Void
    let onDismiss: () -> Void

    @State private var showConfetti = false

    /// whether the user may dismiss right now. Starts from the policy and flips once
    /// `dismiss_delay` has passed; never flips when `dismiss_allowed` is false.
    @State private var dismissUnlocked: Bool
    private let dismissPolicy: MessageDismissPolicy

    init(content: MessageContent, onCTATap: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.content = content
        self.onCTATap = onCTATap
        self.onDismiss = onDismiss
        let policy = MessageDismissPolicy(content: content)
        self.dismissPolicy = policy
        self._dismissUnlocked = State(initialValue: policy.dismissableAtOpen)
    }

    var body: some View {
        // An unstyled message is drawn on its own fill (white unless authored), whatever the phone's appearance.
        messageBody.resolvesAppearance(onFill: content.background_color ?? "#FFFFFF", darkAppearance: false)
    }

    /// The message's hero media, if it has one: lottie, then rive, then video, then image.
    private var hasHero: Bool {
        MessageHeroMedia.of(content) != nil
    }

    /// Whether there is anything to put beside a hero.
    private var hasCopy: Bool {
        content.title != nil || content.body != nil || content.cta_text != nil
    }

    @ViewBuilder
    private var hero: some View {
        // A Lottie, then a Rive, then a video, then the image (MessageHeroMedia); a blank URL is no hero.
        switch MessageHeroMedia.of(content) {
        case .lottie(let lottieUrl):
            LottieBlockView(block: LottieBlock(
                lottie_url: lottieUrl,
                autoplay: true, loop: true, speed: 1.0,
                width: nil, height: 240, alignment: "center",
                play_on_scroll: nil, play_on_tap: nil
            ))
        case .rive(let riveUrl):
            RiveBlockView(block: RiveBlock(
                rive_url: riveUrl, artboard: nil,
                state_machine: content.rive_state_machine,
                autoplay: true, height: 240, alignment: "center",
                inputs: nil, trigger_on_step_complete: nil
            ))
        case .video(let videoUrl):
            VideoBlockView(block: VideoBlock(
                video_url: videoUrl,
                video_thumbnail_url: content.video_thumbnail_url ?? content.image_url,
                video_height: 240,
                video_corner_radius: 12,
                autoplay: true, loop: true, muted: true,
                controls: false, inline_playback: true
            ))
            .padding(.horizontal, 24)
        case .image(let url):
            BundledAsyncPhaseImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 300)
                }
            }
            // No description can be authored for this image, so it is decorative: VoiceOver skips it (AuthoredImageAccessibility).
            .authoredImageAccessibility(nil)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: content.background_color ?? "#FFFFFF")
                .ignoresSafeArea()

            // On a wide window the hero takes the leading pane; the title, body and
            // CTAs keep the trailing one, the same view in both modes.
            SurfaceSplitStack(canSplit: SurfaceLayout.messageSplits(type: "fullscreen", hasHero: hasHero, hasCopy: hasCopy)) {
                VStack {
                    Spacer()
                    hero
                    Spacer()
                }
            } main: { splits in
            VStack(spacing: 24) {
                Spacer()

                // In a split the hero is drawn in the leading pane instead.
                if !splits {
                    hero
                }

                // Title: apply text_color
                if let title = content.title {
                    Text(title)
                        .font(content.titleFont(default: .largeTitle.bold(), defaultSize: 34))
                        .foregroundColor(content.text_color.map { Color(hex: $0) } ?? .primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Body: apply text_color
                if let body = content.body {
                    Text(body)
                        .font(content.bodyFont(default: .body, defaultSize: 17))
                        .foregroundColor(content.text_color.map { Color(hex: $0).opacity(0.7) } ?? .secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // CTA: apply button_color, corner_radius
                if let ctaText = content.cta_text {
                    Button {
                        HapticEngine.triggerIfEnabled(content.haptic?.triggers?.on_button_tap, config: content.haptic)
                        onCTATap()
                    } label: {
                        HStack(spacing: 6) {
                            // CTA icon
                            if let icon = content.cta_icon {
                                IconView(ref: icon, size: 18)
                            }
                            Text(ctaText)
                        }
                        .font(.headline)
                        .foregroundColor(Color(hex: content.button_text_color ?? "#FFFFFF"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color(hex: content.button_color ?? "#6366F1"))
                        .cornerRadius(CGFloat(content.button_corner_radius ?? 8))
                    }
                    .padding(.horizontal, 24)
                }

                // Secondary CTA (Gap #18)
                if let secondaryText = content.secondary_cta_text {
                    Button(action: { onDismiss() }) {
                        HStack(spacing: 4) {
                            if let icon = content.secondary_cta_icon {
                                IconView(ref: icon, size: 12)
                            }
                            Text(secondaryText)
                        }
                        .font(.caption)
                        .foregroundColor(content.text_color.map { Color(hex: $0).opacity(0.6) } ?? .secondary)
                    }
                }

                // Dismiss text
                if let dismissText = content.dismiss_text {
                    Button(dismissText, action: onDismiss)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .messageDismissControl(visible: dismissUnlocked)
                }

                Spacer().frame(height: 32)
            }
            }
            // The hero, copy and CTA lay out in the surface column; the fill behind still covers
            // the whole screen.
            .appdnaSurfaceColumn()

            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
            }
            .padding(16)
            .messageDismissControl(visible: dismissUnlocked)

            // Confetti overlay
            if showConfetti, let effect = content.particle_effect {
                ConfettiOverlay(effect: effect)
            }
        }
        .messageDismissUnlock(dismissPolicy, $dismissUnlocked)
        .onAppear {
            // Haptic on appear
            HapticEngine.triggerIfEnabled(content.haptic?.triggers?.on_button_tap, config: content.haptic)
            // Particle effect on appear
            if let effect = content.particle_effect, effect.trigger == "on_appear" {
                showConfetti = true
            }
        }
    }
}
