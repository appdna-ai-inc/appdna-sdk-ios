import SwiftUI

// MARK: - Paywall section renderer (Screens SDUI)
//
// Sprint C6 (iOS SDK v1.0.52): Previously the PaywallSectionWrapper was a
// placeholder that only rendered the section type label. This file contains
// the real implementations for the 24 paywall_* section types so screens
// composed from the SDUI registry render the same content a stand-alone
// PaywallRenderer would.
//
// Design notes
// ============
// * `PaywallRenderer` is a SwiftUI View with instance state (purchase flow,
//   scroll offset, etc.) and depends on a full `PaywallConfig` (plans, CTA
//   config, localizations). When a paywall_* section is embedded inside a
//   Screen we don't have that full config, so we avoid reusing the View
//   directly and instead build equivalent content from `PaywallSectionData`
//   which is decodable from the section's JSON blob.
// * Actions (CTA tap, restore, dismiss) dispatch through the SectionContext
//   so the host Screen/Flow can observe them. CTA tap is treated as "next"
//   which matches the onboarding convention.
// * iOS 16.0 minimum is respected throughout — no iOS 17-only APIs.

enum PaywallSectionWrapperImpl {

    /// Decode a `[String: AnyCodable]` section payload into the typed
    /// `PaywallSectionData` used by the paywall renderers. Round-trips
    /// through JSON; returns nil when the payload is empty or malformed so
    /// callers can fall back to an EmptyView.
    static func decodeData(_ raw: [String: AnyCodable]?) -> PaywallSectionData? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        do {
            let json = try JSONEncoder().encode(raw)
            return try JSONDecoder().decode(PaywallSectionData.self, from: json)
        } catch {
            return nil
        }
    }

    /// Dispatch rendering for a paywall_* section type. All 24 types are
    /// handled; unknown variants fall through to EmptyView which matches
    /// the SectionRegistry contract.
    @ViewBuilder
    static func render(section: ScreenSection, context: SectionContext) -> some View {
        let type = (section.type ?? "unknown").replacingOccurrences(of: "paywall_", with: "")
        let data = decodeData(section.data)

        switch type {
        case "header":
            HeaderSection(data: data, loc: nil, sectionStyle: nil)
        case "features":
            FeatureList(
                features: data?.features ?? [],
                richItems: data?.items,
                columns: Int(data?.featureColumns ?? 1),
                gap: data?.featureGap ?? 12,
                sectionStyle: nil,
                iconColorOverride: data?.iconColor,
                itemTextColorOverride: data?.itemTextColor,
                iconBgColor: data?.iconBgColor,
                iconBgOpacity: data?.iconBgOpacity ?? 0.15,
                iconBgSize: data?.iconBgSize ?? 32
            )
        case "plans":
            PlansSectionView(data: data, context: context)
        case "cta":
            CTASectionView(data: data, context: context)
        case "social_proof":
            SocialProofSectionView(data: data, context: context)
        case "guarantee":
            GuaranteeSectionView(data: data)
        case "testimonial":
            TestimonialSectionView(data: data)
        case "countdown":
            CountdownSectionView(data: data)
        case "legal":
            LegalSectionView(data: data, context: context)
        case "comparison":
            ComparisonTableSectionView(data: data)
        case "promo":
            PromoInputSectionView(data: data, context: context)
        case "reviews":
            ReviewsCarouselSectionView(data: data)
        case "toggle":
            ToggleSectionView(data: data)
        case "icon_grid":
            IconGridSectionView(data: data)
        case "carousel":
            CarouselSectionView(data: data, context: context)
        case "card":
            CardSectionView(data: data)
        case "timeline":
            TimelineSectionView(data: data)
        case "image":
            ImageSectionView(data: data)
        case "video":
            VideoSectionView(data: data)
        case "lottie":
            LottieSectionView(data: data)
        case "rive":
            RiveSectionView(data: data)
        case "spacer":
            Spacer().frame(height: data?.spacerHeight ?? 24)
        case "divider":
            DividerSectionView(data: data)
        case "sticky_footer":
            StickyFooterSectionView(data: data, context: context)
        default:
            EmptyView()
        }
    }
}

