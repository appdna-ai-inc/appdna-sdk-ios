import SwiftUI

/// Full-screen takeover message.
struct FullscreenView: View {
    let content: MessageContent
    let onCTATap: () -> Void
    let onDismiss: () -> Void

    @State private var showConfetti = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: content.background_color ?? "#FFFFFF")
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Lottie hero (takes priority over image)
                if let lottieUrl = content.lottie_url {
                    LottieBlockView(block: LottieBlock(
                        lottie_url: lottieUrl, lottie_json: nil,
                        autoplay: true, loop: true, speed: 1.0,
                        width: nil, height: 240, alignment: "center",
                        play_on_scroll: nil, play_on_tap: nil, color_overrides: nil
                    ))
                }
                // Rive hero
                else if let riveUrl = content.rive_url {
                    RiveBlockView(block: RiveBlock(
                        rive_url: riveUrl, artboard: nil,
                        state_machine: content.rive_state_machine,
                        autoplay: true, height: 240, alignment: "center",
                        inputs: nil, trigger_on_step_complete: nil
                    ))
                }
                // Video hero
                else if let videoUrl = content.video_url {
                    VideoBlockView(block: VideoBlock(
                        video_url: videoUrl,
                        video_thumbnail_url: content.video_thumbnail_url ?? content.image_url,
                        video_height: 240,
                        video_corner_radius: 12,
                        autoplay: true, loop: true, muted: true,
                        controls: false, inline_playback: true
                    ))
                    .padding(.horizontal, 24)
                }
                // Optional image
                else if let urlString = content.image_url, let url = URL(string: urlString) {
                    BundledAsyncPhaseImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 300, maxHeight: 300)
                        }
                    }
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
                }

                Spacer().frame(height: 32)
            }

            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
            }
            .padding(16)

            // Confetti overlay
            if showConfetti, let effect = content.particle_effect {
                ConfettiOverlay(effect: effect)
            }
        }
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
