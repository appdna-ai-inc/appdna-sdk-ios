import SwiftUI

/// Small contextual tooltip popup.
struct TooltipView: View {
    let content: MessageContent
    let onCTATap: () -> Void
    let onDismiss: () -> Void

    @State private var isVisible = false

    var body: some View {
        VStack {
            Spacer()

            if isVisible {
                tooltipContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.opacity(0.01))
        .onAppear {
            // Haptic on appear
            HapticEngine.triggerIfEnabled(content.haptic?.triggers?.on_button_tap, config: content.haptic)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isVisible = true
            }
            // Auto-dismiss after timeout
            if let seconds = content.auto_dismiss_seconds, seconds > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds)) {
                    withAnimation { isVisible = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
                }
            }
        }
    }

    private var tooltipContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
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

                    Button {
                        withAnimation { isVisible = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                    }
                }

                if let ctaText = content.cta_text {
                    Button(action: {
                        HapticEngine.triggerIfEnabled(content.haptic?.triggers?.on_button_tap, config: content.haptic)
                        onCTATap()
                    }) {
                        HStack(spacing: 4) {
                            // CTA icon
                            if let icon = content.cta_icon {
                                IconView(ref: icon, size: 12)
                            }
                            Text(ctaText)
                        }
                        .font(.caption.bold())
                        .foregroundColor(Color(hex: content.button_color ?? "#6366F1"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Secondary CTA (Gap #18)
                if let secondaryText = content.secondary_cta_text {
                    Button(action: { onDismiss() }) {
                        Text(secondaryText)
                            .font(.caption)
                            .foregroundColor(content.text_color.map { Color(hex: $0).opacity(0.6) } ?? .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: CGFloat(content.corner_radius ?? 12))
                    .fill(Color(hex: content.background_color ?? "#FFFFFF"))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            )

            // Pointer arrow (Gap #17)
            Rectangle()
                .fill(Color(hex: content.background_color ?? "#FFFFFF"))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(45))
                .offset(y: -6)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