// MARK: - Plans

private struct PlansSectionView: View {
    let data: PaywallSectionData?
    let context: SectionContext
    @State private var selectedId: String?

    var body: some View {
        let plans = data?.plans ?? []
        VStack(spacing: 12) {
            ForEach(plans) { plan in
                Button {
                    selectedId = plan.id
                    context.onAction(.custom(type: "plan_selected", value: plan.id))
                } label: {
                    planRow(plan: plan, selected: selectedId == plan.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func planRow(plan: PaywallPlan, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(selected ? Color(hex: "#6366F1") : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.displayName).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                if let desc = plan.description {
                    Text(desc).font(.caption).foregroundColor(.secondary)
                }
                if let trial = plan.trialLabel {
                    Text(trial).font(.caption2).foregroundColor(Color(hex: "#6366F1"))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(plan.displayPrice).font(.subheadline.weight(.bold))
                if let period = plan.period { Text(period).font(.caption2).foregroundColor(.secondary) }
                if let badge = plan.badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(hex: "#F59E0B"))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color(hex: "#6366F1") : Color.gray.opacity(0.3), lineWidth: selected ? 2 : 1)
        )
    }
}

// MARK: - CTA

private struct CTASectionView: View {
    let data: PaywallSectionData?
    let context: SectionContext

    var body: some View {
        VStack(spacing: 8) {
            Button {
                context.onAction(.next)
            } label: {
                Text(data?.ctaText ?? data?.text ?? "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "#6366F1"))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            if data?.showRestore == true {
                Button {
                    context.onAction(.custom(type: "restore_purchase", value: nil))
                } label: {
                    Text(data?.restoreText ?? "Restore Purchases")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Social proof

private struct SocialProofSectionView: View {
    let data: PaywallSectionData?
    let context: SectionContext

    var body: some View {
        switch data?.subType {
        case "countdown":
            CountdownTimerView(seconds: data?.countdownSeconds ?? 86400)
        case "trial_badge":
            Text(data?.text ?? "Free Trial")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "#6366F1").opacity(0.15))
                .foregroundColor(Color(hex: "#6366F1"))
                .clipShape(Capsule())
        default:
            SocialProof(data: data, loc: nil, sectionStyle: nil)
        }
    }
}

// MARK: - Guarantee

private struct GuaranteeSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let hasContent = data?.guaranteeText != nil || data?.title != nil || data?.text != nil || data?.description != nil
        VStack(spacing: 8) {
            if hasContent {
                Image(systemName: "shield.checkmark.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(hex: data?.accentColor ?? "#22C55E"))
                if let badge = data?.guaranteeText ?? data?.text {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Color(hex: data?.accentColor ?? "#22C55E"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(hex: data?.accentColor ?? "#22C55E").opacity(0.15))
                        .clipShape(Capsule())
                }
                if let title = data?.title {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                }
                if let desc = data?.description ?? (data?.title != nil ? (data?.text ?? data?.guaranteeText) : nil) {
                    Text(desc).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }
}

// MARK: - Testimonial

private struct TestimonialSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let layout = data?.layout ?? "quote"
        let content = VStack(spacing: 12) {
            if layout == "quote" {
                Text("\u{201C}")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(Color(hex: "#6366F1"))
            }
            Text(data?.quote ?? data?.testimonial ?? "")
                .italic()
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(layout == "minimal" ? .caption : .body)
            if layout != "minimal" {
                HStack(spacing: 12) {
                    if let avatarUrl = data?.avatarUrl, let url = URL(string: avatarUrl) {
                        BundledAsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = data?.authorName {
                            Text(name).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                        }
                        if let role = data?.authorRole {
                            Text(role).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            } else if let name = data?.authorName {
                Text("— \(name)").font(.caption.weight(.medium)).foregroundColor(.secondary)
            }
        }
        .padding(layout == "card" ? 16 : 0)

        Group {
            if layout == "card" {
                content
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#F9FAFB")))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#E5E7EB"), lineWidth: 1))
                    .padding(.horizontal)
            } else {
                content
            }
        }
    }
}

// MARK: - Countdown

private struct CountdownSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let duration = data?.durationSeconds ?? data?.countdownSeconds ?? 3600
        let layout = data?.layout ?? "inline"
        VStack(spacing: 8) {
            // Round-24 — the SDUI/Screens countdown renderer had the SAME hardcoded grey `.caption`
            // label bug the main PaywallRenderer just fixed (ignoring label_font_size + label_color), plus
            // the label-vs-labelText precedence inversion (Round-11 F4). Honor both + prefer label_text,
            // matching PaywallRenderer.swift + Android (14pt/semibold/#7F1D1D).
            if let label = data?.labelText ?? data?.label {
                Text(label)
                    .font(.system(size: data?.labelFontSize ?? 14, weight: .semibold))
                    .foregroundColor(Color(hex: data?.labelColor ?? "#7F1D1D"))
            }
            Group {
                if layout == "boxed" || layout == "banner" {
                    CountdownTimerView(seconds: duration)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: layout == "banner" ? 0 : 12)
                                .fill(Color(hex: data?.backgroundColor ?? "#FEF2F2"))
                        )
                } else {
                    CountdownTimerView(seconds: duration)
                }
            }
        }
    }
}

// MARK: - Legal

private struct LegalSectionView: View {
    let data: PaywallSectionData?
    let context: SectionContext

    var body: some View {
        let textColor = Color(hex: data?.color ?? "#9CA3AF")
        let linkColor = Color(hex: data?.accentColor ?? "#6366F1")
        let size = data?.fontSize ?? 11
        let align: TextAlignment = {
            switch data?.alignment {
            case "left": return .leading
            case "right": return .trailing
            default: return .center
            }
        }()
        VStack(spacing: 8) {
            if let text = data?.text {
                Text(text)
                    .font(.system(size: size))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(align)
            }
            if let links = data?.links, !links.isEmpty {
                HStack(spacing: 16) {
                    ForEach(links, id: \.label) { link in
                        Button {
                            if link.action == "restore" {
                                context.onAction(.custom(type: "restore_purchase", value: nil))
                            } else if let urlStr = link.url {
                                context.onAction(.openWebview(url: urlStr))
                            }
                        } label: {
                            Text(link.label ?? "")
                                .font(.system(size: size))
                                .foregroundColor(linkColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Comparison table

private struct ComparisonTableSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let cols = data?.tableColumns ?? []
        let rows = data?.tableRows ?? []
        let checkColor = Color(hex: data?.checkColor ?? "#22C55E")
        let crossColor = Color(hex: data?.crossColor ?? "#9CA3AF")
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(" ").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                    Text(col.label ?? "")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .foregroundColor(col.highlighted == true ? Color(hex: data?.highlightColor ?? "#6366F1") : .primary)
                }
            }
            .padding(.vertical, 8)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.feature ?? "").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array((row.values ?? []).enumerated()), id: \.offset) { _, val in
                        Group {
                            switch val {
                            case "true", "yes", "✓":
                                Image(systemName: "checkmark.circle.fill").foregroundColor(checkColor)
                            case "false", "no", "✗":
                                Image(systemName: "xmark.circle").foregroundColor(crossColor)
                            default:
                                Text(val).font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Promo input

private struct PromoInputSectionView: View {
    let data: PaywallSectionData?
    let context: SectionContext
    @State private var code: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = data?.title {
                Text(title).font(.subheadline.weight(.semibold))
            }
            HStack {
                TextField(data?.placeholder ?? "Promo code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                Button {
                    context.onAction(.custom(type: "apply_promo", value: code))
                } label: {
                    Text(data?.buttonText ?? "Apply")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(hex: "#6366F1"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .disabled(code.isEmpty)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Reviews carousel

private struct ReviewsCarouselSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let reviews = data?.reviews ?? []
        let showStars = data?.showRatingStars ?? true
        let starColor = Color(hex: data?.starColor ?? "#F59E0B")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(reviews) { review in
                    VStack(alignment: .leading, spacing: 8) {
                        if showStars, let rating = review.rating {
                            HStack(spacing: 2) {
                                ForEach(0..<Int(rating), id: \.self) { _ in
                                    Image(systemName: "star.fill").font(.caption2).foregroundColor(starColor)
                                }
                            }
                        }
                        if let text = review.text {
                            Text(text).font(.caption).foregroundColor(.primary).lineLimit(4)
                        }
                        if let author = review.author {
                            Text("— \(author)").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(width: 220, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#F9FAFB")))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Toggle

private struct ToggleSectionView: View {
    let data: PaywallSectionData?
    @State private var isOn: Bool

    init(data: PaywallSectionData?) {
        self.data = data
        self._isOn = State(initialValue: data?.defaultValue ?? false)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let label = data?.label {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color(hex: data?.labelColorVal ?? "#1F2937"))
                }
                if let desc = data?.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(Color(hex: data?.descriptionColor ?? "#6B7280"))
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color(hex: data?.onColor ?? "#6366F1"))
        }
        .padding(.horizontal)
    }
}

// MARK: - Icon grid

private struct IconGridSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let cols: Int = {
            if let v = data?.columns?.value as? Int { return v }
            if let v = data?.columns?.value as? Double { return Int(v) }
            return 3
        }()
        let iconSize = data?.iconSize ?? 28
        let iconColor = Color(hex: data?.iconColor ?? "#6366F1")
        let items = data?.items ?? []
        let gridCols = Array(repeating: GridItem(.flexible(), spacing: 12), count: max(cols, 1))
        LazyVGrid(columns: gridCols, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 6) {
                    if let icon = item.icon, !icon.isEmpty {
                        Image(systemName: icon)
                            .font(.system(size: iconSize))
                            .foregroundColor(iconColor)
                    }
                    if let label = item.label ?? item.title {
                        Text(label).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                    }
                    if let desc = item.description {
                        Text(desc).font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Carousel

private struct CarouselSectionView: View {
    let data: PaywallSectionData?
    let context: SectionContext

    var body: some View {
        let pages = data?.pages ?? []
        TabView {
            ForEach(pages) { page in
                VStack(spacing: 12) {
                    ForEach(Array((page.children ?? []).enumerated()), id: \.offset) { _, child in
                        childView(for: child)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .tabViewStyle(.page)
        .frame(minHeight: 240)
    }

    @ViewBuilder
    private func childView(for child: PaywallSection) -> some View {
        let anyCodableData: [String: AnyCodable]? = {
            guard let paywallData = child.data else { return nil }
            do {
                let json = try JSONEncoder().encode(paywallData)
                let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
                return dict.mapValues { AnyCodable($0) }
            } catch {
                return nil
            }
        }()
        let screenSection = ScreenSection(
            id: child.id,
            type: "paywall_\(child.type)",
            data: anyCodableData,
            style: nil,
            visibility_condition: nil,
            entrance_animation: nil,
            a11y: nil
        )
        PaywallSectionWrapperImpl.render(section: screenSection, context: context)
    }
}

// MARK: - Card

private struct CardSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let radius = data?.cornerRadius ?? 16
        if let cards = data?.cards, !cards.isEmpty {
            let cols = data?.cardColumns ?? 2
            let gridCols = Array(repeating: GridItem(.flexible(), spacing: 12), count: max(cols, 1))
            LazyVGrid(columns: gridCols, spacing: 12) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    singleCard(card: card, radius: card.corner_radius ?? radius)
                }
            }
            .padding(.horizontal)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let title = data?.title {
                    Text(title).font(.headline).foregroundColor(.primary)
                }
                if let subtitle = data?.subtitle {
                    Text(subtitle).font(.subheadline).foregroundColor(.secondary)
                }
                if let text = data?.text {
                    Text(text).font(.body).foregroundColor(.secondary)
                }
            }
            .padding(data?.padding ?? 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: data?.backgroundColor ?? "#FFFFFF"))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color(hex: data?.borderColor ?? "#E5E7EB"), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        }
    }

    private func singleCard(card: PaywallCardItem, radius: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imgUrl = card.image_url, let url = URL(string: imgUrl) {
                BundledAsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.1)
                }
                .frame(height: 80).clipped()
            }
            if let icon = card.icon, !icon.isEmpty {
                Image(systemName: icon).font(.title2).foregroundColor(Color(hex: "#6366F1"))
            }
            if let title = card.title {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundColor(Color(hex: card.text_color ?? "#1F2937"))
            }
            if let subtitle = card.subtitle {
                Text(subtitle).font(.caption)
                    .foregroundColor(Color(hex: card.text_color ?? "#1F2937").opacity(0.7))
            }
            if let text = card.text {
                Text(text).font(.caption)
                    .foregroundColor(Color(hex: card.text_color ?? "#1F2937").opacity(0.7))
            }
            if let cta = card.cta_text, !cta.isEmpty {
                Text(cta).font(.caption.bold()).foregroundColor(Color(hex: "#6366F1"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: card.bg_color ?? "#FFFFFF"))
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color(hex: card.border_color ?? "#E5E7EB"), lineWidth: 1))
    }
}

// MARK: - Timeline

private struct TimelineSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let items = data?.items ?? []
        let isHorizontal = data?.orientation == "horizontal"
        let lineColor = Color(hex: data?.lineColor ?? "#E5E7EB")
        let showLine = data?.showLine ?? true
        Group {
            if isHorizontal {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            timelineNode(item, index: idx, total: items.count,
                                         isHorizontal: true, showLine: showLine, lineColor: lineColor)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        timelineNode(item, index: idx, total: items.count,
                                     isHorizontal: false, showLine: showLine, lineColor: lineColor)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func nodeColor(_ item: PaywallGenericItem) -> Color {
        if let color = item.color { return Color(hex: color) }
        switch item.status {
        case "completed": return Color(hex: data?.completedColor ?? "#22C55E")
        case "current":   return Color(hex: data?.currentColor ?? "#6366F1")
        default:          return Color(hex: data?.upcomingColor ?? "#9CA3AF")
        }
    }

    @ViewBuilder
    private func timelineNode(_ item: PaywallGenericItem, index: Int, total: Int,
                              isHorizontal: Bool, showLine: Bool, lineColor: Color) -> some View {
        let color = nodeColor(item)
        if isHorizontal {
            VStack(spacing: 8) {
                Circle().fill(color).frame(width: 12, height: 12)
                if let title = item.title {
                    Text(title).font(.caption.weight(.semibold))
                }
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 80)
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Circle().fill(color).frame(width: 12, height: 12)
                    if showLine && index < total - 1 {
                        Rectangle().fill(lineColor).frame(width: 2).frame(maxHeight: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = item.title {
                        Text(title).font(.subheadline.weight(.semibold))
                    }
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Image

private struct ImageSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        Group {
            if let urlString = data?.imageUrl, let url = URL(string: urlString) {
                BundledAsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.15)
                }
                .frame(maxHeight: data?.height ?? 240)
                .clipShape(RoundedRectangle(cornerRadius: data?.cornerRadius ?? 12))
            }
        }
    }
}

// MARK: - Video

private struct VideoSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        Group {
            if let videoUrl = data?.videoUrl {
                VideoBlockView(block: VideoBlock(
                    video_url: videoUrl,
                    video_thumbnail_url: data?.videoThumbnailUrl ?? data?.imageUrl,
                    video_height: Double(data?.videoHeight ?? data?.height ?? 200),
                    video_corner_radius: Double(data?.cornerRadius ?? 12),
                    autoplay: false,
                    loop: false,
                    muted: true,
                    controls: true,
                    inline_playback: true
                ))
            }
        }
    }
}

// MARK: - Lottie

private struct LottieSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        Group {
            if let lottieUrl = data?.lottieUrl {
                LottieBlockView(block: LottieBlock(
                    lottie_url: lottieUrl,
                    lottie_json: nil,
                    autoplay: true,
                    loop: data?.lottieLoop ?? true,
                    speed: data?.lottieSpeed ?? 1.0,
                    width: nil,
                    height: Double(data?.lottieHeight ?? data?.height ?? 180),
                    alignment: "center",
                    play_on_scroll: nil,
                    play_on_tap: nil,
                    color_overrides: nil
                ))
            }
        }
    }
}

// MARK: - Rive

private struct RiveSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        Group {
            if let riveUrl = data?.riveUrl {
                RiveBlockView(block: RiveBlock(
                    rive_url: riveUrl,
                    artboard: nil,
                    state_machine: data?.riveStateMachine,
                    autoplay: true,
                    height: Double(data?.height ?? 180),
                    alignment: "center",
                    inputs: nil,
                    trigger_on_step_complete: nil
                ))
            }
        }
    }
}

// MARK: - Divider

private struct DividerSectionView: View {
    let data: PaywallSectionData?

    var body: some View {
        let color = Color(hex: data?.color ?? "#E5E7EB")
        let thickness = data?.thickness ?? 1
        let mTop = data?.marginTop ?? 8
        let mBottom = data?.marginBottom ?? 8
        let mH = data?.marginHorizontal ?? 0
        VStack(spacing: 0) {
            if let labelText = data?.labelText {
                HStack(spacing: 12) {
                    Rectangle().fill(color).frame(height: thickness)
                    Text(labelText)
                        .font(.system(size: data?.labelFontSize ?? 12))
                        .foregroundColor(Color(hex: data?.labelColor ?? "#9CA3AF"))
                    Rectangle().fill(color).frame(height: thickness)
                }
            } else {
                Rectangle().fill(color).frame(height: thickness)
            }
        }
        .padding(.top, mTop)
        .padding(.bottom, mBottom)
        .padding(.horizontal, mH)
    }
}

// MARK: - Sticky footer

private struct StickyFooterSectionView: View {
    let data: PaywallSectionData?
    let context: SectionContext

    var body: some View {
        let bgColor = Color(hex: data?.backgroundColor ?? "#FFFFFF")
        VStack(spacing: 8) {
            if let ctaText = data?.ctaText {
                Button {
                    context.onAction(.next)
                } label: {
                    Text(ctaText)
                        .font(.system(size: data?.ctaFontSize ?? 17, weight: resolveCTAFontWeight(data?.ctaFontWeight)))
                        .foregroundColor(Color(hex: data?.ctaTextColor ?? "#FFFFFF"))
                }
                .frame(maxWidth: .infinity)
                .frame(height: data?.ctaHeight ?? 52)
                .background(Color(hex: data?.ctaBgColor ?? "#6366F1"))
                .clipShape(RoundedRectangle(cornerRadius: data?.ctaCornerRadius ?? 14))
            }
            if let secondaryText = data?.secondaryText {
                Button {
                    switch data?.secondaryAction {
                    case "restore":
                        context.onAction(.custom(type: "restore_purchase", value: nil))
                    case "link":
                        if let url = data?.secondaryUrl { context.onAction(.openWebview(url: url)) }
                    default:
                        break
                    }
                } label: {
                    Text(secondaryText).font(.caption).foregroundColor(.secondary)
                }
            }
            if let legalText = data?.legalText {
                Text(legalText).font(.system(size: 10)).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, data?.padding ?? 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            Group {
                if data?.blurBackground == true {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    bgColor
                }
            }
        )
    }
}
