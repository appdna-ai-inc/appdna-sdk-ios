import SwiftUI

/// Paywall header with optional title, subtitle, and background image.
struct HeaderSection: View {
    let data: PaywallSectionData?
    var loc: ((String, String) -> String)? = nil
    /// Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil
    /**
     #881 — the width the floating dismiss control occupies in the top corner, reserved on BOTH
     sides so centred text stays centred.

     The header title is centred across the full width and the dismiss control is an overlay with
     nothing holding space for it, so a title whose first line reaches the edge runs under it. On a
     device, two different generated paywalls both put the ✕ on the word "going". It is a
     generated-content problem meeting a hand-authored default: the prompt asks for an outcome-led
     headline, so a generated title is a full sentence where a hand-authored one is a few words.

     Passed in rather than read here, because this view does not see `config.dismiss` — and the
     caller resolves it with the same arithmetic the control is laid out with.
     */
    var closeInset: CGFloat = 0
    /**
     #891 — the background this header is drawn on, so an unauthored title colour is readable on
     it. It used `.primary`: black in light appearance, white in dark, on a paywall that forces no
     colour scheme — so a dark-backgrounded paywall opened on a light-appearance phone drew a black
     title on it, and the words were gone.
     */
    // `@SwiftUI.Environment`, qualified: the SDK exports its own `enum Environment`
    // (Configuration.swift) which shadows the property wrapper and fails to compile as
    // "enum 'Environment' cannot be used as an attribute".
    @SwiftUI.Environment(\.paywallBackgroundHex) private var backgroundHex: String?

    private var titleTextStyle: TextStyleConfig? {
        data?.title_style ?? sectionStyle?.elements?["title"]?.textStyle
    }
    private var subtitleTextStyle: TextStyleConfig? {
        data?.subtitle_style ?? sectionStyle?.elements?["subtitle"]?.textStyle
    }

    /// Horizontal alignment for the header graphic: leading | center (default) | trailing.
    private var imageAlignment: Alignment {
        switch data?.imageAlignment {
        case "leading":  return .leading
        case "trailing": return .trailing
        default:         return .center
        }
    }

    private var imageMaxHeight: CGFloat { data?.imageMaxHeight ?? 200 }

    var body: some View {
        VStack(spacing: 8) {
            if let imageUrl = data?.imageUrl, let url = URL(string: imageUrl) {
                BundledAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: imageMaxHeight)
                } placeholder: {
                    Color.clear.frame(height: imageMaxHeight)
                }
                .frame(maxWidth: .infinity, alignment: imageAlignment)
            }

            if let title = data?.title {
                if let ts = titleTextStyle {
                    Text(loc?("section-header.title", title) ?? title)
                        .applyTextStyle(ts)
                } else {
                    Text(loc?("section-header.title", title) ?? title)
                        .font(.title.bold())
                        .foregroundColor(PaywallTextDefaults.readable(on: backgroundHex))
                        .multilineTextAlignment(.center)
                }
            }

            if let subtitle = data?.subtitle {
                if let ts = subtitleTextStyle {
                    Text(loc?("section-header.subtitle", subtitle) ?? subtitle)
                        .applyTextStyle(ts)
                } else {
                    Text(loc?("section-header.subtitle", subtitle) ?? subtitle)
                        .font(.body)
                        // Shared cross-platform default: muted grey that reads on both light and
                        // dark backgrounds (Android uses the same #6B7280). Was white@0.6 which
                        // vanished on light paywalls.
                        .foregroundColor(Color(hex: "#6B7280"))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.top, 40)
        .padding(.horizontal)
        .padding(.horizontal, closeInset)
    }
}
