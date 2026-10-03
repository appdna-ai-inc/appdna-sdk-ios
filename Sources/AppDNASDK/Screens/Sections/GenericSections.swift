import SwiftUI

// MARK: - Content Blocks Section

/// Bridges to existing ContentBlockRendererView (51 block types).
internal enum ContentBlocksSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let blocks = parseBlocks(from: section.data ?? [:])
        let layout = section.data?["layout"]?.value as? String ?? "vertical"
        let spacing = section.data?["spacing"]?.value as? Double ?? 12

        return AnyView(
            ContentBlocksSectionView(
                blocks: blocks,
                layout: layout,
                spacing: spacing,
                context: context
            )
        )
    }

    private static func parseBlocks(from data: [String: AnyCodable]) -> [ContentBlock] {
        guard let blocksData = data["blocks"]?.value else { return [] }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: blocksData)
            return try JSONDecoder().decode([ContentBlock].self, from: jsonData)
        } catch {
            print("[SDUI] Failed to parse content blocks: \(error)")
            return []
        }
    }
}

private struct ContentBlocksSectionView: View {
    let blocks: [ContentBlock]
    let layout: String
    let spacing: Double
    @State private var toggleValues: [String: Bool] = [:]
    @State private var inputValues: [String: Any] = [:]
    let context: SectionContext

    var body: some View {
        ContentBlockRendererView(
            blocks: blocks,
            onAction: { action, actionValue in
                handleBlockAction(action, value: actionValue)
            },
            toggleValues: $toggleValues,
            responses: context.responses,
            hookData: context.hookData,
            inputValues: $inputValues,
            currentStepIndex: context.currentScreenIndex,
            totalSteps: context.totalScreens
        )
    }

    /// Validate required form fields before allowing next/submit
    private func validateFormFields() -> Bool {
        for block in blocks {
            let blockType = block.type.rawValue
            guard blockType.hasPrefix("input_") else { continue }

            let fieldId = block.field_id ?? block.id
            let isRequired = block.field_required ?? false

            if isRequired {
                let value = inputValues[fieldId]
                if value == nil || "\(value ?? "")" == "" {
                    // Field required but empty — validation fails
                    return false
                }
            }

            // Pattern validation
            if let config = block.field_config as? [String: Any],
               let pattern = config["pattern"] as? String,
               let value = inputValues[fieldId] as? String,
               !value.isEmpty {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(value.startIndex..., in: value)
                    if regex.firstMatch(in: value, range: range) == nil {
                        return false
                    }
                }
            }
        }
        return true
    }

    private func handleBlockAction(_ action: String, value: String?) {
        switch action {
        case "next":
            guard validateFormFields() else { return }
            context.onAction(.next)
        case "dismiss":
            context.onAction(.dismiss)
        case "skip":
            context.onAction(.next)
        case "open_url":
            if let url = value { context.onAction(.openURL(url: url)) }
        case "deep_link":
            if let url = value { context.onAction(.deepLink(url: url)) }
        case "open_in_webview":
            if let url = value { context.onAction(.openWebview(url: url)) }
        case "open_app_settings":
            context.onAction(.openAppSettings)
        case "share":
            context.onAction(.share(text: value ?? ""))
        default:
            context.onAction(.custom(type: action, value: value))
        }
    }
}

// MARK: - Hero Section

internal enum HeroSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let imageURL = section.data?["image_url"]?.value as? String
        let videoURL = section.data?["video_url"]?.value as? String
        let lottieURL = section.data?["lottie_url"]?.value as? String
        let height = section.data?["height"]?.value as? Double ?? 300
        let contentPosition = section.data?["content_position"]?.value as? String ?? "bottom"

        return AnyView(
            ZStack(alignment: verticalAlignment(contentPosition)) {
                // Media background
                if let url = imageURL, let imageUrl = URL(string: url) {
                    BundledAsyncImage(url: imageUrl) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                } else if videoURL != nil {
                    Color.black // Video placeholder
                } else if lottieURL != nil {
                    Color.clear // Lottie placeholder
                } else {
                    Color.gray.opacity(0.1)
                }

                // Gradient overlay
                if let gradient = section.data?["gradient_overlay"]?.value as? [String: Any],
                   let start = gradient["start"] as? String,
                   let end = gradient["end"] as? String {
                    LinearGradient(
                        colors: [Color(hex: start), Color(hex: end)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                // Overlay blocks
                if let overlayData = section.data?["overlay_blocks"]?.value {
                    let blocks = parseOverlayBlocks(overlayData)
                    ContentBlocksSectionView(
                        blocks: blocks,
                        layout: "vertical",
                        spacing: 8,
                        context: context
                    )
                    .padding()
                }
            }
            .frame(height: CGFloat(height))
            .clipped()
        )
    }

    private static func verticalAlignment(_ position: String) -> Alignment {
        switch position {
        case "top": return .top
        case "center": return .center
        default: return .bottom
        }
    }

    private static func parseOverlayBlocks(_ data: Any) -> [ContentBlock] {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            return try JSONDecoder().decode([ContentBlock].self, from: jsonData)
        } catch {
            return []
        }
    }
}

// MARK: - Spacer Section

internal enum SpacerSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let height = section.data?["height"]?.value as? Double ?? 16
        return AnyView(Spacer().frame(height: CGFloat(height)))
    }
}

// MARK: - Divider Section

