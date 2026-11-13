import SwiftUI

// MARK: - In-app message section renderer (Screens SDUI)
//
// Sprint C6 (iOS SDK v1.0.52): Replaces the placeholder MessageSectionWrapper
// with real renderers that reuse the MessageViews sub-views (BannerView,
// ModalView). Supported section types:
//
//   message_banner  — banner (BannerView)
//   message_modal   — modal card (ModalView)
//   message_content — plain title/body/CTA card for inline placement
//
// CTA taps dispatch through the SectionContext so host flows can react.

enum MessageSectionWrapperImpl {

    static func decodeContent(_ raw: [String: AnyCodable]?) -> MessageContent? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        do {
            let json = try JSONEncoder().encode(raw)
            return try JSONDecoder().decode(MessageContent.self, from: json)
        } catch {
            let title = raw["title"]?.value as? String
            let body = raw["body"]?.value as? String
            let ctaText = raw["cta_text"]?.value as? String
            let imageUrl = raw["image_url"]?.value as? String
            if title == nil && body == nil && ctaText == nil && imageUrl == nil {
                return nil
            }
            return MessageContent(
                title: title, body: body, image_url: imageUrl,
                cta_text: ctaText
            )
        }
    }

    @ViewBuilder
    static func render(section: ScreenSection, context: SectionContext) -> some View {
        let content = decodeContent(section.data) ?? MessageContent()
        let onCTATap: () -> Void = {
            if let action = content.cta_action {
                switch action.type {
                case .deep_link:
                    if let url = action.url { context.onAction(.deepLink(url: url)) }
                case .open_url:
                    if let url = action.url { context.onAction(.openWebview(url: url)) }
                case .share:
                    // share and stay on the screen. Nothing to share → the CTA's dismiss
                    // behaviour, exactly as the in-app message surfaces treat a blank share.
                    if let payload = action.sharePayload {
                        ShareAction.present(payload)
                    } else {
                        context.onAction(.next)
                    }
                case .dismiss, .unknown, .none:
                    context.onAction(.next)
                }
            } else {
                context.onAction(.next)
            }
        }
        let onDismiss: () -> Void = {
            context.onAction(.dismiss)
        }
        switch section.type ?? "unknown" {
        case "message_banner":
            BannerView(content: content, onCTATap: onCTATap, onDismiss: onDismiss)
        case "message_modal":
            ModalView(content: content, onCTATap: onCTATap, onDismiss: onDismiss)
        case "message_content":
            MessageContentInlineView(content: content, onCTATap: onCTATap)
        default:
            EmptyView()
        }
    }
}

private struct MessageContentInlineView: View {
    let content: MessageContent
    let onCTATap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageUrl = content.image_url, let url = URL(string: imageUrl) {
                BundledAsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.15)
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(content.corner_radius ?? 12)))
                // No description can be authored for this image, so it is decorative: VoiceOver skips it (AuthoredImageAccessibility).
                .authoredImageAccessibility(nil)
            }
            if let title = content.title {
                Text(title)
                    .font(content.titleFont(default: .headline, defaultSize: 17))
                    .foregroundColor(content.text_color.map { Color(hex: $0) } ?? .primary)
            }
            if let body = content.body {
                Text(body)
                    .font(content.bodyFont(default: .body, defaultSize: 15))
                    .foregroundColor(content.text_color.map { Color(hex: $0).opacity(0.8) } ?? .secondary)
            }
            if let ctaText = content.cta_text {
                Button(action: onCTATap) {
                    HStack(spacing: 6) {
                        if let icon = content.cta_icon {
                            IconView(ref: icon, size: 14)
                        }
                        Text(ctaText)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(hex: content.button_color ?? "#6366F1"))
                    .foregroundColor(Color(hex: content.button_text_color ?? "#FFFFFF"))
                    .cornerRadius(CGFloat(content.button_corner_radius ?? 10))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(content.corner_radius ?? 12))
                .fill(Color(hex: content.background_color ?? "#FFFFFF"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(content.corner_radius ?? 12))
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}
