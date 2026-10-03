import SwiftUI

/// Top or bottom banner message with auto-dismiss.
struct BannerView: View {
    let content: MessageContent
    let onCTATap: () -> Void
    let onDismiss: () -> Void

    @State private var isVisible = false

    private var isTop: Bool {
        content.banner_position != .bottom
    }

    var body: some View {
        VStack {
            if !isTop { Spacer() }

            if isVisible {
                bannerContent
                    .transition(.move(edge: isTop ? .top : .bottom).combined(with: .opacity))
            }

            if isTop { Spacer() }
        }
        .background(Color.black.opacity(0.01)) // Tap-through background
        .onAppear {
            // Haptic on appear
            HapticEngine.triggerIfEnabled(content.haptic?.triggers?.on_button_tap, config: content.haptic)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isVisible = true
            }
            // Auto-dismiss
            if let seconds = content.auto_dismiss_seconds, seconds > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds)) {
                    withAnimation { isVisible = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
                }
            }
        }
    }

    private var bannerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = content.title {
                        Text(title)
                            .font(content.titleFont(default: .subheadline.bold(), defaultSize: 15))
                            .foregroundColor(content.text_color.map { Color(hex: $0) } ?? .primary)
                    }
                    if let body = content.body {
                        Text(body)
                            .font(content.bodyFont(default: .caption, defaultSize: 12))
                            .foregroundColor(content.text_color.map { Color(hex: $0).opacity(0.7) } ?? .secondary)
                    }
                }

                Spacer()

                if let ctaText = content.cta_text {
                    Button {
                        HapticEngine.triggerIfEnabled(content.haptic?.triggers?.on_button_tap, config: content.haptic)
                        onCTATap()
                    } label: {
                        HStack(spacing: 4) {
                            // CTA icon
                            if let icon = content.cta_icon {
                                IconView(ref: icon, size: 12)
                            }
                            Text(ctaText)
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: content.button_color ?? "#6366F1"))
                        .foregroundColor(Color(hex: content.button_text_color ?? "#FFFFFF"))
                        .cornerRadius(CGFloat(content.button_corner_radius ?? 8))
                    }
                }

                Button {
                    withAnimation { isVisible = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                }
            }

            // Secondary CTA (Gap #18)
            if let secondaryText = content.secondary_cta_text {
                Button(action: { onDismiss() }) {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundColor(content.text_color.map { Color(hex: $0).opacity(0.6) } ?? .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(content.corner_radius ?? 12))
                .fill(Color(hex: content.background_color ?? "#FFFFFF"))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .padding(.horizontal, 16)
        .padding(isTop ? .top : .bottom, 8)
    }
}
