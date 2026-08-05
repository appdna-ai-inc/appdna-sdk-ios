import SwiftUI

/// Schema-driven SwiftUI view that renders a PaywallConfig.
struct PaywallRenderer: View {
    let config: PaywallConfig
    let onPlanSelected: (PaywallPlan, _ metadata: [String: Any]) -> Void
    let onRestore: () -> Void
    let onDismiss: (DismissReason) -> Void
    /// AC-037: Callback for promo code validation. Returns true if code is valid, false otherwise.
    var onPromoCodeSubmit: ((String, @escaping (Bool) -> Void) -> Void)? = nil

    @State private var selectedPlanId: String?
    @State private var showDismiss = false
    @State private var isPurchasing = false
    @State private var isDismissing = false
    @State private var dragOffset: CGFloat = 0
    // SPEC-085: Particle effect state
    @State private var showConfetti = false
    // Post-purchase overlay state
    @State private var showSuccessOverlay = false
    @State private var successMessage = ""
    @State private var showErrorBanner = false
    @State private var errorMessage = ""
    @State private var errorRetryText = ""
    @State private var errorAllowRetry = false

    // SPEC-084: Localization helper + SPEC-088: Template variable interpolation
    private func loc(_ key: String, _ fallback: String) -> String {
        let localized = LocalizationEngine.resolve(key: key, localizations: config.localizations, defaultLocale: config.default_locale, fallback: fallback)
        return TemplateEngine.shared.interpolate(localized, context: templateContext)
    }

    // SPEC-088: Cached template context (built once per render cycle)
    private var templateContext: TemplateContext {
        TemplateEngine.shared.buildContext()
    }

    // SPEC-089d: Extract sticky_footer section if present
    private var stickyFooterSection: PaywallSection? {
        config.sections.first(where: { $0.type == "sticky_footer" })
    }

    // Extract CTA section if present (for bottom pinning outside scroll)
    private var ctaSection: PaywallSection? {
        config.sections.first(where: { $0.type == "cta" })
    }

    /// The currently selected plan (matches `onAppear`'s resolution: section plans, then top-level).
    private var selectedPlan: PaywallPlan? {
        let sectionPlans = config.sections.first(where: { $0.type == "plans" })?.data?.plans ?? []
        let plans = sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans
        return plans.first(where: { $0.id == selectedPlanId })
    }

    /// The selected plan's per-plan CTA text, when non-empty. Wired into the pinned CTA + sticky
    /// footer so a plan can override the section/top-level CTA label (e.g. "Start 7-day trial").
    /// Basic wire only — a full selected-plan template-variable namespace ({{plan.*}}) is deferred.
    private var selectedPlanCtaText: String? {
        guard let t = selectedPlan?.cta_text, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return t
    }

    /// Sections that should render INSIDE the pinned bottom area, BELOW the
    /// CTA + restore button. Currently only applies to `legal` sections that
    /// appear AFTER the cta section in the original `config.sections` array.
    /// This lets users put "Terms & Conditions" text directly below the
    /// Restore Purchase button by placing the legal section after the CTA
    /// in the flow editor, instead of having it float between plans and CTA.
    private var pinnedFooterLegalSections: [PaywallSection] {
        guard let ctaIdx = config.sections.firstIndex(where: { $0.type == "cta" }) else {
            return []
        }
        return config.sections.enumerated()
            .filter { $0.offset > ctaIdx && $0.element.type == "legal" }
            .map { $0.element }
    }

    /// IDs of legal sections that have been moved to the pinned footer —
    /// used to exclude them from the scrollable content so they don't render twice.
    private var pinnedFooterLegalIds: Set<String> {
        Set(pinnedFooterLegalSections.map { $0.id ?? "" })
    }

    /// Sections sorted by `style.position.vertical_align` — top bucket first, then middle
    /// (unspecified / center), then bottom. Within each bucket, original array order is preserved.
    /// This makes the console's "Position → Vertical Align" actually move sections within the layout.
    private var orderedSections: [PaywallSection] {
        var topBucket: [PaywallSection] = []
        var midBucket: [PaywallSection] = []
        var bottomBucket: [PaywallSection] = []
        for section in config.sections {
            let va = section.style?.position?.vertical_align
            switch va {
            case "top":    topBucket.append(section)
            case "bottom": bottomBucket.append(section)
            default:       midBucket.append(section)
            }
        }
        return topBucket + midBucket + bottomBucket
    }

    // SPEC-089d: Toggle state for toggle sections
    @State private var toggleStates: [String: Bool] = [:]
    // Scroll offset for collapse-on-scroll sections
    @State private var scrollOffset: CGFloat = 0
    // SPEC-089d: Promo input state
    @State private var promoCode: String = ""
    @State private var promoState: PromoState = .idle

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Scrollable content with pinned bottom CTA
            ScrollView(showsIndicators: false) {
                // spacing: 0 — per-section margins handle all spacing
                VStack(spacing: 0) {
                    // Scroll offset tracker (invisible)
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PaywallScrollOffsetPrefKey.self,
                            value: -geo.frame(in: .named("paywallScroll")).minY
                        )
                    }
                    .frame(height: 0)