internal enum DividerSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let color = section.data?["color"]?.value as? String
        let thickness = section.data?["thickness"]?.value as? Double ?? 1
        let insetLeft = section.data?["inset_left"]?.value as? Double ?? 0
        let insetRight = section.data?["inset_right"]?.value as? Double ?? 0

        return AnyView(
            Rectangle()
                .fill(color.flatMap { Color(hex: $0) } ?? Color.gray.opacity(0.3))
                .frame(height: CGFloat(thickness))
                .padding(.leading, CGFloat(insetLeft))
                .padding(.trailing, CGFloat(insetRight))
        )
    }
}

// MARK: - CTA Footer Section

internal enum CTAFooterSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let primaryButton = section.data?["primary_button"]?.value as? [String: Any]
        let secondaryButton = section.data?["secondary_button"]?.value as? [String: Any]
        let disclaimerText = section.data?["disclaimer_text"]?.value as? String

        return AnyView(
            VStack(spacing: 12) {
                if let primary = primaryButton {
                    Button(action: {
                        handleButtonAction(primary, context: context)
                    }) {
                        Text(primary["text"] as? String ?? "Continue")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .cornerRadius(12)
                    }
                }

                if let secondary = secondaryButton {
                    Button(action: {
                        handleButtonAction(secondary, context: context)
                    }) {
                        Text(secondary["text"] as? String ?? "Skip")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                if let disclaimer = disclaimerText {
                    Text(disclaimer)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        )
    }

    private static func handleButtonAction(_ button: [String: Any], context: SectionContext) {
        let action = button["action"] as? String ?? "next"
        let actionValue = button["action_value"] as? String

        switch action {
        case "next": context.onAction(.next)
        case "dismiss": context.onAction(.dismiss)
        case "back": context.onAction(.back)
        case "open_url": if let v = actionValue { context.onAction(.openURL(url: v)) }
        case "open_in_webview": if let v = actionValue { context.onAction(.openWebview(url: v)) }
        case "deep_link": if let v = actionValue { context.onAction(.deepLink(url: v)) }
        case "show_paywall": context.onAction(.showPaywall(id: actionValue))
        case "show_survey": context.onAction(.showSurvey(id: actionValue))
        case "show_screen": if let v = actionValue { context.onAction(.showScreen(id: v)) }
        case "share": context.onAction(.share(text: actionValue ?? ""))
        case "open_app_settings": context.onAction(.openAppSettings)
        default: context.onAction(.custom(type: action, value: actionValue))
        }
    }
}

// MARK: - Sticky Footer Section

internal enum StickyFooterSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        // Same as CTA footer but rendered outside the ScrollView by ScreenRenderer
        CTAFooterSectionRenderer.render(section: section, context: context)
    }
}

// MARK: - Media Sections

internal enum ImageSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let imageURL = section.data?["image_url"]?.value as? String
        let height = section.data?["height"]?.value as? Double
        let cornerRadius = section.data?["corner_radius"]?.value as? Double ?? 0

        return AnyView(
            Group {
                if let url = imageURL, let imageUrl = URL(string: url) {
                    BundledAsyncImage(url: imageUrl) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(height: height.map { CGFloat($0) })
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(cornerRadius)))
                }
            }
        )
    }
}

internal enum VideoSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let videoURL = section.data?["video_url"]?.value as? String
        let height = section.data?["height"]?.value as? Double ?? 200

        return AnyView(
            Group {
                if let url = videoURL {
                    VideoBlockView(block: VideoBlock(
                        video_url: url,
                        video_thumbnail_url: section.data?["thumbnail_url"]?.value as? String,
                        video_height: height,
                        video_corner_radius: section.data?["corner_radius"]?.value as? Double ?? 0,
                        autoplay: section.data?["autoplay"]?.value as? Bool ?? false,
                        loop: section.data?["loop"]?.value as? Bool ?? false,
                        muted: section.data?["muted"]?.value as? Bool ?? true,
                        controls: nil,
                        inline_playback: nil
                    ))
                }
            }
        )
    }
}

internal enum LottieSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let lottieURL = section.data?["lottie_url"]?.value as? String
        let height = section.data?["height"]?.value as? Double ?? 200

        return AnyView(
            Group {
                if lottieURL != nil {
                    LottieBlockView(block: LottieBlock(
                        lottie_url: lottieURL,
                        lottie_json: nil,
                        autoplay: section.data?["autoplay"]?.value as? Bool ?? true,
                        loop: section.data?["loop"]?.value as? Bool ?? true,
                        speed: section.data?["speed"]?.value as? Double ?? 1.0,
                        width: nil,
                        height: height,
                        alignment: "center",
                        play_on_scroll: nil,
                        play_on_tap: nil,
                        color_overrides: nil
                    ))
                }
            }
        )
    }
}

internal enum RiveSectionRenderer: SectionRenderer {
    static func render(section: ScreenSection, context: SectionContext) -> AnyView {
        let riveURL = section.data?["rive_url"]?.value as? String
        let height = section.data?["height"]?.value as? Double ?? 200

        return AnyView(
            Group {
                if let url = riveURL {
                    RiveBlockView(block: RiveBlock(
                        rive_url: url,
                        artboard: section.data?["artboard"]?.value as? String,
                        state_machine: section.data?["state_machine"]?.value as? String,
                        autoplay: true,
                        height: height,
                        alignment: "center",
                        inputs: nil,
                        trigger_on_step_complete: nil
                    ))
                }
            }
        )
    }
}
