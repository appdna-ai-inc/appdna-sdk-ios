import SwiftUI

/// Paywall header with optional title, subtitle, and background image.
struct HeaderSection: View {
    let data: PaywallSectionData?
    var loc: ((String, String) -> String)? = nil
    /// SPEC-084: Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil

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
                        .foregroundColor(.primary)
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
                        .foregroundColor(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.top, 40)
        .padding(.horizontal)
    }
}