                    // CTA and sticky_footer are pinned outside scroll via safeAreaInset.
                    // Sections are bucket-sorted by position.vertical_align so
                    // "top" renders first, "bottom" renders last within the scroll area.
                    ForEach(Array(orderedSections.enumerated()), id: \.offset) { _, section in
                        // CTA and sticky_footer are pinned via safeAreaInset.
                        // Legal sections that come AFTER cta in the original
                        // section array are pinned INSIDE the bottom inset
                        // below the CTA, so skip them here too.
                        let isPinnedLegal = section.type == "legal" && pinnedFooterLegalIds.contains(section.id ?? "")
                        if section.type != "cta" && section.type != "sticky_footer" && !isPinnedLegal {
                            let shouldCollapse = section.collapse_on_scroll == true
                            let collapseProgress = shouldCollapse ? min(max(scrollOffset / 50, 0), 1) : 0

                            if shouldCollapse {
                                sectionView(for: section)
                                    .opacity(Double(1 - collapseProgress))
                                    .frame(maxHeight: collapseProgress >= 1 ? 0 : .infinity)
                                    .clipped()
                                    .animation(.easeInOut(duration: 0.15), value: collapseProgress >= 1)
                            } else {
                                sectionView(for: section)
                            }
                        }
                    }
                }
                .padding(config.layout?.padding ?? 20)
            }
            .coordinateSpace(name: "paywallScroll")
            .onPreferenceChange(PaywallScrollOffsetPrefKey.self) { value in
                scrollOffset = value
            }
            .safeAreaInset(edge: .bottom) {
                // Bottom-pinned CTA + sticky footer (Apple HIG pattern)
                VStack(spacing: 0) {
                    // CTA section from layout — pinned to bottom, outside scroll
                    if let ctaSec = ctaSection {
                        let topLevelText = config.cta?.text
                        let sectionText = ctaSec.data?.ctaText ?? ctaSec.data?.text
                        // Selected plan's per-plan CTA overrides the section/top-level label.
                        let ctaText = selectedPlanCtaText ?? topLevelText ?? sectionText
                        let showRestore = ctaSec.data?.showRestore ?? false
                        let restorePosition = ctaSec.data?.restorePosition ?? "below"
                        // Restore button rendered OUTSIDE `.applyContainerStyle`
                        // so the CTA section's container bg/shadow doesn't extend
                        // under it — restore is effectively a text link and
                        // should always show through to the page background,
                        // regardless of what container styling the subscribe
                        // button has.
                        let restoreView = RestoreLinkView(
                            text: ctaSec.data?.restoreText,
                            show: showRestore,
                            textColor: ctaSec.data?.restoreTextColor,
                            fontSize: ctaSec.data?.restoreFontSize.map { CGFloat($0) },
                            style: ctaSec.style?.elements?["restore_text"]?.textStyle,
                            onRestore: onRestore
                        )
                        VStack(spacing: 8) {
                            if showRestore && restorePosition == "above" {
                                restoreView
                            }
                            CTAButton(
                                cta: config.cta,
                                isPurchasing: isPurchasing,
                                onTap: handleCTATap,
                                loc: loc,
                                sectionStyle: ctaSec.style,
                                ctaGradient: ctaSec.data?.ctaGradient,
                                textOverride: ctaText,
                                ctaFontSize: ctaSec.data?.ctaFontSize,
                                ctaFontWeight: ctaSec.data?.ctaFontWeight,
                                restoreText: nil,          // rendered outside
                                showRestore: false,        // rendered outside
                                onRestore: nil
                            )
                            .ctaAnimation(config.animation?.cta_animation)
                            .applyContainerStyle(ctaSec.style?.container)
                            if showRestore && restorePosition != "above" {
                                restoreView
                            }
                        }
                        .padding(.bottom, 8)
                    } else if let cta = config.cta {
                        // Fallback: top-level CTA button (when no CTA section exists in layout)
                        Button(action: handleCTATap) {
                            if isPurchasing {
                                ProgressView().tint(.white)
                            } else {
                                Text(cta.text ?? "Continue")
                                    .font(cta.resolvedFontSize.map { .system(size: CGFloat($0), weight: .semibold) } ?? .headline)
                                    .foregroundColor(Color(hex: cta.resolvedTextColor))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(cta.resolvedHeight))
                        .background(Color(hex: cta.resolvedBgColor))
                        .cornerRadius(CGFloat(cta.resolvedCornerRadius))
                        .padding(.horizontal, config.layout?.padding ?? 20)
                        .padding(.bottom, 8)
                        .disabled(isPurchasing || selectedPlanId == nil)
                    }

                    // Pinned legal sections — rendered INSIDE the bottom inset
                    // below the CTA + restore button. Activated when a legal
                    // section appears AFTER the cta section in the original
                    // sections array. Uses the horizontal padding from layout
                    // so it matches the CTA's alignment.
                    if !pinnedFooterLegalSections.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(Array(pinnedFooterLegalSections.enumerated()), id: \.offset) { _, legalSec in
                                legalSectionView(data: legalSec.data, style: legalSec.style)
                                    .applyContainerStyle(legalSec.style?.container)
                            }
                        }
                        .padding(.horizontal, CGFloat(config.layout?.padding ?? 20))
                        .padding(.top, 4)
                    }

                    // SPEC-089d: Sticky footer pinned to bottom
                    if let footer = stickyFooterSection {
                        stickyFooterView(data: footer.data, style: footer.style)
                    }
                }
                .padding(.bottom, config.layout?.footer_padding ?? 8)
            }
            // Background as modifier — does NOT corrupt safe area (Apple HIG)
            .background { backgroundView.allowsHitTesting(false) }

            // SPEC-085: Confetti/particle overlay
            if showConfetti, let effect = config.particle_effect {
                ConfettiOverlay(effect: effect)
            }

            // Post-purchase success overlay
            if showSuccessOverlay {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundColor(Color(hex: "#22C55E"))
                        Text(successMessage)
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
                .transition(.opacity)
            }

            // Post-purchase error banner
            if showErrorBanner {
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        if errorAllowRetry {
                            Button {
                                showErrorBanner = false
                                isPurchasing = false
                            } label: {
                                Text(errorRetryText)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 80)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Dismiss control — show by default when config.dismiss is nil (not in Firestore).
            // SPEC-419 — `delay_seconds > 0` REVEALS the dismiss after N seconds and must win
            // even when allowed=false (the winback pattern: force engagement for N seconds, THEN
            // let the user leave). Only a paywall that is BOTH disallowed AND has no delayed
            // reveal is a true hard force-choice. `showDismiss` already flips true after the delay.
            let neverDismissable = !(config.dismiss?.isAllowed ?? true) && (config.dismiss?.delaySeconds ?? 0) <= 0
            if showDismiss && !neverDismissable {
                let dismissStyle = config.dismiss?.style ?? "x_button"
                switch dismissStyle {
                case "text_link":
                    VStack {
                        Spacer()
                        Button {
                            triggerDismiss()
                        } label: {
                            Text(loc("dismiss.text", config.dismiss?.text ?? "No thanks"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 24)
                    }
                case "swipe_down":
                    VStack {
                        Capsule()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 36, height: 5)
                            .padding(.top, 8)
                        Spacer()
                    }
                default: // x_button
                    dismissButton
                }
            }
        }
        .dismissAnimation(config.animation?.dismiss_animation, isDismissing: isDismissing)
        .entryAnimation(config.animation?.entry_animation, durationMs: config.animation?.entry_duration_ms)
        .onAppear {
            // Select default plan — try section.data.plans, then top-level config.plans
            let sectionPlans = config.sections.first(where: { $0.type == "plans" })?.data?.plans ?? []
            let plans = sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans
            if !plans.isEmpty {
                selectedPlanId = plans.first(where: { $0.isDefault == true })?.id ?? plans.first?.id
            }

            // Handle dismiss delay — always show dismiss when config.dismiss is nil (default behavior)
            let dismissDelay = config.dismiss?.delaySeconds ?? 0
            if dismissDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(dismissDelay)) {
                    withAnimation { showDismiss = true }
                }
            } else {
                withAnimation { showDismiss = true }
            }

            // Listen for post-purchase notifications
            NotificationCenter.default.addObserver(forName: .paywallPurchaseSuccess, object: nil, queue: .main) { notif in
                let info = notif.userInfo ?? [:]
                successMessage = info["message"] as? String ?? "Welcome to Premium!"
                withAnimation { showSuccessOverlay = true }
                if info["confetti"] as? Bool == true { showConfetti = true }
            }
            NotificationCenter.default.addObserver(forName: .paywallPurchaseFailure, object: nil, queue: .main) { notif in
                let info = notif.userInfo ?? [:]
                errorMessage = info["message"] as? String ?? "Payment failed."
                errorRetryText = info["retry_text"] as? String ?? "Try Again"
                errorAllowRetry = (info["action"] as? String) == "retry"
                isPurchasing = false
                withAnimation { showErrorBanner = true }
                // Auto-dismiss after 4s when there is no retry button —
                // the banner otherwise has no escape path besides closing
                // the entire paywall (e.g. when host triggers a failure
                // without a retry action, the user sees a "Payment failed"
                // banner pinned to the bottom of the screen indefinitely).
                // When errorAllowRetry is true the banner stays up; user
                // action is required to choose retry vs dismiss.
                if !errorAllowRetry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        withAnimation { showErrorBanner = false }
                    }
                }
            }
        }
        .gesture(
            config.dismiss?.style == "swipe_down" ?
            DragGesture()
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 150 {
                        triggerDismiss()
                    } else {
                        withAnimation { dragOffset = 0 }
                    }
                }
            : nil
        )
        .offset(y: dragOffset)
    }

    // MARK: - Background

    /// Background view — rendered via .background() modifier, NOT as ZStack sibling.
    /// .ignoresSafeArea() is applied here so it extends edge-to-edge behind content.
    @ViewBuilder
    private var backgroundView: some View {
        let bg = config.background ?? config.layout?.background
        switch bg?.type {
        case "gradient":
            if let gradient = bg?.gradient, let stops = gradient.stops, stops.count >= 2 {
                let angle = Angle(degrees: gradient.angle ?? 180)
                let swiftStops = stops.map { stop in
                    Gradient.Stop(
                        color: Color(hex: stop.color ?? "#000000"),
                        location: (stop.position ?? 0) / 100.0
                    )
                }
                let start = UnitPoint(x: 0.5 - cos(angle.radians) * 0.5, y: 0.5 - sin(angle.radians) * 0.5)
                let end = UnitPoint(x: 0.5 + cos(angle.radians) * 0.5, y: 0.5 + sin(angle.radians) * 0.5)
                LinearGradient(stops: swiftStops, startPoint: start, endPoint: end)
                    .ignoresSafeArea()
            } else if let colors = bg?.colors, colors.count >= 2 {
                LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        case "image":
            let urlString = bg?.image_url ?? bg?.value
            if let urlString, let url = URL(string: urlString) {
                BundledAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.black
                }
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        case "video":
            ZStack {
                Color.black.ignoresSafeArea()
                if let videoUrlStr = bg?.video_url ?? bg?.value,
                   let videoUrl = URL(string: videoUrlStr) {
                    VideoBackgroundView(url: videoUrl)
                        .ignoresSafeArea()
                }
            }
        case "color":
            let colorVal = bg?.color ?? bg?.value ?? "#FFFFFF"
            if colorVal == "transparent" || colorVal == "clear" {
                Color.clear.ignoresSafeArea()
            } else {
                Color(hex: colorVal).ignoresSafeArea()
            }
        case "transparent", "clear", "none":
            Color.clear.ignoresSafeArea()
        default:
            Color(.systemBackground).ignoresSafeArea()
        }
    }

    // MARK: - Dismiss helpers

    private func triggerDismiss() {
        if config.animation?.dismiss_animation != nil {
            isDismissing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onDismiss(.dismissed)
            }
        } else {
            onDismiss(.dismissed)
        }
    }

    private var dismissButton: some View {
        Button {
            triggerDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.3))
                .clipShape(Circle())
        }
        .padding(16)
        .transition(.opacity)
    }

    // MARK: - Section rendering (AnyView to avoid exponential type-checking on 24-case switch)

    private func sectionView(for section: PaywallSection) -> some View {
        let staggerDelay = config.animation?.section_stagger_delay_ms ?? 0
        let margin = section.style?.margin
        let hasExplicitMargin = margin != nil && (
            (margin?.top != nil && margin?.top != 0) ||
            (margin?.bottom != nil && margin?.bottom != 0) ||
            (margin?.left != nil && margin?.left != 0) ||
            (margin?.right != nil && margin?.right != 0) ||
            (margin?.leading != nil && margin?.leading != 0) ||
            (margin?.trailing != nil && margin?.trailing != 0)
        )
        let defaultSpacing = config.layout?.spacing ?? 16
        // Sections with explicit margins use those; others get default layout spacing as bottom gap
        let top = CGFloat(margin?.top ?? 0)
        let bottom = hasExplicitMargin ? CGFloat(margin?.bottom ?? 0) : CGFloat(defaultSpacing)
        let left = CGFloat(margin?.leading ?? margin?.left ?? 0)
        let right = CGFloat(margin?.trailing ?? margin?.right ?? 0)
        return sectionContent(for: section)
            .padding(EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right))
            .sectionStagger(config.animation?.section_stagger, delayMs: staggerDelay)
    }

    private func sectionContent(for section: PaywallSection) -> AnyView {
        switch section.type {
        case "header":
            return AnyView(HeaderSection(data: section.data, loc: loc, sectionStyle: section.style)
                .applyContainerStyle(section.style?.container))
        case "features":
            return AnyView(FeatureList(
                features: (section.data?.features ?? []).enumerated().map { i, f in loc("feature.\(i)", f) },
                richItems: section.data?.items,
                columns: Int(section.data?.featureColumns ?? 1),
                gap: section.data?.featureGap ?? 12,
                sectionStyle: section.style,
                iconColorOverride: section.data?.iconColor,
                itemTextColorOverride: section.data?.itemTextColor,
                iconBgColor: section.data?.iconBgColor,
                iconBgOpacity: section.data?.iconBgOpacity ?? 0.15,
                iconBgSize: section.data?.iconBgSize ?? 32)
                .applyContainerStyle(section.style?.container))
        case "plans":
            // Plans can be in section.data.plans OR top-level config.plans
            let sectionPlans = section.data?.plans ?? []
            let effectivePlans = sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans
            return AnyView(plansSection(plans: effectivePlans, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "cta":
            // CTA section: top-level cta.text takes priority, then section config text
            let topLevelText = config.cta?.text
            let sectionText = section.data?.ctaText ?? section.data?.text
            let ctaText = topLevelText ?? sectionText
            return AnyView(CTAButton(
                cta: config.cta,
                isPurchasing: isPurchasing,
                onTap: handleCTATap,
                loc: loc,
                sectionStyle: section.style,
                ctaGradient: section.data?.ctaGradient,
                textOverride: ctaText,
                ctaFontSize: section.data?.ctaFontSize,
                ctaFontWeight: section.data?.ctaFontWeight,
                restoreText: section.data?.restoreText,
                showRestore: section.data?.showRestore ?? false,
                restorePosition: section.data?.restorePosition ?? "below",
                restoreTextColor: section.data?.restoreTextColor,
                restoreFontSize: section.data?.restoreFontSize.map { CGFloat($0) }
            )
            .ctaAnimation(config.animation?.cta_animation)
            .applyContainerStyle(section.style?.container))
        case "social_proof":
            return AnyView(socialProofSection(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "guarantee":
            return AnyView(guaranteeSectionView(data: section.data, style: section.style))
        case "image":
            return AnyView(imageSectionView(data: section.data, style: section.style))
        case "spacer":
            return AnyView(Spacer().frame(height: section.data?.spacerHeight ?? 24))
        case "testimonial":
            return AnyView(testimonialSectionView(data: section.data, style: section.style))
        case "lottie":
            return AnyView(lottieSectionView(data: section.data, style: section.style))
        case "video", "video_background":
            return AnyView(videoSectionView(data: section.data, style: section.style))
        case "rive":
            return AnyView(riveSectionView(data: section.data, style: section.style))
        case "countdown":
            return AnyView(countdownSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "legal":
            return AnyView(legalSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "divider":
            return AnyView(dividerSectionView(data: section.data, style: section.style))
        case "sticky_footer":
            return AnyView(EmptyView()) // Rendered outside ScrollView
        case "card":
            return AnyView(cardSectionView(data: section.data, style: section.style))
        case "carousel":
            return AnyView(carouselSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "timeline":
            return AnyView(timelineSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "icon_grid":
            return AnyView(iconGridSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "comparison_table":
            return AnyView(comparisonTableSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "promo_input":
            return AnyView(promoInputSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "toggle":
            return AnyView(toggleSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "reviews_carousel":
            return AnyView(reviewsCarouselSectionView(data: section.data, style: section.style)
                .applyContainerStyle(section.style?.container))
        default:
            return AnyView(EmptyView())
        }
    }

    // MARK: - Guarantee section (extracted from inline switch case)

    @ViewBuilder
    private func guaranteeSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let hasContent = data?.guaranteeText != nil || data?.title != nil || data?.text != nil || data?.description != nil
        if hasContent {
            VStack(spacing: 8) {
                // Icon (SF Symbol or fallback shield)
                if let iconName = data?.icon {
                    let sfName = iconName.contains("_") || iconName.contains(".") ? iconName : "shield.checkmark.fill"
                    Image(systemName: sfName)
                        .font(.system(size: 28))
                        .foregroundColor(Color(hex: data?.accentColor ?? "#22C55E"))
                } else {
                    Image(systemName: "shield.checkmark.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color(hex: data?.accentColor ?? "#22C55E"))
                }

                // Badge text
                if let badge = data?.guaranteeText ?? data?.text {
                    let badgeTs = style?.elements?["badge"]?.textStyle
                    if let ts = badgeTs {
                        Text(loc("guarantee.badge", badge))
                            .applyTextStyle(ts)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color(hex: data?.accentColor ?? "#22C55E").opacity(0.15))
                            .clipShape(Capsule())
                    } else {
                        Text(loc("guarantee.badge", badge))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Color(hex: data?.accentColor ?? "#22C55E"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color(hex: data?.accentColor ?? "#22C55E").opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                // Title
                if let title = data?.title {
                    let titleTs = style?.elements?["title"]?.textStyle
                    if let ts = titleTs {
                        Text(loc("guarantee.title", title)).applyTextStyle(ts)
                    } else {
                        Text(loc("guarantee.title", title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                    }
                }

                // Description
                if let desc = data?.description ?? (data?.title != nil ? (data?.text ?? data?.guaranteeText) : nil) {
                    let textTs = style?.elements?["text"]?.textStyle ?? style?.elements?["description"]?.textStyle
                    if let ts = textTs {
                        Text(loc("guarantee.description", desc))
                            .applyTextStyle(ts)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(loc("guarantee.description", desc))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .applyContainerStyle(style?.container)
        }
    }

    // MARK: - SPEC-084: Social proof with sub-types

    private func socialProofSection(data: PaywallSectionData?, style: SectionStyleConfig?) -> AnyView {
        switch data?.subType {
        case "countdown":
            return AnyView(CountdownTimerView(seconds: data?.countdownSeconds ?? 86400, valueTextStyle: style?.elements?["value"]?.textStyle))
        case "trial_badge":
            if let ts = style?.elements?["value"]?.textStyle {
                return AnyView(Text(loc("social_proof.trial_badge", data?.text ?? "Free Trial"))
                    .applyTextStyle(ts)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")).opacity(0.15))
                    .clipShape(Capsule()))
            } else {
                return AnyView(Text(loc("social_proof.trial_badge", data?.text ?? "Free Trial"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")).opacity(0.15))
                    .foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                    .clipShape(Capsule()))
            }
        default: // app_rating
            return AnyView(SocialProof(data: data, loc: loc, sectionStyle: style))
        }
    }

    // MARK: - SPEC-084: Image section

    @ViewBuilder
    private func imageSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let urlString = data?.imageUrl, let url = URL(string: urlString) {
            BundledAsyncPhaseImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxHeight: data?.height ?? 240)
                        .clipShape(RoundedRectangle(cornerRadius: data?.cornerRadius ?? 12))
                default:
                    ProgressView().frame(height: data?.height ?? 240)
                }
            }
            .applyContainerStyle(style?.container)
        }
    }

    // MARK: - SPEC-084: Testimonial section

    private func testimonialSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let quoteTextStyle = style?.elements?["quote"]?.textStyle
        let authorNameTextStyle = style?.elements?["author_name"]?.textStyle
        let authorRoleTextStyle = style?.elements?["author_role"]?.textStyle
        let layout = data?.layout ?? "quote"

        let content = VStack(spacing: 12) {
            // Quote mark only for "quote" layout
            if layout == "quote" {
                Text("\u{201C}")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
            }

            if let ts = quoteTextStyle {
                Text(loc("testimonial.quote", data?.quote ?? data?.testimonial ?? ""))
                    .applyTextStyle(ts)
            } else {
                Text(loc("testimonial.quote", data?.quote ?? data?.testimonial ?? ""))
                    .italic()
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .font(layout == "minimal" ? .caption : .body)
            }

            if layout != "minimal" {
                HStack(spacing: 12) {
                    if let avatarUrl = data?.avatarUrl, let url = URL(string: avatarUrl) {
                        BundledAsyncPhaseImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    } else if let name = data?.authorName {
                        Circle()
                            .fill(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")).opacity(0.2))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Text(initials(name))
                                    .font(.caption.bold())
                                    .foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if let name = data?.authorName {
                            let interpolatedName = loc("testimonial.author_name", name)
                            if let ts = authorNameTextStyle {
                                Text(interpolatedName).applyTextStyle(ts)
                            } else {
                                Text(interpolatedName).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                            }
                        }
                        if let role = data?.authorRole {
                            let interpolatedRole = loc("testimonial.author_role", role)
                            if let ts = authorRoleTextStyle {
                                Text(interpolatedRole).applyTextStyle(ts)
                            } else {
                                Text(interpolatedRole).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } else if let name = data?.authorName {
                // Minimal: just author name inline
                Text("— \(loc("testimonial.author_name", name))")
                    .font(.caption.weight(.medium)).foregroundColor(.secondary)
            }
        }
        .padding(layout == "card" ? 16 : 0)

        return Group {
            if layout == "card" {
                content
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#F9FAFB")))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#E5E7EB"), lineWidth: 1))
                    .padding(.horizontal)
            } else {
                content
            }
        }
        .applyContainerStyle(style?.container)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first.map { String($0.prefix(1)) } ?? ""
        let last = parts.count > 1 ? (parts.last.map { String($0.prefix(1)) } ?? "") : ""
        return (first + last).uppercased()
    }

    // MARK: - SPEC-085: Lottie section

    @ViewBuilder
    private func lottieSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let lottieUrl = data?.lottieUrl {
            let block = LottieBlock(
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
            )
            LottieBlockView(block: block)
                .applyContainerStyle(style?.container)
        }
    }

    // MARK: - SPEC-085: Video section

    @ViewBuilder
    private func videoSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let videoUrl = data?.videoUrl {
            let block = VideoBlock(
                video_url: videoUrl,
                video_thumbnail_url: data?.videoThumbnailUrl ?? data?.imageUrl,
                video_height: Double(data?.videoHeight ?? data?.height ?? 200),
                video_corner_radius: Double(data?.cornerRadius ?? 12),
                autoplay: false,
                loop: false,
                muted: true,
                controls: true,
                inline_playback: true
            )
            VideoBlockView(block: block)
                .applyContainerStyle(style?.container)
        }
    }

    // MARK: - SPEC-085: Rive section

    @ViewBuilder
    private func riveSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let riveUrl = data?.riveUrl {
            let block = RiveBlock(
                rive_url: riveUrl,
                artboard: nil,
                state_machine: data?.riveStateMachine,
                autoplay: true,
                height: Double(data?.height ?? 180),
                alignment: "center",
                inputs: nil,
                trigger_on_step_complete: nil
            )
            RiveBlockView(block: block)
                .applyContainerStyle(style?.container)
        }
    }

    // MARK: - SPEC-089d: Countdown section (AC-028)

    @ViewBuilder
    private func countdownSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let duration = data?.durationSeconds ?? data?.countdownSeconds ?? 3600
        let valueTextStyle = style?.elements?["value"]?.textStyle
        let layout = data?.layout ?? "inline"
        // Round-11 Finding 4 — prefer `label_text` (the countdown-specific console field) over the
        // generic `label`, matching Android (PaywallActivity: `label_text ?: label`). iOS had the
        // precedence inverted, so a section with both set rendered a different string per platform.
        let labelText = data?.labelText ?? data?.label

        VStack(spacing: 8) {
            // Label text (e.g. "Offer ends in")
            if let label = labelText {
                // Round-23 — honor the authored `label_font_size` + `label_color` (both decoded but
                // ignored) with Android's exact defaults (14pt, semibold, #7F1D1D dark-red). iOS was
                // hardcoded to `.caption`(~12pt)/medium/system-grey, so the label size was silently
                // dropped and the default color differed on every countdown (grey vs dark-red) from Android.
                Text(loc("countdown.label", label))
                    .font(.system(size: data?.labelFontSize ?? 14, weight: .semibold))
                    .foregroundColor(Color(hex: data?.labelColor ?? "#7F1D1D"))
            }

            if layout == "boxed" || layout == "banner" {
                CountdownTimerView(seconds: duration, valueTextStyle: valueTextStyle)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: layout == "banner" ? 0 : 12)
                            .fill(Color(hex: data?.backgroundColor ?? "#FEF2F2"))
                    )
            } else {
                CountdownTimerView(seconds: duration, valueTextStyle: valueTextStyle)
            }
        }
    }

    // MARK: - SPEC-089d: Legal section (AC-029)

    @ViewBuilder
    private func legalSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let textColor = Color(hex: data?.color ?? "#9CA3AF")
        let linkColor = Color(hex: data?.accentColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let size = data?.fontSize ?? 11
        let textAlignment: TextAlignment = {
            switch data?.alignment {
            case "left": return .leading
            case "right": return .trailing
            default: return .center
            }
        }()

        VStack(spacing: 8) {
            if let text = data?.text {
                // Parse markdown-style links: [text](url)
                Text(parseMarkdownLinks(text))
                    .font(.system(size: size))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(textAlignment)
                    .tint(linkColor)
            }

            if let links = data?.links, !links.isEmpty {
                HStack(spacing: 16) {
                    ForEach(links, id: \.label) { link in
                        if link.action == "restore" {
                            Button {
                                onRestore()
                            } label: {
                                Text(link.label ?? "Restore Purchases")
                                    .font(.system(size: size))
                                    .foregroundColor(linkColor)
                            }
                        } else if let urlStr = link.url, let url = URL(string: urlStr) {
                            // Use Button + InAppBrowser instead of SwiftUI Link.
                            // Link(...) hands URLs to UIApplication.open which
                            // launches Safari — we want a sheet-style in-app browser
                            // so users stay in the app.
                            Button {
                                InAppBrowser.present(url: url)
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
        }
        .frame(maxWidth: .infinity)
        // Intercept URL opens from any inline markdown links inside the
        // Text(AttributedString) above. Without this, tapping a markdown
        // link in the legal paragraph launches Safari. OpenURLAction
        // returns .handled so SwiftUI doesn't pass the URL to UIApplication.
        .environment(\.openURL, OpenURLAction { url in
            InAppBrowser.present(url: url)
            return .handled
        })
    }

    /// The sticky footer's secondary action, resolved.
    ///
    /// SPEC-070-B W11 — `internal static` so the test can drive the REAL code. The Button body above
    /// is now a single call to this; deleting the `URLSafety` hop below turns that test red.
    ///
    /// 🔴 This used to be `URL(string: data.secondaryUrl)` → `UIApplication.shared.open(url)`,
    /// inline in the Button. `URLSafety` was right there, tested, and unused on the one surface where
    /// the config decides where the user's money goes. A paywall config naming `javascript:` opened
    /// `javascript:`.
    internal static func performSecondaryAction(
        action: String?,
        url: String?,
        onRestore: () -> Void
    ) {
        switch action {
        case "restore":
            onRestore()
        case "link":
            URLSafety.open(url)
        default:
            break
        }
    }

    private func parseMarkdownLinks(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        // Simple markdown link parser: [label](url)
        let pattern = "\\[([^\\]]+)\\]\\(([^)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        // Reconstruct attributed string with links
        var attrStr = AttributedString()
        var remaining = text
        while let match = regex.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) {
            guard let labelRange = Range(match.range(at: 1), in: remaining),
                  let urlRange = Range(match.range(at: 2), in: remaining),
                  let fullRange = Range(match.range, in: remaining) else { break }
            // Add text before the match
            let beforeText = String(remaining[remaining.startIndex..<fullRange.lowerBound])
            attrStr.append(AttributedString(beforeText))
            // Add the link
            let label = String(remaining[labelRange])
            let urlString = String(remaining[urlRange])
            var linkAttr = AttributedString(label)
            if let url = URL(string: urlString) {
                linkAttr.link = url
            }
            attrStr.append(linkAttr)
            remaining = String(remaining[fullRange.upperBound...])
        }
        if !remaining.isEmpty {
            attrStr.append(AttributedString(remaining))
        }
        return attrStr.characters.isEmpty ? result : attrStr
    }

    // MARK: - SPEC-089d: Divider section (AC-030)

    @ViewBuilder
    private func dividerSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let dividerColor = Color(hex: data?.color ?? "#E5E7EB")
        let thickness = data?.thickness ?? 1
        let lineStyle = data?.lineStyle ?? "solid"
        let mTop = data?.marginTop ?? 8
        let mBottom = data?.marginBottom ?? 8
        let mH = data?.marginHorizontal ?? 0

        VStack(spacing: 0) {
            if let labelText = data?.labelText {
                // Divider with centered label
                HStack(spacing: 12) {
                    dividerLine(color: dividerColor, thickness: thickness, style: lineStyle)
                    Text(labelText)
                        .font(.system(size: data?.labelFontSize ?? 12))
                        .foregroundColor(Color(hex: data?.labelColor ?? "#9CA3AF"))
                        .padding(.horizontal, 8)
                        .background(Color.clear)
                    dividerLine(color: dividerColor, thickness: thickness, style: lineStyle)
                }
            } else {
                dividerLine(color: dividerColor, thickness: thickness, style: lineStyle)
            }
        }
        .padding(.top, mTop)
        .padding(.bottom, mBottom)
        .padding(.horizontal, mH)
    }

    private func dividerLine(color: Color, thickness: CGFloat, style: String) -> AnyView {
        switch style {
        case "dashed":
            return AnyView(Line()
                .stroke(style: StrokeStyle(lineWidth: thickness, dash: [6, 3]))
                .foregroundColor(color)
                .frame(height: thickness))
        case "dotted":
            return AnyView(Line()
                .stroke(style: StrokeStyle(lineWidth: thickness, dash: [2, 2]))
                .foregroundColor(color)
                .frame(height: thickness))
        default: // solid
            return AnyView(Rectangle()
                .fill(color)
                .frame(height: thickness))
        }
    }

    // MARK: - SPEC-089d: Sticky footer (AC-031)

    @ViewBuilder
    private func stickyFooterView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let bgColor = Color(hex: data?.backgroundColor ?? "#FFFFFF")

        VStack(spacing: 8) {
            // CTA button — selected plan's per-plan CTA overrides the footer's configured label.
            if let ctaText = selectedPlanCtaText ?? data?.ctaText {
                Button {
                    handleCTATap()
                } label: {
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(loc("sticky_footer.cta", ctaText))
                            .font(.system(size: data?.ctaFontSize ?? 17, weight: resolveCTAFontWeight(data?.ctaFontWeight)))
                            .foregroundColor(Color(hex: data?.ctaTextColor ?? "#FFFFFF"))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: data?.ctaHeight ?? 52)
                .background(Color(hex: data?.ctaBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                .clipShape(RoundedRectangle(cornerRadius: data?.ctaCornerRadius ?? 14))
                .disabled(isPurchasing)
            }

            // Secondary action
            if let secondaryText = data?.secondaryText {
                Button {
                    Self.performSecondaryAction(
                        action: data?.secondaryAction,
                        url: data?.secondaryUrl,
                        onRestore: onRestore
                    )
                } label: {
                    Text(loc("sticky_footer.secondary", secondaryText))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Legal text
            if let legalText = data?.legalText {
                Text(loc("sticky_footer.legal", legalText))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
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
        .applyContainerStyle(style?.container)
    }

    // MARK: - SPEC-089d: Card section (AC-032)

    @ViewBuilder
    private func cardSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let radius = data?.cornerRadius ?? 16

        if let cards = data?.cards, !cards.isEmpty {
            // Multi-card grid
            let cols = data?.cardColumns ?? 2
            let gridCols = Array(repeating: GridItem(.flexible(), spacing: 12), count: cols)
            LazyVGrid(columns: gridCols, spacing: 12) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    singleCardView(card: card, radius: card.corner_radius ?? radius)
                }
            }
            .padding(.horizontal)
            .applyContainerStyle(style?.container)
        } else {
            // Single card (legacy)
            VStack(alignment: .leading, spacing: 12) {
                if let title = data?.title {
                    Text(loc("card.title", title)).font(.headline).foregroundColor(.primary)
                }
                if let subtitle = data?.subtitle {
                    Text(loc("card.subtitle", subtitle)).font(.subheadline).foregroundColor(.secondary)
                }
                if let text = data?.text {
                    Text(loc("card.body", text)).font(.body).foregroundColor(.secondary)
                }
            }
            .padding(data?.padding ?? 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: data?.backgroundColor ?? "#FFFFFF"))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color(hex: data?.borderColor ?? "#E5E7EB"), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            .applyContainerStyle(style?.container)
        }
    }

    private func singleCardView(card: PaywallCardItem, radius: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imgUrl = card.image_url, let url = URL(string: imgUrl) {
                BundledAsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.1) }
                    .frame(height: 80).clipped()
            }
            if let icon = card.icon, !icon.isEmpty {
                Image(systemName: icon).font(.title2).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
            }
            if let title = card.title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(Color(hex: card.text_color ?? "#1F2937"))
            }
            if let subtitle = card.subtitle {
                Text(subtitle).font(.caption).foregroundColor(Color(hex: card.text_color ?? "#1F2937").opacity(0.7))
            }
            if let text = card.text {
                Text(text).font(.caption).foregroundColor(Color(hex: card.text_color ?? "#1F2937").opacity(0.7))
            }
            if let cta = card.cta_text, !cta.isEmpty {
                Text(cta).font(.caption.bold()).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: card.bg_color ?? "#FFFFFF"))
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color(hex: card.border_color ?? "#E5E7EB"), lineWidth: 1))
    }

    // MARK: - SPEC-089d: Carousel section (AC-033)

    @ViewBuilder
    private func carouselSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let pages = data?.pages, !pages.isEmpty {
            CarouselView(
                pages: pages,
                config: config,
                autoScroll: data?.autoScroll ?? false,
                autoScrollIntervalMs: data?.autoScrollIntervalMs ?? 3000,
                showIndicators: data?.showIndicators ?? true,
                indicatorColor: data?.indicatorColor ?? "#666666",
                indicatorActiveColor: data?.indicatorActiveColor ?? "#FFFFFF",
                height: data?.height,
                loc: loc
            )
        }
    }

    // MARK: - SPEC-089d: Timeline section (AC-034)

    @ViewBuilder
    private func timelineSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let items = data?.items ?? []
        let isCompact = data?.compact ?? false
        let showLine = data?.showLine ?? true
        let isHorizontal = data?.orientation == "horizontal"

        if isHorizontal {
            // Horizontal timeline
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 8) {
                            let statusColor = timelineStatusColor(
                                status: item.status ?? "upcoming",
                                completedColor: data?.completedColor ?? "#22C55E",
                                currentColor: data?.currentColor ?? (AppDNA.brandAccentHex ?? "#6366F1"),
                                upcomingColor: data?.upcomingColor ?? "#666666"
                            )
                            HStack(spacing: 0) {
                                if index > 0 && showLine {
                                    Rectangle().fill(Color(hex: data?.lineColor ?? "#D1D5DB")).frame(height: 2)
                                }
                                ZStack {
                                    Circle().fill(statusColor).frame(width: 24, height: 24)
                                    if item.status == "completed" {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                                    }
                                }
                                if index < items.count - 1 && showLine {
                                    Rectangle().fill(Color(hex: data?.lineColor ?? "#D1D5DB")).frame(height: 2)
                                }
                            }
                            if let title = item.title {
                                Text(title).font(.caption.weight(.semibold)).foregroundColor(.primary).multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 80)
                    }
                }
                .padding(.horizontal, 8)
            }
        } else {
        // Vertical timeline (default)
        let connectorColor = Color(hex: data?.lineColor ?? style?.elements?["connector"]?.textStyle?.color ?? "#FFFFFF")
        let titleFontSize = CGFloat(data?.fontSize ?? 14)
        let itemSpacing: CGFloat = isCompact ? 12 : 20

        HStack(alignment: .top, spacing: 12) {
            // Left column: continuous line with dots
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let itemColor = item.color.map { Color(hex: $0) } ?? timelineStatusColor(
                        status: item.status ?? "upcoming",
                        completedColor: data?.completedColor ?? "#22C55E",
                        currentColor: data?.currentColor ?? (AppDNA.brandAccentHex ?? "#6366F1"),
                        upcomingColor: data?.upcomingColor ?? "#666666"
                    )

                    Circle()
                        .fill(itemColor.opacity(0.6))
                        .frame(width: 8, height: 8)

                    if showLine && index < items.count - 1 {
                        Rectangle()
                            .fill(connectorColor.opacity(0.25))
                            .frame(width: 1, height: itemSpacing)
                    }
                }
            }
            .padding(.top, 5) // Align dots with text center

            // Right column: text labels
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let itemColor = item.color.map { Color(hex: $0) } ?? timelineStatusColor(
                        status: item.status ?? "upcoming",
                        completedColor: data?.completedColor ?? "#22C55E",
                        currentColor: data?.currentColor ?? (AppDNA.brandAccentHex ?? "#6366F1"),
                        upcomingColor: data?.upcomingColor ?? "#666666"
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        if let title = item.title {
                            Text(title)
                                .font(.system(size: titleFontSize, weight: .medium))
                                .foregroundColor(itemColor)
                        }
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(itemColor.opacity(0.7))
                        }
                    }
                    .frame(height: 8 + (index < items.count - 1 ? itemSpacing : 0), alignment: .top)
                }
            }
        }
        } // close else (vertical)
    }

    private func timelineStatusColor(status: String, completedColor: String, currentColor: String, upcomingColor: String) -> Color {
        switch status {
        case "completed": return Color(hex: completedColor)
        case "current": return Color(hex: currentColor)
        default: return Color(hex: upcomingColor)
        }
    }

    // MARK: - SPEC-089d: Icon grid section (AC-035)

    @ViewBuilder
    private func iconGridSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let items = data?.items ?? []
        let columnCount = (data?.columns?.value as? Int) ?? 3
        let gridSpacing = data?.spacing ?? 16
        let iconSz = data?.iconSize ?? 32
        let iconClr = data?.iconColor ?? (AppDNA.brandAccentHex ?? "#6366F1")

        let gridColumns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)

        LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 8) {
                    if let icon = item.icon {
                        // Check if it's an emoji or SF Symbol
                        if icon.count <= 2 && icon.unicodeScalars.allSatisfy({ $0.value > 127 }) {
                            Text(icon)
                                .font(.system(size: iconSz))
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: iconSz * 0.6))
                                .foregroundColor(Color(hex: iconClr))
                                .frame(width: iconSz, height: iconSz)
                        }
                    }

                    if let label = item.label ?? item.title {
                        let ts = style?.elements?["title"]?.textStyle
                        if let ts = ts {
                            Text(label).applyTextStyle(ts)
                        } else {
                            Text(label)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    if let desc = item.description ?? item.subtitle {
                        let ds = style?.elements?["description"]?.textStyle
                        if let ds = ds {
                            Text(desc).applyTextStyle(ds)
                        } else {
                            Text(desc)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - SPEC-089d: Comparison table section (AC-036)

    private func comparisonTableSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        // Column labels: prefer structured tableColumns, fall back to plain string array from AnyCodable columns
        let structuredCols = data?.tableColumns ?? []
        let columnLabels: [String]
        let columnHighlights: [Bool]
        if !structuredCols.isEmpty {
            columnLabels = structuredCols.map { $0.label ?? "" }
            columnHighlights = structuredCols.map { $0.highlighted ?? false }
        } else if let colStrings = data?.columns?.value as? [String] {
            columnLabels = colStrings
            columnHighlights = Array(repeating: false, count: colStrings.count)
        } else {
            columnLabels = []
            columnHighlights = []
        }
        let rows = data?.tableRows ?? []
        let checkClr = Color(hex: data?.checkColor ?? "#22C55E")
        let crossClr = Color(hex: data?.crossColor ?? "#D1D5DB")
        let highlightClr = Color(hex: data?.highlightColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let borderClr = Color(hex: data?.borderColor ?? "#E5E7EB")
        let radius = data?.cornerRadius ?? 12

        return VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                // Feature column header
                Text("Feature")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)

                ForEach(Array(columnLabels.enumerated()), id: \.offset) { colIdx, label in
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(colIdx < columnHighlights.count && columnHighlights[colIdx] ? highlightClr.opacity(0.15) : Color.clear)
                }
            }
            .background(Color(hex: "#F9FAFB"))

            Divider().background(borderClr)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    Text(row.feature ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)

                    ForEach(Array((row.values ?? []).enumerated()), id: \.offset) { valIdx, value in
                        Group {
                            switch value.lowercased() {
                            case "check", "true", "yes", "y", "✓":
                                Image(systemName: "checkmark")
                                    .foregroundColor(checkClr)
                                    .font(.caption.weight(.bold))
                            case "cross", "false", "no", "n", "-", "✗":
                                Image(systemName: "xmark")
                                    .foregroundColor(crossClr)
                                    .font(.caption.weight(.bold))
                            case "partial", "~":
                                Image(systemName: "minus")
                                    .foregroundColor(Color(hex: "#FBBF24"))
                                    .font(.caption.weight(.bold))
                            default:
                                Text(value)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            valIdx < columnHighlights.count && columnHighlights[valIdx]
                                ? highlightClr.opacity(0.08)
                                : Color.clear
                        )
                    }
                }

                if rowIdx < rows.count - 1 {
                    Divider().background(borderClr.opacity(0.3))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(borderClr, lineWidth: 1)
        )
    }

    // MARK: - SPEC-089d: Promo input section (AC-037)

    /**
     SPEC-070-B AC-30(b) — what a promo code submission resolves to. A REVENUE path.

     🔴 The original: a paywall with NO delegate ran

         updateState(code.isNotBlank() ? "success" : "error")

     so ANY non-blank string the user typed rendered "Code applied!", and the CTA path then folded
     that unvalidated string into the purchase metadata as `promo_code` — presented downstream as if
     the app had validated it. Nobody had. The SDK cannot validate a code; only the host can. So when
     there is no host to ask, the only honest answer is REJECT, which is also what every delegate
     default already answers on timeout.

     Android proves this by driving the real composable (`PromoCodeFallbackTest`). iOS shipped the
     same fix inline in a `Button` action — where no test could reach it — and asserted nothing. This
     function IS the shipped decision (the button calls it and does nothing else), so a test that
     calls it exercises the branch that ships rather than a re-implementation of it.

     `internal`, not `private`, for exactly that reason.
     */
    internal static func resolvePromoSubmission(
        code: String,
        onPromoCodeSubmit: ((String, @escaping (Bool) -> Void) -> Void)?,
        setState: @escaping (PromoState) -> Void
    ) {
        setState(.loading)
        guard let onPromoCodeSubmit else {
            // No delegate configured — we cannot validate the code, so we must NOT report success.
            Log.warning("Promo code submitted but no AppDNAPaywallDelegate is registered — rejecting. Implement onPromoCodeSubmit to validate codes.")
            setState(.error)
            return
        }
        onPromoCodeSubmit(code) { isValid in
            // The host may answer on any thread; `promoState` drives SwiftUI.
            DispatchQueue.main.async {
                setState(isValid ? .success : .error)
            }
        }
    }

    @ViewBuilder
    private func promoInputSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        HStack(spacing: 8) {
            TextField(data?.placeholder ?? "Promo code", text: $promoCode)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(hex: "#F9FAFB"))
                .cornerRadius(8)
                .foregroundColor(.primary)
                .font(.subheadline)

            Button {
                // AC-037: Submit promo code via delegate callback.
                //
                // The decision itself lives in `resolvePromoSubmission` — see there. It is not inlined
                // here because a decision inlined in a `Button` action inside a `@ViewBuilder` is
                // reachable by nothing: SwiftUI has no equivalent of Android's Compose test rule in
                // this SDK, so the ONLY way this branch can be under test is for it to be a function.
                // It was inline, and it was the one branch on this whole screen that nothing asserted.
                Self.resolvePromoSubmission(
                    code: promoCode,
                    onPromoCodeSubmit: onPromoCodeSubmit
                ) { newState in
                    promoState = newState
                }
            } label: {
                if case .loading = promoState {
                    ProgressView().tint(.white)
                } else {
                    Text(loc("promo.button", data?.buttonText ?? "Apply"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(hex: data?.accentColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
            .cornerRadius(8)
            .disabled(promoState == .loading)
        }

        // Status messages
        switch promoState {
        case .success:
            Text(data?.successText ?? "Code applied!")
                .font(.caption)
                .foregroundColor(Color(hex: "#22C55E"))
        case .error:
            Text(data?.errorText ?? "Invalid code")
                .font(.caption)
                .foregroundColor(.red)
        default:
            EmptyView()
        }
    }

    // MARK: - SPEC-089d: Toggle section (AC-038)

    @ViewBuilder
    private func toggleSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let key = data?.label ?? "toggle"
        let isOn = Binding<Bool>(
            get: { toggleStates[key] ?? data?.defaultValue ?? false },
            set: { toggleStates[key] = $0 }
        )

        HStack(spacing: 12) {
            if let iconName = data?.icon {
                Image(systemName: iconName)
                    .foregroundColor(Color(hex: data?.accentColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let label = data?.label {
                    Text(loc("toggle.label", label))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Color(hex: data?.labelColorVal ?? "#FFFFFF"))
                }
                if let desc = data?.description {
                    Text(loc("toggle.description", desc))
                        .font(.caption)
                        .foregroundColor(Color(hex: data?.descriptionColor ?? "#9CA3AF"))
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color(hex: data?.onColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
        }
    }

    // MARK: - SPEC-089d: Reviews carousel section (AC-039)

    @ViewBuilder
    private func reviewsCarouselSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let reviews = data?.reviews, !reviews.isEmpty {
            ReviewsCarouselView(
                reviews: reviews,
                autoScroll: data?.autoScroll ?? true,
                autoScrollIntervalMs: data?.autoScrollIntervalMs ?? 4000,
                showRatingStars: data?.showRatingStars ?? true,
                starColor: data?.starColor ?? "#FBBF24",
                textStyle: style?.elements?["text"]?.textStyle,
                authorStyle: style?.elements?["author"]?.textStyle,
                cardStyle: style?.elements?["card"],
                loc: loc
            )
        }
    }

    // MARK: - Plans

    // SPEC-084: Grid/carousel/stack plan layouts
    private func plansSection(plans: [PaywallPlan], style: SectionStyleConfig? = nil) -> some View {
        // Gap 10: Read plan_display_style from section data first, then layout, then type
        let sectionData = config.sections.first(where: { $0.type == "plans" })?.data
        let displayStyle = sectionData?.planDisplayStyle ?? config.layout?.plan_display_style ?? config.layout?.type ?? "vertical_stack"
        // Gap 11: Build card styling from section data
        let cardStyle = PlanCardStyle(from: sectionData)
        let cardGap = cardStyle.cardGap ?? 12

        let hasCTASection = config.sections.contains(where: { $0.type == "cta" })
        return VStack(spacing: cardGap) {
            planLayoutView(plans: plans, displayStyle: displayStyle, style: style, cardStyle: cardStyle)

            // Only show inline restore when no CTA section handles it
            if !hasCTASection {
                Button(loc("restore.text", "Restore Purchases")) {
                    onRestore()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    /// Type-erased plan layout supporting 12 display styles (Gap 10).
    private func planLayoutView(plans: [PaywallPlan], displayStyle: String, style: SectionStyleConfig?, cardStyle: PlanCardStyle) -> AnyView {
        switch displayStyle {

        // Grid: side-by-side plans, strictly equal widths, no overflow.
        //
        // We measure the available width with GeometryReader and then apply
        // an EXPLICIT `.frame(width: cardWidth)` to each card. Explicit frames
        // are the ONLY layout primitive SwiftUI treats as a hard constraint —
        // neither `.frame(maxWidth: .infinity)` nor a custom Layout's `place`
        // proposal are sufficient, because both can be overridden by a child's
        // intrinsic content size.
        //
        // Height is measured via PreferenceKey from the tallest child and
        // applied back to the GeometryReader's outer frame (GeometryReader
        // itself has no intrinsic height).
        //
        // We also skip `.planSelection(...)` in grid mode because its
        // `scaleEffect(1.03)` creates a compositing layer that visually
        // extends ~1.5% on each side beyond the cell's layout bounds.
        // Selection emphasis comes from border width + selected_bg_color +
        // selected_text_color — more than enough for a 2-column grid.
        case "grid":
            let gap = cardStyle.cardGap ?? 10
            return AnyView(
                GridPlansView(
                    plans: plans,
                    gap: gap,
                    selectedPlanId: selectedPlanId,
                    selectPlan: { self.selectPlan($0) },
                    loc: loc,
                    sectionStyle: style,
                    cardStyle: cardStyle,
                    planSelectionAnimation: config.animation?.plan_selection_animation
                )
            )

        // Carousel / horizontal_scroll: side-by-side plans.
        //
        // If all plans fit within the available width at their natural
        // `card_width` (or 200pt default), we render them as an equal-width
        // grid filling the full available width — this is what users want
        // for 2-plan layouts (Monthly / Annual). If they don't fit, we fall
        // back to a horizontally-scrollable carousel with the natural widths
        // so users can swipe.
        //
        // Previous behavior hardcoded `.frame(width: 200)` on every card
        // inside a horizontal ScrollView, which made the second card render
        // off-screen on iPhone for any 2-plan layout (2×200 + gap > ~360pt
        // available). That was the bug in customer-reported screenshots.
        case "carousel", "horizontal_scroll":
            let gap = cardStyle.cardGap ?? 12
            return AnyView(
                HorizontalPlansView(
                    plans: plans,
                    gap: gap,
                    selectedPlanId: selectedPlanId,
                    selectPlan: { self.selectPlan($0) },
                    loc: loc,
                    sectionStyle: style,
                    cardStyle: cardStyle,
                    planSelectionAnimation: config.animation?.plan_selection_animation
                )
            )

        // Radio list: compact VStack with radio circles (no full card BG)
        case "radio_list":
            return AnyView(VStack(spacing: cardStyle.cardGap ?? 8) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    Button { selectPlan(plan.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedPlanId == plan.id ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc("plan.\(index).name", plan.displayName))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                HStack(spacing: 4) {
                                    Text(plan.displayPrice).font(.caption.bold()).foregroundColor(.primary)
                                    if let period = plan.period {
                                        Text("/ \(period)").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if let badge = plan.badge {
                                Text(badge)
                                    .font(.caption2.bold())
                                    .foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFFFFF"))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                }
            })

        // Pill selector: horizontal pill-shaped buttons
        case "pill_selector":
            return AnyView(ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardStyle.cardGap ?? 8) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        Button { selectPlan(plan.id) } label: {
                            VStack(spacing: 2) {
                                Text(loc("plan.\(index).name", plan.displayName))
                                    .font(.subheadline.weight(.semibold))
                                Text(plan.displayPrice)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .foregroundColor(selectedPlanId == plan.id ? .white : .primary)
                            .background(
                                Capsule().fill(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : Color.clear)
                            )
                        }
                        .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            })

        // Segmented toggle: iOS native Picker segmented style
        case "segmented_toggle", "segmented":
            return AnyView(VStack(spacing: 8) {
                Picker("Plan", selection: Binding(
                    get: { selectedPlanId ?? plans.first?.id ?? "" },
                    set: { selectPlan($0) }
                )) {
                    ForEach(plans) { plan in
                        Text(plan.displayName).tag(plan.id)
                    }
                }
                .pickerStyle(.segmented)

                // Show price for selected plan
                if let selected = plans.first(where: { $0.id == selectedPlanId }) {
                    HStack(spacing: 4) {
                        Text(selected.displayPrice).font(.title3.bold())
                        if let period = selected.period {
                            Text("/ \(period)").font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
            })

        // Mini cards: compact 2-column grid with minimal info
        case "mini_cards":
            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            return AnyView(LazyVGrid(columns: columns, spacing: cardStyle.cardGap ?? 8) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    Button { selectPlan(plan.id) } label: {
                        VStack(spacing: 4) {
                            Text(loc("plan.\(index).name", plan.displayName))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                            Text(plan.displayPrice)
                                .font(.subheadline.bold())
                                .foregroundColor(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : .primary)
                            if let period = plan.period {
                                Text("/ \(period)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 10)
                            .fill(selectedPlanId == plan.id ? (cardStyle.selectedBgColor.flatMap { Color(hex: $0) } ?? Color.clear) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 10)
                            .stroke(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : Color.clear, lineWidth: 2))
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                }
            })

        // Explicit vertical stack cases
        case "vertical_stack", "stack":
            return planLayoutFallbackStack(plans: plans, style: style, cardStyle: cardStyle)

        // Timeline reveal: dot + line + horizontal card
        case "timeline_reveal", "timeline":
            return AnyView(VStack(spacing: 0) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    HStack(alignment: .top, spacing: 12) {
                        // Timeline dot + line (always show line as decorative element)
                        VStack(spacing: 0) {
                            Circle()
                                .fill(Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                                .frame(width: 12, height: 12)
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(width: 12)
                        .padding(.top, 6)

                        // Plan card — horizontal layout
                        Button { selectPlan(plan.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                // Trial label
                                if let trial = plan.trialLabel {
                                    Text(trial.uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                                        .tracking(0.5)
                                }
                                // Name + Price horizontal
                                HStack {
                                    Text(plan.displayName)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(plan.displayPrice)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                }
                                // Badge
                                if let badge = plan.badge, !badge.isEmpty {
                                    Text(badge)
                                        .font(.caption2.bold())
                                        .foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFFFFF"))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                                        .clipShape(Capsule())
                                }
                                // Description
                                if let desc = plan.description, !desc.isEmpty {
                                    Text(desc).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 12)
                                    .fill(selectedPlanId == plan.id ? (cardStyle.selectedBgColor.flatMap { Color(hex: $0) } ?? Color.clear) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 12)
                                    .stroke(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : Color.gray.opacity(0.2), lineWidth: selectedPlanId == plan.id ? 2 : 1)
                            )
                        }
                        .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    }
                    .padding(.bottom, index < plans.count - 1 ? 8 : 0)
                }
            })

        // Comparison table: feature rows with check/cross per plan
        case "comparison_table", "comparison_cards", "feature_matrix", "pricing_table":
            let sectionData = config.sections.first(where: { $0.type == "plans" })?.data
            let compFeatures = sectionData?.features ?? []
            return AnyView(VStack(spacing: 0) {
                // Header row: plan names
                HStack(spacing: 0) {
                    Text("").frame(maxWidth: .infinity)
                    ForEach(plans, id: \.id) { plan in
                        Button { selectPlan(plan.id) } label: {
                            Text(plan.displayName)
                                .font(.caption.bold())
                                .foregroundColor(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    }
                }
                .background(Color.gray.opacity(0.05))
                // Price row
                HStack(spacing: 0) {
                    Text("Price").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    ForEach(plans, id: \.id) { plan in
                        Text(plan.displayPrice).font(.caption.bold()).foregroundColor(.primary).frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                Divider()
                // Feature rows
                ForEach(compFeatures, id: \.self) { feature in
                    HStack(spacing: 0) {
                        Text(feature).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                        ForEach(plans, id: \.id) { _ in
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundColor(Color(hex: "#22C55E")).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                // Badge row
                HStack(spacing: 0) {
                    Text("").frame(maxWidth: .infinity)
                    ForEach(plans, id: \.id) { plan in
                        if let badge = plan.badge, !badge.isEmpty {
                            Text(badge).font(.caption2.bold()).foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFF"))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))).clipShape(Capsule())
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("").frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
            )

        // Single hero: one featured plan, large card
        case "single_hero":
            let hero = plans.first(where: { $0.isDefault == true }) ?? plans.first
            guard let plan = hero else { return planLayoutFallbackStack(plans: plans, style: style, cardStyle: cardStyle) }
            let idx = plans.firstIndex(where: { $0.id == plan.id }) ?? 0
            let labelStyle = style?.elements?["label"]?.textStyle ?? style?.elements?["plan_name"]?.textStyle
            let priceStyle = style?.elements?["price"]?.textStyle
            return AnyView(
                Button { selectPlan(plan.id) } label: {
                    VStack(spacing: 12) {
                        if let trial = plan.trialLabel {
                            Text(trial.uppercased())
                                .font(.caption.bold()).foregroundColor(Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                                .tracking(0.5)
                        }
                        Text(plan.displayName)
                            .font(labelStyle?.font_size.map { .system(size: CGFloat($0), weight: .bold) } ?? .title2.bold())
                            .foregroundColor(labelStyle?.color.map { Color(hex: $0) } ?? .primary)
                        Text(plan.displayPrice)
                            .font(priceStyle?.font_size.map { .system(size: CGFloat($0), weight: .bold) } ?? .title.bold())
                            .foregroundColor(priceStyle?.color.map { Color(hex: $0) } ?? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                        if let badge = plan.badge, !badge.isEmpty {
                            Text(badge).font(.caption.bold()).foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFF"))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))).clipShape(Capsule())
                        }
                        if let desc = plan.description, !desc.isEmpty {
                            Text(desc).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                        if let features = plan.features, !features.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(features, id: \.self) { f in
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                        Text(f).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 16)
                        .fill(Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 16)
                        .stroke(Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")), lineWidth: 2))
                }
                .contentShape(Rectangle())
                    .buttonStyle(.plain)
                .padding(.horizontal)
            )

        // Product as CTA: each plan IS a buy button
        case "product_as_cta":
            return AnyView(VStack(spacing: cardStyle.cardGap ?? 10) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    Button { selectPlan(plan.id); handleCTATap() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.displayName).font(.subheadline.weight(.semibold)).foregroundColor(.white)
                                if let trial = plan.trialLabel {
                                    Text(trial).font(.caption).foregroundColor(.white.opacity(0.8))
                                }
                            }
                            Spacer()
                            Text(plan.displayPrice).font(.headline.bold()).foregroundColor(.white)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 14)
                            .fill(Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))))
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                }
            })

        // Carousel cards: horizontally swipeable rich cards
        case "carousel_cards":
            return AnyView(
                TabView {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        Button { selectPlan(plan.id) } label: {
                            VStack(spacing: 8) {
                                if let trial = plan.trialLabel {
                                    Text(trial.uppercased()).font(.caption2.bold())
                                        .foregroundColor(Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                                }
                                Text(plan.displayName).font(.headline).foregroundColor(.primary)
                                Text(plan.displayPrice).font(.title3.bold()).foregroundColor(.primary)
                                if let badge = plan.badge, !badge.isEmpty {
                                    Text(badge).font(.caption2.bold()).foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFF"))
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))).clipShape(Capsule())
                                }
                                if let desc = plan.description, !desc.isEmpty {
                                    Text(desc).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 16)
                                .fill(selectedPlanId == plan.id ? (cardStyle.selectedBgColor.flatMap { Color(hex: $0) } ?? Color.clear) : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 16)
                                .stroke(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : Color.gray.opacity(0.2), lineWidth: selectedPlanId == plan.id ? 2 : 1))
                            .padding(.horizontal, 8)
                        }
                        .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: plans.count > 1 ? .always : .never))
                .frame(height: 200)
            )

        // Accordion: expandable/collapsible rows
        case "accordion":
            return AnyView(VStack(spacing: cardStyle.cardGap ?? 8) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    let isExpanded = selectedPlanId == plan.id
                    Button { selectPlan(plan.id) } label: {
                        VStack(spacing: 0) {
                            // Header row (always visible)
                            HStack {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundColor(Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                                    .frame(width: 16)
                                Text(plan.displayName).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                                Spacer()
                                Text(plan.displayPrice).font(.subheadline.bold()).foregroundColor(.primary)
                                if let badge = plan.badge, !badge.isEmpty {
                                    Text(badge).font(.system(size: 9).bold()).foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFF"))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))).clipShape(Capsule())
                                }
                            }
                            .padding(12)

                            // Expanded content
                            if isExpanded {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let trial = plan.trialLabel {
                                        HStack(spacing: 4) {
                                            Image(systemName: "gift").font(.caption).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                            Text(trial).font(.caption).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                        }
                                    }
                                    if let desc = plan.description, !desc.isEmpty {
                                        Text(desc).font(.caption).foregroundColor(.secondary)
                                    }
                                    if let savings = plan.savings_text, !savings.isEmpty {
                                        Text(savings).font(.caption.bold()).foregroundColor(Color(hex: "#22C55E"))
                                    }
                                    if let features = plan.features, !features.isEmpty {
                                        ForEach(features, id: \.self) { f in
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                                Text(f).font(.caption).foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 12).padding(.bottom, 12)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 10)
                            .fill(isExpanded ? (cardStyle.selectedBgColor.flatMap { Color(hex: $0) } ?? Color.clear) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 10)
                            .stroke(isExpanded ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : Color.gray.opacity(0.2), lineWidth: isExpanded ? 2 : 1))
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
                }
            })

        // tier_ladder, interactive_slider — fallback
        case "tier_ladder", "interactive_slider":
            return planLayoutFallbackStack(plans: plans, style: style, cardStyle: cardStyle)

        // Default: unknown styles fall back to vertical_stack
        default:
            return planLayoutFallbackStack(plans: plans, style: style, cardStyle: cardStyle)
        }
    }

    /// Fallback vertical stack used by default and unsupported advanced styles.
    private func planLayoutFallbackStack(plans: [PaywallPlan], style: SectionStyleConfig?, cardStyle: PlanCardStyle) -> AnyView {
        return AnyView(ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
            PlanCard(plan: plan, isSelected: selectedPlanId == plan.id,
                     onSelect: { selectPlan(plan.id) }, planIndex: index,
                     loc: loc, sectionStyle: style, cardStyle: cardStyle)
            .planSelection(config.animation?.plan_selection_animation, isSelected: selectedPlanId == plan.id)
        })
    }

    /// Helper to select a plan and trigger haptic.
    private func selectPlan(_ planId: String) {
        selectedPlanId = planId
        HapticEngine.triggerIfEnabled(config.haptic?.triggers?.on_plan_select, config: config.haptic)
    }

    // MARK: - CTA handler

    private func handleCTATap() {
        guard let planId = selectedPlanId else { return }
        // Plans can be in section.data.plans OR top-level config.plans
        let sectionPlans = config.sections.first(where: { $0.type == "plans" })?.data?.plans ?? []
        let allPlans = sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans
        guard let plan = allPlans.first(where: { $0.id == planId }) else { return }
        // SPEC-085: Haptic on CTA tap
        HapticEngine.triggerIfEnabled(config.haptic?.triggers?.on_button_tap, config: config.haptic)
        // SPEC-085: Trigger particle effect on purchase
        if let effect = config.particle_effect, effect.trigger == "on_purchase" {
            showConfetti = true
        }
        isPurchasing = true
        // AC-038: Include toggle states in purchase metadata
        var metadata: [String: Any] = [:]
        if !toggleStates.isEmpty {
            metadata["toggle_states"] = toggleStates
        }
        if !promoCode.isEmpty && promoState == .success {
            metadata["promo_code"] = promoCode
        }
        onPlanSelected(plan, metadata)
    }
}

// MARK: - Shared plan row preference + helpers

/// Preference key used by `GridPlansView` and `HorizontalPlansView` to collect
/// the tallest plan card's height so the GeometryReader container can adopt
/// an intrinsic height (GeometryReader itself has no intrinsic size).
private struct PlanRowHeightPref: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Side-by-side plan grid that GUARANTEES equal card widths and zero overflow.
///
/// Uses GeometryReader to measure the parent's offered width, then applies an
/// EXPLICIT `.frame(width: cardWidth)` to each card. Explicit frames are the
/// only layout primitive SwiftUI treats as a hard constraint on width.
///
/// The GeometryReader's outer frame height is sized from a PreferenceKey that
/// reports the tallest rendered child.
struct GridPlansView: View {
    let plans: [PaywallPlan]
    let gap: CGFloat
    let selectedPlanId: String?
    let selectPlan: (String) -> Void
    let loc: (String, String) -> String
    let sectionStyle: SectionStyleConfig?
    let cardStyle: PlanCardStyle
    var planSelectionAnimation: String? = nil

    @State private var rowHeight: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    /// Below this width a card can't fit price + period + badge without
    /// wrapping or truncating, so we fall back to a vertical stack instead
    /// of rendering unreadable mini cards. Matches HorizontalPlansView.
    private var minCardWidth: CGFloat { 140 }

    var body: some View {
        let count = CGFloat(max(plans.count, 1))
        let totalGap = gap * max(count - 1, 0)
        let cardWidth = max((availableWidth - totalGap) / count, 0)
        let useHorizontal = availableWidth == 0 || cardWidth >= minCardWidth

        Group {
            if useHorizontal {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        PlanCard(
                            plan: plan,
                            isSelected: selectedPlanId == plan.id,
                            onSelect: { selectPlan(plan.id) },
                            planIndex: index,
                            loc: loc,
                            sectionStyle: sectionStyle,
                            cardStyle: cardStyle
                        )
                        // Strip "scale" because it visually extends ~1.5% beyond
                        // the cell bounds. glow/border_highlight are cell-safe.
                        .planSelection(
                            safeGridAnimation(planSelectionAnimation),
                            isSelected: selectedPlanId == plan.id
                        )
                        .frame(width: cardWidth, alignment: .topLeading)
                        .background(
                            GeometryReader { innerGeo in
                                Color.clear
                                    .preference(key: PlanRowHeightPref.self, value: innerGeo.size.height)
                            }
                        )
                    }
                }
                .frame(height: rowHeight > 0 ? rowHeight : 180)
                .onPreferenceChange(PlanRowHeightPref.self) { height in
                    if abs(height - rowHeight) > 0.5 {
                        rowHeight = height
                    }
                }
            } else {
                // Screen too narrow for side-by-side — stack vertically so
                // every plan is fully visible instead of squished.
                VStack(spacing: gap) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        PlanCard(
                            plan: plan,
                            isSelected: selectedPlanId == plan.id,
                            onSelect: { selectPlan(plan.id) },
                            planIndex: index,
                            loc: loc,
                            sectionStyle: sectionStyle,
                            cardStyle: cardStyle
                        )
                        .planSelection(planSelectionAnimation, isSelected: selectedPlanId == plan.id)
                    }
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { availableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { availableWidth = $0 }
            }
        )
    }
}

/// Strips the `scale` animation in tightly-packed grid layouts because its
/// `scaleEffect(1.03)` creates a compositing layer that visually extends
/// ~1.5% beyond the cell's layout bounds. `glow` and `border_highlight`
/// are cell-safe and preserved.
private func safeGridAnimation(_ animation: String?) -> String? {
    animation == "scale" ? nil : animation
}

// MARK: - HorizontalPlansView

/// Side-by-side plan layout used by the `horizontal_scroll` and `carousel`
/// display styles.
///
/// Dynamically picks between two modes based on how much each card would
/// have to shrink to fit the available width:
///
///   1. **Side-by-side** (compressed width ≥ minCardWidth): equal-width
///      cards filling the full available width. Used when the compressed
///      width is still readable (≥ 140pt). Works for 2–3 plan Monthly/
///      Annual layouts on any device, and for any number of plans on iPad.
///
///   2. **Stacked fallback** (compressed width < minCardWidth): plans stack
///      vertically so every option is fully visible. Replaces the previous
///      horizontal-scroll behavior which hid plans behind a swipe gesture
///      on small screens (iPhone mini / SE) — users never discovered them.
struct HorizontalPlansView: View {
    let plans: [PaywallPlan]
    let gap: CGFloat
    let selectedPlanId: String?
    let selectPlan: (String) -> Void
    let loc: (String, String) -> String
    let sectionStyle: SectionStyleConfig?
    let cardStyle: PlanCardStyle
    let planSelectionAnimation: String?

    @State private var rowHeight: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    /// Minimum readable card width. Below this we fall back to a vertical
    /// stack instead of a horizontal scroll — hidden content is a worse
    /// failure mode than losing the side-by-side affordance.
    private var minCardWidth: CGFloat { 140 }

    var body: some View {
        let count = CGFloat(max(plans.count, 1))
        let totalGap = gap * max(count - 1, 0)
        let compressedWidth = max((availableWidth - totalGap) / count, 0)
        let useHorizontal = availableWidth == 0 || compressedWidth >= minCardWidth

        Group {
            if useHorizontal {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        PlanCard(
                            plan: plan,
                            isSelected: selectedPlanId == plan.id,
                            onSelect: { selectPlan(plan.id) },
                            planIndex: index,
                            loc: loc,
                            sectionStyle: sectionStyle,
                            cardStyle: cardStyle
                        )
                        .planSelection(
                            safeGridAnimation(planSelectionAnimation),
                            isSelected: selectedPlanId == plan.id
                        )
                        .frame(width: compressedWidth, alignment: .topLeading)
                        .background(
                            GeometryReader { innerGeo in
                                Color.clear
                                    .preference(key: PlanRowHeightPref.self, value: innerGeo.size.height)
                            }
                        )
                    }
                }
                .frame(height: rowHeight > 0 ? rowHeight : 180)
                .onPreferenceChange(PlanRowHeightPref.self) { height in
                    if abs(height - rowHeight) > 0.5 {
                        rowHeight = height
                    }
                }
            } else {
                VStack(spacing: gap) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        PlanCard(
                            plan: plan,
                            isSelected: selectedPlanId == plan.id,
                            onSelect: { selectPlan(plan.id) },
                            planIndex: index,
                            loc: loc,
                            sectionStyle: sectionStyle,
                            cardStyle: cardStyle
                        )
                        .planSelection(planSelectionAnimation, isSelected: selectedPlanId == plan.id)
                    }
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { availableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { availableWidth = $0 }
            }
        )
    }
}

// MARK: - Scroll offset preference key for collapse-on-scroll

private struct PaywallScrollOffsetPrefKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
