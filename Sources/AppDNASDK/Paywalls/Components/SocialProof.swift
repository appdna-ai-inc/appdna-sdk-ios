import SwiftUI

/// Star rating and review count display.
struct SocialProof: View {
    let data: PaywallSectionData?
    var loc: ((String, String) -> String)? = nil
    /// Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil

    private var valueTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["value"]?.textStyle
    }

    var body: some View {
        VStack(spacing: 8) {
            if let rating = data?.rating {
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: starName(for: index, rating: rating))
                            .foregroundColor(Color(hex: "#FBBF24"))
                            .font(.body)
                    }

                    if let count = data?.reviewCount {
                        if let ts = valueTextStyle {
                            Text("(\(formatCount(count)))")
                                .applyTextStyle(ts)
                        } else {
                            Text("(\(formatCount(count)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let testimonial = data?.testimonial {
                Text("\"\(loc?("social_proof.testimonial", testimonial) ?? testimonial)\"")
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .font(.subheadline.italic())
                    .padding(.horizontal)
            }
        }
    }

    private func starName(for index: Int, rating: Double) -> String {
        let threshold = Double(index) + 1
        if rating >= threshold {
            return "star.fill"
        } else if rating >= threshold - 0.5 {
            return "star.leadinghalf.filled"
        } else {
            return "star"
        }
    }

    private func formatCount(_ count: Int) -> String {
        // Match Android formatCompactCount exactly: an M tier + suppress the tenths digit
        // when it's 0 or the whole is >= 10. iOS was naive (no M tier, always a decimal), so 1,000,000
        // rendered "1000.0K" (vs "1M") and 12,450 rendered "12.4K" (vs "12K") on the paywall's
        // social-proof review count — a user-visible conversion surface.
        let abs = Swift.abs(count)
        if abs >= 1_000_000 {
            let whole = abs / 1_000_000
            let tenths = (abs % 1_000_000) / 100_000
            return (tenths == 0 || whole >= 10) ? "\(whole)M" : "\(whole).\(tenths)M"
        }
        if abs >= 1_000 {
            let whole = abs / 1_000
            let tenths = (abs % 1_000) / 100
            return (tenths == 0 || whole >= 10) ? "\(whole)K" : "\(whole).\(tenths)K"
        }
        return "\(abs)"
    }
}
