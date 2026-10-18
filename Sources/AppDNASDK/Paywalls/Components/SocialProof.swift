import SwiftUI

/// Star rating and review count display.
struct SocialProof: View {
    /// #947 — the page this sits on, so `.secondary` stops following the phone. Same reason as
    /// `FeatureList`: a system colour is black in light appearance and white in dark, and a paywall
    /// forces no colour scheme, so the review count vanished for anyone whose phone disagreed with
    /// the author's background. Measured as 1,557 pixels changing between the two appearances.
    @SwiftUI.Environment(\.paywallBackgroundHex) private var pageBackgroundHex: String?

    let data: PaywallSectionData?
    var loc: ((String, String) -> String)? = nil
    /// Per-section style with element overrides.
    var sectionStyle: SectionStyleConfig? = nil

    private var valueTextStyle: TextStyleConfig? {
        sectionStyle?.elements?["value"]?.textStyle
    }

    var body: some View {
        VStack(spacing: 8) {
            /*
             #954 — the caption, above the stars.

             `data.text` decoded, travelled and was drawn by the `countdown` and `trial_badge`
             branches and by NOTHING in this one, so an author could write "Loved by 12,000
             runners", see it in the console preview, publish it, and have no device draw it. One
             saved section on dev carried `text` and nothing else, and rendered blank for exactly
             this reason. Above the stars because that is the reading order of the pattern and
             where the countdown branch puts its own label.
             */
            if let caption = data?.text, !caption.isEmpty {
                Text(loc?("social_proof.text", caption) ?? caption)
                    .applyTextStyleOrDefault(
                        sectionStyle?.elements?["text"]?.textStyle,
                        font: .caption,
                        color: PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.8)
                    )
                    .multilineTextAlignment(.center)
                    .applyElementStyle(sectionStyle?.elements?["text"]?.container)
            }

            if let rating = data?.rating {
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: starName(for: index, rating: rating))
                            .foregroundColor(Color(hex: "#FBBF24"))
                            .font(.body)
                    }

                    if let count = data?.reviewCount {
                        // #910 — the `value` element's container, beside the text style it
                        // already honoured.
                        Group {
                            if let ts = valueTextStyle {
                                Text("(\(formatCount(count)))")
                                    .applyTextStyle(ts)
                            } else {
                                Text("(\(formatCount(count)))")
                                    .font(.caption)
                                    // #947 — off the page, not off the phone.
                                    .foregroundColor(
                                        PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                            }
                        }
                        .applyElementStyle(sectionStyle?.elements?["value"]?.container)
                    }
                }
            }

            if let testimonial = data?.testimonial {
                /*
                 🔴 #947's defect, one line further down than #947 looked. This was
                 `.foregroundColor(.white.opacity(0.8))` — a colour that follows nothing, so the
                 quote vanished on any light page, exactly as the review count did until #947 took
                 it off the phone and put it on the page. The two `.font` modifiers were the other
                 half: `.callout` was dead, overridden by `.subheadline.italic()` below it.
                 */
                Text("\"\(loc?("social_proof.testimonial", testimonial) ?? testimonial)\"")
                    .applyTextStyleOrDefault(
                        sectionStyle?.elements?["testimonial"]?.textStyle,
                        font: .subheadline.italic(),
                        color: PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.8)
                    )
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .applyElementStyle(sectionStyle?.elements?["testimonial"]?.container)

                /*
                 #955 — the attribution, which the generator writes and this section could not
                 draw. 12 of 22 saved sections on dev carry an `author`, because the paywall prompt
                 asked for one; the field decoded as `author_name` and reached no view. The
                 `testimonial` SECTION has drawn it all along, which is what makes this a gap
                 rather than a feature: the same content rendered two ways depending on which
                 section type an author happened to pick.
                 */
                if let author = data?.authorName, !author.isEmpty {
                    Text("\u{2014} \(loc?("social_proof.author_name", author) ?? author)")
                        .applyTextStyleOrDefault(
                            sectionStyle?.elements?["author_name"]?.textStyle,
                            font: .caption,
                            color: PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.6)
                        )
                        .applyElementStyle(sectionStyle?.elements?["author_name"]?.container)
                }
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
