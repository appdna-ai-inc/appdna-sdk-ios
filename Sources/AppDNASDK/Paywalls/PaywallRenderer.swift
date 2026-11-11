import SwiftUI

/// Schema-driven SwiftUI view that renders a PaywallConfig.
struct PaywallRenderer: View {
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    let config: PaywallConfig
    let onPlanSelected: (PaywallPlan, _ metadata: [String: Any]) -> Void
    let onRestore: () -> Void
    let onDismiss: (DismissReason) -> Void
    /// Callback for promo code validation. Returns true if code is valid, false otherwise.
    var onPromoCodeSubmit: ((String, @escaping (Bool) -> Void) -> Void)? = nil

    /*
     * WHAT THE USER DID, reported separately from what it achieved.
     *
     * `AppDNAPaywallDelegate.onPaywallAction` was declared on iOS and called from nowhere, while
     * Android fired `CTA_TAPPED` — so a host implementing it heard the tap on one platform and
     * silence on the other, from the same published paywall.
     *
     * Optional with a default so every existing construction of this view keeps compiling; the
     * manager supplies it.
     */
    var onAction: ((PaywallAction) -> Void)? = nil

    @State private var selectedPlanId: String?
    /// The pinned group's measured height, the viewport's, and the latched verdict.
    @State private var pinnedZoneHeight: CGFloat = 0
    @State private var paywallViewportHeight: CGFloat = 0
    @State private var bottomZoneOverflowed = false
    @State private var showDismiss = false
    /// The Back button has its OWN delay, so it cannot ride on `showDismiss`.
    @State private var showBack = false
    @State private var isPurchasing = false
    @State private var isDismissing = false
    @State private var dragOffset: CGFloat = 0
    // Particle effect state
    @State private var showConfetti = false
    // Post-purchase overlay state
    @State private var showSuccessOverlay = false
    @State private var successMessage = ""
    @State private var showErrorBanner = false
    @State private var errorMessage = ""
    @State private var errorRetryText = ""
    @State private var errorAllowRetry = false
    /// The post-purchase observer tokens, owned for exactly the life of this
    /// view and removed in the holder's `deinit` (not `.onDisappear`, which also fires under a host's
    /// full-screen cover and so lost a purchase-ended post, leaving the CTA spinning).
    @StateObject private var purchaseObservers = PaywallPurchaseObservers()

    // Localization helper: Template variable interpolation
    private func loc(_ key: String, _ fallback: String) -> String {
        let localized = LocalizationEngine.resolve(key: key, localizations: config.localizations, defaultLocale: config.default_locale, fallback: fallback)
        return TemplateEngine.shared.interpolate(localized, context: templateContext)
    }

    // Cached template context (built once per render cycle)
    private var templateContext: TemplateContext {
        TemplateEngine.shared.buildContext(surface: .other)
    }

    // Extract sticky_footer section if present
    private var stickyFooterSection: PaywallSection? {
        config.sections.first(where: { $0.type == "sticky_footer" })
    }

    // Extract CTA section if present (for bottom pinning outside scroll)
    private var ctaSection: PaywallSection? {
        config.sections.first(where: { $0.type == "cta" })
    }

    /// The plans this paywall offers, in the order they draw — the ONE resolution every site shares.
    ///
    /// There used to be four copies of these three lines, drifting apart: two applied the authored rank and
    /// two did not, and the one that drew was among those that did not.
    private var resolvedPlans: [PaywallPlan] {
        let sectionPlans = config.sections.first(where: { $0.type == "plans" })?.data?.plans ?? []
        // The authored rank, which both platforms decoded and neither read.
        return PaywallPlanOrder.sorted(sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans)
    }

    /// The currently selected plan (matches `onAppear`'s resolution: section plans, then top-level).
    private var selectedPlan: PaywallPlan? {
        resolvedPlans.first(where: { $0.id == selectedPlanId })
    }

    /// The selected plan's per-plan CTA text, when non-empty. Wired into the pinned CTA + sticky
    /// footer so a plan can override the section/top-level CTA label (e.g. "Start 7-day trial").
    /// Basic wire only — a full selected-plan template-variable namespace ({{plan.*}}) is deferred.
    private var selectedPlanCtaText: String? {
        guard let t = selectedPlan?.cta_text, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return t
    }

    /**
     The CTA's label, resolved once for all three places a CTA is drawn.

     🔴 WHY THE BUTTON NAMES THE PLAN. A tap on a plan row that drifts ~14pt is claimed by the
     `ScrollView` the rows live in, so the selection does not change and the CTA buys the plan chosen
     BEFORE it — measured, and iOS's own convention, so the tolerance is deliberately
     left alone. What made that a wrong purchase rather than a visible mistake is that nothing on
     screen named what was about to be bought. A button reading "Subscribe — Annual" shows a stale
     selection before the money moves instead of on the receipt after.

     An author can already say it exactly, per plan, with `plans[].cta_text`, and that still wins.
     This is the default for the paywalls where nobody did: measured on dev when this was written,
     6 of 129 plans carried the field and 27 of 30 ACTIVE multi-plan paywalls had none.

     Deliberately conservative, because it changes copy on live paywalls:
       - a single-plan paywall is never touched — there is no choice to get wrong;
       - an authored per-plan label wins outright, untouched;
       - a CTA whose own text already contains the plan's name is left alone, so "Start Annual" does
         not become "Start Annual — Annual";
       - the plan's `displayName` is `label ?? name`, which is the short word an author typed
         ("Annual"), not a price string.

     It is one function rather than three because three copies HAVE drifted apart: the section arm
     resolved the per-plan label, the root arm did not, and the same authored field worked or did
     nothing depending on the layout.
     */
    private func ctaLabel(_ authored: String?) -> String? {
        selectedPlanCtaText ?? authored
    }

    /**
     The selected plan's name to append to the CTA, or nil to leave the CTA alone.

     🔴 IT IS A SUFFIX RATHER THAN PART OF THE LABEL. The label is the FALLBACK to
     `loc("cta.text", …)`, so a paywall with a translation got the translation and lost the appended
     name — the mitigation disappearing on exactly the paywalls hardest to check, since a device walk
     in the default locale would never show it. The suffix is composed AFTER localisation instead
     (`CTAButton.displayText`, and the two sites that draw their own `Text`), and the name itself
     goes through `loc("plan.<idx>.name", …)`, the key Android's plan rows already use, so both
     halves are translated.

     Three guards, the same three on every surface:
       - nil for a SINGLE-plan paywall — there is no choice to get wrong;
       - nil when the plan carries its own `cta_text`, which wins outright and says it exactly;
       - the already-contains-the-name check lives with the composition, so "Start Annual" cannot
         become "Start Annual — Annual" whichever string localisation produced.
    */
    private var planNameSuffix: String? {
        // The author can switch naming off for the whole paywall (it defaults on).
        guard config.cta?.name_plan != false else { return nil }
        guard selectedPlanCtaText == nil else { return nil }
        let plans = resolvedPlans
        guard plans.count > 1,
              let idx = plans.firstIndex(where: { $0.id == selectedPlanId }) else { return nil }
        let name = loc("plan.\(idx).name", plans[idx].displayName)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Localise `authored` as the CTA, then append the plan's name — for the two sites that draw
    /// their own `Text` instead of going through `CTAButton`.
    private func ctaDisplayText(_ authored: String?, locKey: String = "cta.text", fallback: String) -> String {
        CTAPlanName.compose(base: loc(locKey, ctaLabel(authored) ?? fallback), plan: planNameSuffix, format: planNameFormat)
    }

    /// Where the CTA text and the plan's name go, localised so a locale can reorder them.
    private var planNameFormat: String {
        loc("cta.plan_format", config.cta?.plan_format ?? CTAPlanName.defaultFormat)
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

    /**
     Sections an author pinned to the bottom zone.

     > Owner, 2026-10-16: *"don't you think this whole section should be tied to low zone not to
     > top to look better in therms of UI/UX?"* — about the plan tiles.

     Before this only the `cta` section (and a `legal` placed after it) could be pinned, so the
     plans scrolled away while the button that buys them stayed. A section authored
     `zone: "bottom"` now joins the pinned group, in authored order, ABOVE the CTA — choose, then
     confirm, which is the order a reader expects.

     The CTA and `sticky_footer` are excluded because they are pinned by their own rules already;
     adding them here would render them twice.
     */
    private var authoredBottomZoneSections: [PaywallSection] {
        config.sections.filter {
            $0.zone == "bottom" && $0.type != "cta" && $0.type != "sticky_footer"
                && !pinnedFooterLegalIds.contains($0.id ?? "")
        }
    }

    /**
     The pinned group, capped against the viewport.

     Pinning the plans and the CTA is what the zone is for; pinning the header, the features and a
     table as well turns the body into a sliver, which is the defect the zone fixed, arriving from
     the other direction. Past `PaywallBottomZone.maxFraction` everything except the CTA goes back to the
     body in its authored position — degrade, never clip, because a group that hides the button is
     worse than a scrolling one.

     🔴 LATCHED in `bottomZoneOverflowed`, because the decision feeds back into what it measures:
     unpinning shrinks the group below the threshold, which would re-pin it, which would exceed the
     threshold again. The first full measurement decides and the decision holds.
     */
    private var bottomZoneSections: [PaywallSection] {
        bottomZoneOverflowed ? [] : authoredBottomZoneSections
    }

    /// Record the pinned group's height and latch the verdict once it is known.
    private func recordPinnedHeight(_ geo: GeometryProxy) {
        // The reader is a zero-height probe at the TOP of the group, so the group's height is the
        // distance from it to the bottom of the window.
        let frame = geo.frame(in: .global)
        let height = max(0, paywallViewportHeight - frame.minY)
        pinnedZoneHeight = height
        if !bottomZoneOverflowed,
           PaywallBottomZone.overflows(pinned: Double(height), viewport: Double(paywallViewportHeight)) {
            bottomZoneOverflowed = true
        }
    }

    /// IDs of the sections pinned by `zone: "bottom"`, to exclude them from the scroll body.
    private var bottomZoneIds: Set<String> {
        Set(bottomZoneSections.map { $0.id ?? "" })
    }

    /// IDs of legal sections that have been moved to the pinned footer —
    /// used to exclude them from the scrollable content so they don't render twice.
    private var pinnedFooterLegalIds: Set<String> {
        Set(pinnedFooterLegalSections.map { $0.id ?? "" })
    }

    /// Sections sorted by `style.position.vertical_align` — top bucket first, then middle
    /// (unspecified / center), then bottom. Within each bucket, original array order is preserved.
    /// This makes the console's "Position → Vertical Align" actually move sections within the layout.
    /// The pitch (indexes into `orderedSections`) and whether the paywall has two
    /// panes' worth of content. Pinned exactly as the scroll below pins.
    private var paywallSplit: (pitch: [Int], splits: Bool) {
        let sections = orderedSections
        let pinned = sections.map { section -> Bool in
            section.type == "cta" || section.type == "sticky_footer"
                || (section.type == "legal" && pinnedFooterLegalIds.contains(section.id ?? ""))
                || (bottomZoneIds.contains(section.id ?? "") && section.zone == "bottom")
        }
        return SurfaceLayout.paywallSplit(types: sections.map(\.type), pinned: pinned)
    }

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

    // Toggle state for toggle sections
    @State private var toggleStates: [String: Bool] = [:]
    // Scroll offset for collapse-on-scroll sections
    @State private var scrollOffset: CGFloat = 0
    // Promo input state
    @State private var promoCode: String = ""
    @State private var promoState: PromoState = .idle

    /// The paywall's own accent: its CTA's colour when authored, else the brand accent.
    private var paywallAccentHex: String { config.cta?.authoredBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1") }

    var body: some View {
        // The page's background travels down the hierarchy, so every default text colour is
        // chosen against the surface it is drawn on. Through the ENVIRONMENT rather than a
        // parameter: `PlanCard` alone has five call sites, and five places to forget one is how
        // the screens surface once lost its styling.
        content
            .environment(\.paywallBackgroundHex, pageBackgroundHex)
            .environment(\.paywallAccentHex, config.cta?.authoredBgColor)
            // The viewport the pinned-zone cap is measured against.
            .background(GeometryReader { geo in
                Color.clear.onAppear { paywallViewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { paywallViewportHeight = $0 }
            })
    }

    private var content: some View {
        ZStack(alignment: .topTrailing) {
            // Scrollable content with pinned bottom CTA
            // On a wide window the pitch (everything above the plans) takes the leading
            // pane; the plans and the pinned CTA keep the trailing one, which is the SAME view in both
            // modes, so the scroll position and the pinned zone survive a fold or an unfold.
            SurfaceSplitStack(canSplit: paywallSplit.splits) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(paywallSplit.pitch, id: \.self) { idx in
                            sectionView(for: orderedSections[idx])
                        }
                    }
                    .padding(config.layout?.padding ?? 20)
                }
            } main: { splits in
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
                    ForEach(Array(orderedSections.enumerated()), id: \.offset) { idx, section in
                        // CTA and sticky_footer are pinned via safeAreaInset.
                        // Legal sections that come AFTER cta in the original
                        // section array are pinned INSIDE the bottom inset
                        // below the CTA, so skip them here too.
                        let isPinnedLegal = section.type == "legal" && pinnedFooterLegalIds.contains(section.id ?? "")
                        // A section pinned to the bottom zone renders there, not here.
                        let isBottomZone = bottomZoneIds.contains(section.id ?? "") && section.zone == "bottom"
                        // In a split, the pitch is drawn in the leading pane instead.
                        let inLeadPane = splits && paywallSplit.pitch.contains(idx)
                        if section.type != "cta" && section.type != "sticky_footer" && !isPinnedLegal && !isBottomZone && !inLeadPane {
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
                    // Measure this group and latch the verdict. The reader sits INSIDE the
                    // group so it measures what is pinned, including the CTA, which is what the
                    // user actually loses body height to.
                    Color.clear.frame(height: 0).background(GeometryReader { geo in
                        Color.clear.onAppear { recordPinnedHeight(geo) }
                            .onChange(of: geo.frame(in: .global).minY) { _ in recordPinnedHeight(geo) }
                    })
                    // The authored bottom-zone sections, above the CTA, in authored order.
                    ForEach(Array(bottomZoneSections.enumerated()), id: \.offset) { _, pinned in
                        sectionView(for: pinned)
                            .padding(.horizontal, config.layout?.padding ?? 20)
                            .padding(.bottom, config.layout?.spacing ?? 16)
                    }
                    // CTA section from layout — pinned to bottom, outside scroll
                    if let ctaSec = ctaSection {
                        let topLevelText = config.cta?.text
                        let sectionText = ctaSec.data?.ctaText ?? ctaSec.data?.text
                        // One resolution for all three CTA sites: the plan's own label,
                        // else the authored text, else the authored text naming the plan.
                        let ctaText = ctaLabel(topLevelText ?? sectionText)
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
                            // And its container half, so both restore renderers agree.
                            elementStyle: ctaSec.style?.elements?["restore_text"]?.container,
                            backgroundHex: pageBackgroundHex,
                            // Restore's own fill + radius.
                            bgColor: ctaSec.data?.restoreBgColor,
                            cornerRadius: ctaSec.data?.restoreCornerRadius.map { CGFloat($0) },
                            // The restore link's action is authorable too; unset restores.
                            onRestore: { performButtonAction(ctaSec.data?.restoreAction, url: nil, default: "restore") }
                        )
                        // The CTA↔Restore gap on the path where the restore link is
                        // rendered OUTSIDE the CTA button. Hoisted into a typed local: inlining
                        // `ctaSec.data?.restoreGap ?? 8` here made the whole `body` exceed Swift's type-check
                        // budget ("unable to type-check this expression in reasonable time"), which is the same
                        // reason this file already type-erases its 45-case section switch with AnyView.
                        let restoreGapOuter: CGFloat = ctaSec.data?.restoreGap ?? 8
                        VStack(spacing: restoreGapOuter) {
                            if showRestore && restorePosition == "above" {
                                restoreView
                            }
                            CTAButton(
                                cta: config.cta,
                                isPurchasing: isPurchasing,
                                // The same condition the root-`cta` fallback has always
                                // carried, and the one Android has always carried. Without it this
                                // button accepted a tap it could do nothing with.
                                canPurchase: selectedPlanId != nil,
                                // The CTA's action is authorable; unset still purchases.
                                onTap: { performButtonAction(ctaSec.data?.ctaAction, url: nil, default: "purchase") },
                                loc: loc,
                                sectionStyle: ctaSec.style,
                                ctaGradient: ctaSec.data?.ctaGradient,
                                textOverride: ctaText,
                                planNameSuffix: planNameSuffix,
                                planNameFormat: planNameFormat,
                                ctaFontSize: ctaSec.data?.ctaFontSize,
                                ctaFontWeight: ctaSec.data?.ctaFontWeight,
                                restoreText: nil,          // rendered outside
                                showRestore: false,        // rendered outside
                                onRestore: nil
                            )
                            .ctaAnimation(config.animation?.cta_animation)
                            .applyContainerStyle(ctaSec.style?.container)
                            // Extra buttons sit between the CTA and the restore link.
                            if let extras = ctaSec.data?.extraButtons, !extras.isEmpty {
                                extraButtonsView(extras)
                            }
                            if showRestore && restorePosition != "above" {
                                restoreView
                            }
                        }
                        .padding(.bottom, 8)
                    } else if let cta = config.cta {
                        /*
                         * Fallback: top-level CTA button (when no CTA section exists in layout).
                         *
                         * 🔴 `selectedPlanCtaText` FIRST, because this arm used to ignore it
                         * and that made an authored label work or not depending on the layout. The
                         * SECTION arm above resolves `selectedPlanCtaText ?? topLevelText ??
                         * sectionText`; this one read `cta.text ?? "Continue"`, so a paywall whose
                         * plans carry a per-plan `cta_text` and whose layout has no `cta` SECTION
                         * drew the generic label. Android has never had the split: it synthesises a
                         * `__root_cta__` section for exactly this case, so the root CTA goes through
                         * its one resolution chain and the per-plan label wins there too.
                         *
                         * It matters for a drifting tap specifically. A tap that drifts far enough for the
                         * scroll view to claim it does not change the selection, and the CTA then
                         * buys the plan selected BEFORE it — silently, because nothing on screen
                         * names what is about to be bought. A CTA that reads "Start Annual — $34.99"
                         * makes a stale selection visible before the purchase instead of after, and
                         * this is the arm where that was impossible to author.
                         */
                        Button(action: handleCTATap) {
                            if isPurchasing {
                                ProgressView().tint(.white)
                            } else {
                                Text(ctaDisplayText(cta.text, fallback: "Continue"))
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

                    // Sticky footer pinned to bottom
                    if let footer = stickyFooterSection {
                        stickyFooterView(data: footer.data, style: footer.style)
                    }
                }
                .padding(.bottom, config.layout?.footer_padding ?? 8)
            }
            // In a split the trailing pane's top is the paywall's top corner, where the dismiss
            // control is drawn: start below it.
            .padding(.top, splits ? 44 : 0)
            }
            // The sections and the pinned zone lay out in the surface column; on a wide window
            // they stop stretching edge to edge, while the background below still fills it.
            .appdnaSurfaceColumn()
            // Background as modifier — does NOT corrupt safe area (Apple HIG)
            .background { backgroundView.allowsHitTesting(false) }

            // Confetti/particle overlay
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
                                /*
                                 The retry RETRIES. It used to hide the banner and stop
                                 there, so a user who tapped "Try Again" saw the banner vanish and
                                 nothing else happen, while Android started the purchase again. It
                                 now runs the CTA's own path — the selected plan, the in-progress
                                 state, the same metadata — exactly as a second tap on the CTA would.
                                */
                                showErrorBanner = false
                                handleCTATap()
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
                    /*
                     🔴 Tapping the BANNER dismisses it, so a tap aimed at a covered CTA recovers
                     instead of doing nothing — whatever still overlaps (a long message, a narrow
                     screen, a pinned group measured a frame late), the user's instinctive second tap
                     clears the obstruction rather than vanishing into it.

                     And ONLY the banner. This gesture used to sit on the outer
                     `VStack { Spacer(); banner }`, whose `contentShape(Rectangle())` is the whole
                     SCREEN: while the banner was up, a tap on the CTA, a plan row, anything, only
                     hid the banner, so a user retrying a failed purchase bought nothing and saw
                     nothing (5 of 5 walks). The card's own shape is the hit area; the empty space
                     around it stays transparent to touches. The retry button inside keeps its own
                     action — a Button wins over its container's tap gesture.
                    */
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { withAnimation { showErrorBanner = false } }
                    .padding(.horizontal, 16)
                    /*
                     🔴 ABOVE THE PINNED ZONE, MEASURED — it used to be a hardcoded `80`.
                     *
                     * The pinned group is the CTA plus whatever is pinned with it: a restore link,
                     * legal text, and ANY section authored `zone: "bottom"` — the plan
                     * tiles included. Its real height is already measured into `pinnedZoneHeight`
                     * (`recordPinnedHeight`), and was used only to decide overflow. The banner
                     * guessed it as 80, so on any paywall whose pinned group is taller the banner
                     * covered the button that buys: the banner's background is opaque and
                     * hit-testable, so a tap aimed at the CTA reached no action — and a SwiftUI
                     * `Button` that receives no touch logs nothing, emits nothing and calls no
                     * delegate, which is indistinguishable from a store that refused.
                     *
                     * Measured on the two-plan walk fixture, whose pinned group is short: the CTA
                     * label sits at y=788 in an 874-point window and the banner's top edge at 794,
                     * so they overlap by ~6 points there. The overlap grows with the pinned group,
                     * which is why the fix is the measurement rather than a bigger constant.
                     *
                     * `max(80, …)` keeps the old spacing as a floor for the case the measurement has
                     * not landed yet (`pinnedZoneHeight` starts at 0), so a banner shown in the
                     * first frames cannot sit lower than it used to.
                     */
                    .padding(.bottom, max(80, pinnedZoneHeight + 16))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // The Back button, rendered INDEPENDENTLY of the close control.
            //
            // The first pass made "back" a dismiss STYLE, so a paywall could have a chevron or an X
            // but never both, and the two shared one position/colour/size. They are two buttons.
            // `back.allowed` deliberately does not exist: a back affordance that cannot be tapped is
            // not a thing anyone asked for — `enabled` is the whole switch.
            if let back = config.dismiss?.back, back.isEnabled, showBack {
                backAffordance(back)
            }

            // Dismiss control — show by default when config.dismiss is nil (not in Firestore).
            // `delay_seconds > 0` REVEALS the dismiss after N seconds and must win
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
                                .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                        }
                        .padding(.bottom, 24)
                    }
                case "back_button":
                    // A chevron that LEAVES the paywall, which returns the user to
                    // whatever was presented before it (a previous paywall, an onboarding step, a
                    // screen module). On a single-view paywall that is the same operation as close;
                    // what differs is the GLYPH. Navigating between
                    // views INSIDE one paywall is a separate feature — "FR · Console · Multi-view
                    // paywalls" — deliberately not built here.
                    backButton
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
            // The authored rank, which both platforms decoded and neither read.
            let plans = PaywallPlanOrder.sorted(sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans)
            if !plans.isEmpty {
                selectedPlanId = plans.first(where: { $0.isDefault == true })?.id ?? plans.first?.id
            }

            // Handle dismiss delay — always show dismiss when config.dismiss is nil (default behavior)
            // The Back button's own delay, independent of the close button's.
            let backDelay = config.dismiss?.back?.delaySeconds ?? 0
            if backDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(backDelay)) {
                    withAnimation { showBack = true }
                }
            } else {
                withAnimation { showBack = true }
            }
            let dismissDelay = config.dismiss?.delaySeconds ?? 0
            if dismissDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(dismissDelay)) {
                    withAnimation { showDismiss = true }
                }
            } else {
                withAnimation { showDismiss = true }
            }

            // Listen for post-purchase notifications (a repeated onAppear replaces them). The blocks capture
            // Bindings, never `self` — see `PaywallPurchaseObservers` (a captured view would keep the holder alive).
            let purchasing = $isPurchasing
            let successText = $successMessage
            let successOverlay = $showSuccessOverlay
            let confetti = $showConfetti
            let errorText = $errorMessage
            let retryText = $errorRetryText
            let allowRetry = $errorAllowRetry
            let errorBanner = $showErrorBanner
            // A plain value, not `self`: these blocks must not capture the view (see
            // `PaywallPurchaseObservers` — a captured view keeps the holder alive).
            let particleTrigger = config.particle_effect?.trigger
            purchaseObservers.register(
                onSuccess: { notif in
                    let info = notif.userInfo ?? [:]
                    successText.wrappedValue = info["message"] as? String ?? "Welcome to Premium!"
                    withAnimation { successOverlay.wrappedValue = true }
                    if info["confetti"] as? Bool == true { confetti.wrappedValue = true }
                },
                // The purchase ended with the paywall still up: re-enable the CTA.
                onEnded: { _ in
                    purchasing.wrappedValue = false
                },
                // The purchase SUCCEEDED, whichever `on_success` branch runs next.
                onCelebrate: { _ in
                    guard let effect = particleTrigger, effect == "on_purchase" else { return }
                    confetti.wrappedValue = true
                },
                onFailure: { notif in
                    let info = notif.userInfo ?? [:]
                    /*
                     * 🔴 STOP CELEBRATING. `handleCTATap` starts the particle effect when
                     * the CTA is TAPPED (it reads `trigger == "on_purchase"` and fires on the one
                     * moment that is definitely not a purchase), and nothing ever set it back. So a
                     * user who cancelled the sheet or had a card declined watched a congratulatory
                     * animation run on top of a payment-failed message, indefinitely.
                     *
                     * Clearing it here removes that, which is the user-visible half. Moving the
                     * trigger to the success path proper is the other half and needs plumbing the
                     * three `post_purchase.on_success` branches that dismiss without posting
                     * `.paywallPurchaseSuccess` — left for its own change rather than rushed here.
                     */
                    confetti.wrappedValue = false
                    errorText.wrappedValue = info["message"] as? String ?? "Payment failed."
                    retryText.wrappedValue = info["retry_text"] as? String ?? "Try Again"
                    let canRetry = (info["action"] as? String) == "retry"
                    allowRetry.wrappedValue = canRetry
                    purchasing.wrappedValue = false
                    withAnimation { errorBanner.wrappedValue = true }
                    // Auto-dismiss after 4s when there is no retry button —
                    // the banner otherwise has no escape path besides closing
                    // the entire paywall (e.g. when host triggers a failure
                    // without a retry action, the user sees a "Payment failed"
                    // banner pinned to the bottom of the screen indefinitely).
                    // When errorAllowRetry is true the banner stays up; user
                    // action is required to choose retry vs dismiss.
                    if !canRetry {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            withAnimation { errorBanner.wrappedValue = false }
                        }
                    }
                }
            )
        }
        // No `.onDisappear` removal: `purchaseObservers` removes them in its `deinit`.
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

    /// Extra buttons under the CTA, in authored order.
    ///
    /// This is what lifts the "two buttons, one of them restore" cap: a second restore, a
    /// "Maybe later", or a terms link are all just entries here. `filled` draws a button, `text`
    /// draws a tappable label like the restore link.
    @ViewBuilder
    private func extraButtonsView(_ buttons: [PaywallExtraButton]) -> some View {
        ForEach(buttons) { button in
            Button {
                performButtonAction(button.action, url: button.url, default: "dismiss")
            } label: {
                let size = CGFloat(button.font_size ?? 16)
                if (button.style ?? "filled") == "text" {
                    Text(loc("cta.extra.\(button.id)", button.text ?? ""))
                        .font(.system(size: size, weight: .medium))
                        .foregroundColor(button.text_color.map { Color(hex: $0) } ?? PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else {
                    Text(loc("cta.extra.\(button.id)", button.text ?? ""))
                        .font(.system(size: size, weight: .semibold))
                        .foregroundColor(button.text_color.map { Color(hex: $0) } ?? .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(button.bg_color.map { Color(hex: $0) } ?? Color.secondary.opacity(0.25))
                        // An extra button had a Background but always inherited the CTA's
                        // radius, so a pill CTA forced every extra button to be a pill. Unset still
                        // inherits, so existing paywalls are untouched.
                        .clipShape(RoundedRectangle(cornerRadius: CGFloat(button.corner_radius ?? config.cta?.resolvedCornerRadius ?? 12)))
                }
            }
        }
    }

    /// The ONE place an authored button action is dispatched.
    ///
    /// These are the four things a paywall can actually do. `dismiss` leaves the paywall, which
    /// returns the user to the previous screen — so "back" needs no separate action. `nil` falls
    /// back to the caller's default, which keeps an unauthored CTA purchasing and an unauthored
    /// restore link restoring.
    private func performButtonAction(_ action: String?, url: String?, default defaultAction: String) {
        let resolved = action ?? defaultAction
        switch resolved {
        case "restore":
            onRestore()
        case "dismiss":
            triggerDismiss()
        case "link":
            onAction?(.linkTapped)
            if let raw = url, let parsed = URL(string: raw) {
                InAppBrowser.present(url: parsed)
            }
        case "purchase":
            handleCTATap()
        // AN AUTHORED ACTION THIS SDK DOES NOT KNOW. The default arm still purchases,
        // because that is what every unauthored CTA has always done and changing it would break
        // paywalls that rely on it — but the host is told, which is the whole point of `.custom`:
        // an action "defined in the paywall config" that only the host can mean anything by.
        //
        // Line comments, not a block: `scripts/__tests__/cta-extra-buttons.test.ts` strips `//`
        // and asserts on the resulting SHAPE of this switch, so a block comment inside the arm
        // hides the code from the gate that guards it.
        default:
            onAction?(.custom)
            handleCTATap()
        }
    }

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

    private var dismissButton: some View { dismissGlyph("xmark") }

    /// The standalone Back control. Its own glyph, side, colour, size and delay.
    @ViewBuilder
    private func backAffordance(_ back: PaywallBackButton) -> some View {
        let glyphSize: CGFloat = back.size ?? 16
        let glyphColor: Color = back.color.map { Color(hex: $0) } ?? PaywallTextDefaults.readable(on: pageBackgroundHex)
        switch back.resolvedStyle {
        case "text_link":
            VStack {
                Button { triggerDismiss() } label: {
                    Text(loc("back.text", back.text ?? "Back"))
                        .font(.system(size: glyphSize))
                        .foregroundColor(glyphColor)
                }
                .padding(16)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: back.position == "top_right" ? .trailing : .leading)
            .transition(.opacity)
        default:
            Button { triggerDismiss() } label: {
                Image(systemName: back.resolvedStyle == "arrow" ? "arrow.left" : "chevron.left")
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundColor(glyphColor)
                    .frame(width: glyphSize * 2, height: glyphSize * 2)
                    .background(Color.black.opacity(0.3))
                    .clipShape(Circle())
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: back.position == "top_right" ? .trailing : .leading)
            .transition(.opacity)
        }
    }

    /// The back chevron. Same button, same dismissal; a different glyph.
    private var backButton: some View { dismissGlyph("chevron.left") }

    /// ONE builder for both, so an authored size, colour or position cannot be
    /// applied to the X and forgotten on the chevron. Unset reproduces the previous hardcoded
    /// 16pt / `.primary` / 32×32 circle exactly.
    private func dismissGlyph(_ systemName: String) -> some View {
        let glyphSize: CGFloat = config.dismiss?.size ?? 16
        let glyphColor: Color = config.dismiss?.color.map { Color(hex: $0) } ?? PaywallTextDefaults.readable(on: pageBackgroundHex)
        return Button {
            triggerDismiss()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundColor(glyphColor)
                .frame(width: glyphSize * 2, height: glyphSize * 2)
                .background(Color.black.opacity(0.3))
                .clipShape(Circle())
        }
        .padding(16)
        // The authored side. The enclosing ZStack is `.topTrailing`, so a
        // full-width frame with an explicit alignment is what lets the glyph move to the left.
        .frame(maxWidth: .infinity, alignment: (config.dismiss?.position ?? "top_right") == "top_left" ? .leading : .trailing)
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

    /**
     The dismiss control's footprint, reserved on BOTH sides of the header.

     The header title is centred across the FULL width and the dismiss control is an overlay with
     nothing holding space for it, so a title whose first line reaches the edge runs underneath. On
     a device, two different generated paywalls both put the ✕ on the word "going". It is a
     generated-content problem meeting a hand-authored default: the prompt asks for an outcome-led
     headline, so a generated title is a full sentence where a hand-authored one is a few words.

     The gate and the arithmetic mirror the control exactly — `neverDismissable` as the dismiss
     overlay computes it, and `.padding(16)` + `.frame(width: glyphSize * 2)` from `dismissButton`
     — so the inset and the button can never disagree about whether there is something up there.
     A delayed reveal reserves from the START, or the title reflows the moment the button appears.
     `text_link` sits at the bottom and `swipe_down` is a capsule at the top CENTRE, so neither
     steals width from a centred title.

     Computed HERE rather than in the `case "header"` arm: a paywall-level config read inside a
     `switch section.type` arm is attributed to that section by `check:authorability`, and the
     header has no `dismiss` field of its own.
     */
    private var headerCloseInset: CGFloat { PaywallHeaderInset.resolve(config.dismiss) }

    /**
     The page's own background, so text nobody authored can be read against IT rather than
     against the phone's appearance setting. `value` and `color` are the two spellings Firestore
     has used; a gradient or an image yields nil and the default falls back to light-on-dark, which
     is what this surface has always assumed for those.
     */
    private var pageBackgroundHex: String? {
        let bg = config.background ?? config.layout?.background
        switch bg?.type {
        case "color":
            // `{"type":"color"}` with no value paints white, so the ink reads white too.
            return bg?.color.flatMap { $0.isEmpty ? nil : $0 } ?? bg?.value.flatMap { $0.isEmpty ? nil : $0 } ?? "#FFFFFF"
        case "gradient", "image", "video", "transparent", "clear", "none":
            return nil
        default:
            // No authored background: the page is the system's, so its ink follows the system's.
            return colorScheme == .dark ? "#000000" : "#FFFFFF"
        }
    }

    private func sectionContent(for section: PaywallSection) -> AnyView {
        switch section.type {
        case "header":
            return AnyView(HeaderSection(data: section.data, loc: loc, sectionStyle: section.style,
                                         closeInset: headerCloseInset)
                .applyContainerStyle(section.style?.container))
        case "features":
            return AnyView(FeatureList(
                features: (section.data?.features ?? []).enumerated().map { i, f in loc("feature.\(i)", f) },
                // A feature row now reports that the user tapped it.
                onFeatureSelected: { onAction?(.featureSelected) },
                richItems: section.data?.items,
                columns: Int(section.data?.featureColumns ?? 1),
                gap: section.data?.featureGap ?? 12,
                sectionStyle: section.style,
                iconColorOverride: section.data?.iconColor,
                itemTextColorOverride: section.data?.itemTextColor,
                subtitleColorOverride: section.data?.itemSubtitleColor,
                subtitleFontSize: section.data?.itemSubtitleFontSize,
                itemImageShape: section.data?.itemImageShape,
                itemExcludedColor: section.data?.itemExcludedColor,
                iconBgColor: section.data?.iconBgColor,
                iconBgOpacity: section.data?.iconBgOpacity ?? 0.15,
                iconBgSize: section.data?.iconBgSize ?? 32)
                .applyContainerStyle(section.style?.container))
        case "plans":
            // Plans can be in section.data.plans OR top-level config.plans
            let sectionPlans = section.data?.plans ?? []
            /*
             * 🔴 THE SORT BELONGS HERE, because this is the only site that DRAWS.
             *
             * `PaywallPlanOrder.sorted` was added for "the order a paywall's plans draw in" and
             * wired it into `selectedPlan` and `onAppear` — both of which resolve a plan with
             * `first(where: { $0.id == … })`, where order is irrelevant by construction. This site,
             * the one where order IS the entire question, did not call it, so an authored rank
             * reordered nothing on screen and plans drew in whatever order they were serialised in.
             * Android has always sorted at its own render site (`PaywallActivity.kt`, `"plans" ->`),
             * so the same document drew in two different orders on the two platforms.
             *
             * `sorted` is a no-op unless some plan carries `sort_order`, so nothing published
             * without a rank moves. Measured by `PlanOrderRenderTests`, which compares RENDERS
             * rather than calling the sorter — the shared fixture calls it directly and therefore
             * could not see that no renderer did.
             */
            let effectivePlans = PaywallPlanOrder.sorted(sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans)
            return AnyView(plansSection(plans: effectivePlans, style: section.style)
                .applyContainerStyle(section.style?.container))
        case "cta":
            /*
             * CTA section: top-level cta.text takes priority, then section config text.
             *
             * 🔴 THROUGH `ctaLabel` LIKE THE OTHER THREE. This arm resolved the text itself, so it
             * got neither the selected plan's own `cta_text` nor the multi-plan default.
             * Whether it is reachable today is beside the point: a CTA site that resolves
             * its own label is how the arms drifted before, and a fourth one sitting here would be the next
             * one. The `ctaLabel(` count is pinned by a test so a fifth cannot appear quietly.
             */
            let topLevelText = config.cta?.text
            let sectionText = section.data?.ctaText ?? section.data?.text
            let ctaText = ctaLabel(topLevelText ?? sectionText)
            return AnyView(CTAButton(
                cta: config.cta,
                isPurchasing: isPurchasing,
                onTap: handleCTATap,
                loc: loc,
                sectionStyle: section.style,
                ctaGradient: section.data?.ctaGradient,
                textOverride: ctaText,
                planNameSuffix: planNameSuffix,
                planNameFormat: planNameFormat,
                ctaFontSize: section.data?.ctaFontSize,
                ctaFontWeight: section.data?.ctaFontWeight,
                restoreText: section.data?.restoreText,
                showRestore: section.data?.showRestore ?? false,
                restorePosition: section.data?.restorePosition ?? "below",
                restoreTextColor: section.data?.restoreTextColor,
                restoreFontSize: section.data?.restoreFontSize.map { CGFloat($0) },
                restoreGap: section.data?.restoreGap,
                // The other CTA path (a paywall whose restore link is drawn INSIDE the CTA
                // component) has to honour the same pair, or the control would work on one layout
                // and silently do nothing on the other.
                restoreBgColor: section.data?.restoreBgColor,
                restoreCornerRadius: section.data?.restoreCornerRadius.map { CGFloat($0) }
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
                // Icon: an SF Symbol name, else the default shield (`GuaranteeIcon`).
                Image(systemName: GuaranteeIcon.symbol(data?.icon))
                    .font(.system(size: 28))
                    .foregroundColor(Color(hex: data?.accentColor ?? "#22C55E"))

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
                            .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
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
                            .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .applyContainerStyle(style?.container)
        }
    }

    // MARK: - Social proof with sub-types

    private func socialProofSection(data: PaywallSectionData?, style: SectionStyleConfig?) -> AnyView {
        switch data?.subType {
        case "countdown":
            return AnyView(countdownTimer(
                duration: data?.countdownSeconds ?? 86400,
                data: data,
                valueTextStyle: style?.elements?["value"]?.textStyle))
        case "trial_badge":
            if let ts = style?.elements?["value"]?.textStyle {
                return AnyView(Text(loc("social_proof.trial_badge", data?.text ?? "Free Trial"))
                    .applyTextStyle(ts)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: paywallAccentHex).opacity(0.15))
                    .clipShape(Capsule()))
            } else {
                return AnyView(Text(loc("social_proof.trial_badge", data?.text ?? "Free Trial"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: paywallAccentHex).opacity(0.15))
                    .foregroundColor(Color(hex: paywallAccentHex))
                    .clipShape(Capsule()))
            }
        default: // app_rating
            return AnyView(SocialProof(data: data, loc: loc, sectionStyle: style))
        }
    }

    // MARK: - Image section

    @ViewBuilder
    private func imageSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        PaywallImageSectionView(data: data, style: style)
    }

    // MARK: - Testimonial section

    private func testimonialSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let quoteTextStyle = style?.elements?["quote"]?.textStyle
        let authorNameTextStyle = style?.elements?["author_name"]?.textStyle
        let authorRoleTextStyle = style?.elements?["author_role"]?.textStyle
        // And their containers, from the ElementStylePanel the console shows beside each
        // TextStylePanel. Resolved once: `author_name` is drawn at TWO sites below, the card/quote
        // layouts and the `minimal` one, and wiring only the first is how earlier elements
        // reached a device with an authored border that drew nowhere.
        let quoteElementStyle = style?.elements?["quote"]?.container
        let authorNameElementStyle = style?.elements?["author_name"]?.container
        let authorRoleElementStyle = style?.elements?["author_role"]?.container
        let layout = data?.layout ?? "quote"

        let content = VStack(spacing: 12) {
            // Quote mark only for "quote" layout
            if layout == "quote" {
                Text("\u{201C}")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
            }

            Group {
                if let ts = quoteTextStyle {
                    Text(loc("testimonial.quote", data?.quote ?? data?.testimonial ?? ""))
                        .applyTextStyle(ts)
                } else {
                    Text(loc("testimonial.quote", data?.quote ?? data?.testimonial ?? ""))
                        .italic()
                        .multilineTextAlignment(.center)
                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                        .font(layout == "minimal" ? .caption : .body)
                }
            }
            .applyElementStyle(quoteElementStyle)

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
                        Group { if let name = data?.authorName {
                            let interpolatedName = loc("testimonial.author_name", name)
                            if let ts = authorNameTextStyle {
                                Text(interpolatedName).applyTextStyle(ts)
                            } else {
                                Text(interpolatedName).font(.subheadline.weight(.semibold)).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                            }
                        } }
                        .applyElementStyle(authorNameElementStyle)
                        Group { if let role = data?.authorRole {
                            let interpolatedRole = loc("testimonial.author_role", role)
                            if let ts = authorRoleTextStyle {
                                Text(interpolatedRole).applyTextStyle(ts)
                            } else {
                                Text(interpolatedRole).font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                            }
                        } }
                        .applyElementStyle(authorRoleElementStyle)
                    }
                }
            } else if let name = data?.authorName {
                // Minimal: just author name inline. The SECOND site this element is drawn
                // at, and it honours the same text style and container as the card layouts: the
                // console has one control, and a host sees whichever layout it authored.
                Group {
                    if let ts = authorNameTextStyle {
                        Text("— \(loc("testimonial.author_name", name))").applyTextStyle(ts)
                    } else {
                        Text("— \(loc("testimonial.author_name", name))")
                            .font(.caption.weight(.medium)).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                    }
                }
                .applyElementStyle(authorNameElementStyle)
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

    // MARK: - Lottie section

    @ViewBuilder
    private func lottieSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let lottieUrl = data?.lottieUrl {
            let block = LottieBlock(
                lottie_url: lottieUrl,
                autoplay: true,
                loop: data?.lottieLoop ?? true,
                speed: data?.lottieSpeed ?? 1.0,
                width: nil,
                height: Double(data?.lottieHeight ?? data?.height ?? 180),
                alignment: "center",
                play_on_scroll: nil,
                play_on_tap: nil
            )
            LottieBlockView(block: block)
                .applyContainerStyle(style?.container)
        }
    }

    // MARK: - Video section

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

    // MARK: - Rive section

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

    // MARK: - Countdown section

    @ViewBuilder
    private func countdownSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let duration = data?.durationSeconds ?? data?.countdownSeconds ?? 3600
        let valueTextStyle = style?.elements?["value"]?.textStyle
        let layout = data?.layout ?? "inline"
        // Prefer `label_text` (the countdown-specific console field) over the
        // generic `label`, matching Android (PaywallActivity: `label_text ?: label`). iOS had the
        // precedence inverted, so a section with both set rendered a different string per platform.
        let labelText = data?.labelText ?? data?.label

        VStack(spacing: 8) {
            // Label text (e.g. "Offer ends in")
            if let label = labelText {
                // Honor the authored `label_font_size` + `label_color` (both decoded but
                // ignored) with Android's exact defaults (14pt, semibold, #7F1D1D dark-red). iOS was
                // hardcoded to `.caption`(~12pt)/medium/system-grey, so the label size was silently
                // dropped and the default color differed on every countdown (grey vs dark-red) from Android.
                Text(loc("countdown.label", label))
                    // `label_font_weight` is a console control that reached no renderer.
                    .font(.system(size: data?.labelFontSize ?? 14, weight: resolvePaywallFontWeight(data?.labelFontWeight, default: .semibold)))
                    .foregroundColor(Color(hex: data?.labelColor ?? "#7F1D1D"))
            }

            if layout == "boxed" || layout == "banner" {
                countdownTimer(duration: duration, data: data, valueTextStyle: valueTextStyle)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: layout == "banner" ? 0 : 12)
                            .fill(Color(hex: data?.backgroundColor ?? "#FEF2F2"))
                    )
            } else {
                countdownTimer(duration: duration, data: data, valueTextStyle: valueTextStyle)
            }
        }
    }

    /*
     * The countdown's six expiry/format fields, passed through in one place.
     *
     * `auto_advance` is wired to the renderer's own dismiss rather than to anything the view
     * reaches for: the paywall owns its lifecycle, and a view that dismissed itself would bypass
     * the single dismiss guard `PaywallManager` keeps (the one that stops the SDK dismissing
     * twice). `.programmatic` is the honest reason — the user did nothing; the timer ran out.
     */
    private func countdownTimer(
        duration: Int,
        data: PaywallSectionData?,
        valueTextStyle: TextStyleConfig?
    ) -> some View {
        CountdownTimerView(
            seconds: duration,
            valueTextStyle: valueTextStyle,
            showDays: data?.showDays,
            showHours: data?.showHours,
            showMinutes: data?.showMinutes,
            showSeconds: data?.showSeconds,
            onExpireAction: data?.onExpireAction,
            expiredText: data?.expiredText.map { loc("countdown.expired_text", $0) },
            onExpire: { onDismiss(.programmatic) },
            digitFontSize: data?.digitFontSize,
            digitFontWeight: data?.digitFontWeight,
            digitColorHex: data?.textColor,
            // The Variant the console offers and no renderer read.
            variant: data?.variant
        )
    }

    // MARK: - Legal section

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

        // The `text` element, which the console's Style tab offers for this section and
        // neither half of which was read: not the text style, not the container. An author styling
        // the legal paragraph got nothing at all.
        let textElementStyle = style?.elements?["text"]?.textStyle
        let textElementContainer = style?.elements?["text"]?.container

        VStack(spacing: 8) {
            if let text = data?.text {
                // Parse markdown-style links: [text](url)
                Group {
                    if let ts = textElementStyle {
                        Text(parseMarkdownLinks(text))
                            .applyTextStyle(ts)
                            .multilineTextAlignment(textAlignment)
                            .tint(linkColor)
                    } else {
                        Text(parseMarkdownLinks(text))
                            .font(.system(size: size))
                            .foregroundColor(textColor)
                            .multilineTextAlignment(textAlignment)
                            .tint(linkColor)
                    }
                }
                .applyElementStyle(textElementContainer)
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
                                onAction?(.linkTapped)   // reported before the browser opens
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
            onAction?(.linkTapped)   // A markdown link inside the legal paragraph counts
            InAppBrowser.present(url: url)
            return .handled
        })
    }

    /// The sticky footer's secondary action, resolved.
    ///
    /// `internal static` so the test can drive the REAL code. The Button body above
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

    /// Forwards to the shared parser in `LegalMarkdownLinks.swift`, so the
    /// Screens/Sections legal renderer uses the SAME one instead of a plain-Text copy.
    private func parseMarkdownLinks(_ text: String) -> AttributedString {
        legalMarkdownLinks(text)
    }

    // MARK: - Divider section

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
                        /*
                         * `label_bg_color`, which this hard-coded to `.clear` while Android
                         * has always honoured it (`PaywallActivity.kt`, the divider's label
                         * background with a 4dp corner). Both SDKs DECODE the key; only one drew
                         * it, so a divider authored with a label chip rendered as a chip on
                         * Android and as bare text on iOS — one document, two paywalls, which is
                         * the divergence class ADR-001 exists to prevent.
                         *
                         * Unauthored stays `.clear`, so nothing already published moves.
                         */
                        .background(
                            (data?.labelBgColor.map { Color(hex: $0) } ?? Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        )
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

    // MARK: - Sticky footer

    @ViewBuilder
    private func stickyFooterView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let bgColor = Color(hex: data?.backgroundColor ?? "#FFFFFF")

        VStack(spacing: 8) {
            // CTA button — the one `ctaLabel` resolution, as the other two sites use.
            if let ctaText = ctaLabel(data?.ctaText) {
                Button {
                    handleCTATap()
                } label: {
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(ctaDisplayText(data?.ctaText, locKey: "sticky_footer.cta", fallback: ctaText))
                            .font(.system(size: data?.ctaFontSize ?? 17, weight: resolveCTAFontWeight(data?.ctaFontWeight)))
                            .foregroundColor(Color(hex: data?.ctaTextColor ?? "#FFFFFF"))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: data?.ctaHeight ?? 52)
                .background(Color(hex: data?.ctaBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                .clipShape(RoundedRectangle(cornerRadius: data?.ctaCornerRadius ?? 14))
                // The sticky footer's own CTA, under the same rule as the section one and
                // Android's: a button that cannot resolve a plan refuses the tap and shows it.
                .disabled(isPurchasing || selectedPlanId == nil)
                .opacity(selectedPlanId == nil ? 0.5 : 1)
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
                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                }
            }

            // Legal text
            if let legalText = data?.legalText {
                // The size and colour are now authored. Unset keeps the previous
                // hardcoded 10pt / `.secondary`, so a published paywall is unchanged. This is what
                // made a footer size problem look like a Legal-section bug: the footer Subtitle was pinned at 10pt
                // while the Legal SECTION honoured its authored size, so a 13pt legal paragraph
                // genuinely rendered larger than this line — which the author had sized to 16.
                Text(loc("sticky_footer.legal", legalText))
                    .font(.system(size: data?.legalFontSize ?? 10))
                    .foregroundColor(data?.legalTextColor.map { Color(hex: $0) } ?? PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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

    // MARK: - Card section

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
                    Text(loc("card.title", title)).font(.headline).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                }
                if let subtitle = data?.subtitle {
                    Text(loc("card.subtitle", subtitle)).font(.subheadline).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                }
                if let text = data?.text {
                    Text(loc("card.body", text)).font(.body).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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

    // MARK: - Carousel section

    @ViewBuilder
    private func carouselSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        if let pages = data?.pages, !pages.isEmpty {
            CarouselView(
                pages: pages,
                config: config,
                autoScroll: data?.autoScroll ?? false,
                autoScrollIntervalMs: data?.autoScrollIntervalMs ?? 3000,
                showIndicators: data?.showIndicators ?? true,
                // The inactive indicator. `#666666` reads on both pages so it was never a
                // defect, but Android resolves this from the page and two SDKs drawing a
                // different grey for the same unauthored field is a divergence worth
                // closing. Same function, same answer, on both.
                indicatorColor: data?.indicatorColor
                    ?? PaywallTextDefaults.readableHex(on: pageBackgroundHex),
                hasAuthoredIndicatorColor: data?.indicatorColor != nil,
                // The ACTIVE indicator, read off the page. White over a white page is one
                // dot's worth of nothing, and Android's equivalent was fixed the same way.
                indicatorActiveColor: data?.indicatorActiveColor
                    ?? PaywallTextDefaults.readableHex(on: pageBackgroundHex),
                height: data?.height,
                loc: loc
            )
        }
    }

    // MARK: - Timeline section

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
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                    }
                                }
                                if index < items.count - 1 && showLine {
                                    Rectangle().fill(Color(hex: data?.lineColor ?? "#D1D5DB")).frame(height: 2)
                                }
                            }
                            if let title = item.title {
                                Text(title).font(.caption.weight(.semibold)).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex)).multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 80)
                    }
                }
                .padding(.horizontal, 8)
            }
        } else {
        // Vertical timeline (default)
        // The timeline's rail, read off the page. It was white, so on a light paywall the
        // steps floated with nothing joining them.
        let connectorColor = Color(
            hex: data?.lineColor
                ?? style?.elements?["connector"]?.textStyle?.color
                ?? PaywallTextDefaults.readableHex(on: pageBackgroundHex))
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

    // MARK: - Icon grid section

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

                    // The icon grid's two text elements, each with the container the
                    // console's ElementStylePanel writes beside its text style.
                    Group { if let label = item.label ?? item.title {
                        let ts = style?.elements?["title"]?.textStyle
                        if let ts = ts {
                            Text(label).applyTextStyle(ts)
                        } else {
                            Text(label)
                                .font(.caption.weight(.medium))
                                .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                .multilineTextAlignment(.center)
                        }
                    } }
                    .applyElementStyle(style?.elements?["title"]?.container)

                    Group { if let desc = item.description ?? item.subtitle {
                        let ds = style?.elements?["description"]?.textStyle
                        if let ds = ds {
                            Text(desc).applyTextStyle(ds)
                        } else {
                            Text(desc)
                                .font(.caption2)
                                .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    } }
                    .applyElementStyle(style?.elements?["description"]?.container)
                }
            }
        }
    }

    // MARK: - Comparison table section

    private func comparisonTableSectionView(data: PaywallSectionData?, style: SectionStyleConfig?) -> some View {
        let resolved = PaywallTableColumns.resolve(
            structured: data?.tableColumns,
            fallback: data?.columns?.value,
        )
        let columnLabels = resolved.labels
        let columnHighlights = resolved.highlights
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
                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)

                ForEach(Array(columnLabels.enumerated()), id: \.offset) { colIdx, label in
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
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
                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
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

    // MARK: - Promo input section

    /**
     What a promo code submission resolves to. A REVENUE path.

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
                .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                .font(.subheadline)

            Button {
                // Submit promo code via delegate callback.
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
                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
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

    // MARK: - Toggle section

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
                        /*
                         🔴 This default was the literal `"#FFFFFF"`, which over a white
                         page is a label that is not on the screen. It is the one site on this
                         surface the appearance-drift probe could NOT see: a fixed hex does not
                         change with the phone, so it scored zero drift while being invisible.
                         Two different defects, two different measurements — the other is the
                         light-page ink count Android's sweep uses.
                        */
                        .foregroundColor(
                            data?.labelColorVal.map { Color(hex: $0) }
                                ?? PaywallTextDefaults.readable(on: pageBackgroundHex))
                }
                if let desc = data?.description {
                    Text(loc("toggle.description", desc))
                        .font(.caption)
                        // `#9CA3AF` reads on both pages, so only the authored path changes
                        // here: it is a real mid-grey rather than an assumption about the backdrop.
                        .foregroundColor(Color(hex: data?.descriptionColor ?? "#9CA3AF"))
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color(hex: data?.onColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
        }
    }

    // MARK: - Reviews carousel section

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
                // `elements[…]` is a SectionElementConfig now; the card wants the
                // container half of it, from either spelling.
                cardStyle: style?.elements?["card"]?.container,
                // The other two elements' containers, from the same panel.
                textElementStyle: style?.elements?["text"]?.container,
                authorElementStyle: style?.elements?["author"]?.container,
                loc: loc
            )
        }
    }

    // MARK: - Plans

    // Grid/carousel/stack plan layouts
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
                .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                                .foregroundColor(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc("plan.\(index).name", plan.displayName))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                HStack(spacing: 4) {
                                    Text(loc("plan.\(index).price", plan.displayPrice)).font(.caption.bold()).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                    if let period = plan.displayPeriod {
                                        Text("/ \(period)").font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                    .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
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
                                    // 13pt to match Android's 13.sp on this arm, rather than
                                    // `.subheadline` (15pt). A tab bar is the one place the two
                                    // platforms sit side by side in a screenshot comparison, and an
                                    // 2pt difference reads as a bug in whichever one you look at
                                    // second. The console preview draws it at 12px.
                                    .font(.system(size: 13, weight: .semibold))
                                Text(loc("plan.\(index).price", plan.displayPrice))
                                    .font(.caption)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .foregroundColor(selectedPlanId == plan.id ? .white : PaywallTextDefaults.readable(on: pageBackgroundHex))
                            .background(
                                Capsule().fill(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : Color.clear)
                            )
                        }
                        .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
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
                if let (idx, selected) = plans.enumerated().first(where: { $0.element.id == selectedPlanId }) {
                    HStack(spacing: 4) {
                        Text(loc("plan.\(idx).price", selected.displayPrice)).font(.title3.bold())
                        if let period = selected.displayPeriod {
                            Text("/ \(period)").font(.subheadline).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                                .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                            Text(loc("plan.\(index).price", plan.displayPrice))
                                .font(.subheadline.bold())
                                .foregroundColor(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : PaywallTextDefaults.readable(on: pageBackgroundHex))
                            if let period = plan.displayPeriod {
                                Text("/ \(period)")
                                    .font(.caption2)
                                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 10)
                            .fill(selectedPlanId == plan.id ? (cardStyle.selectedBgColor.flatMap { Color(hex: $0) } ?? Color.clear) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: cardStyle.cardCornerRadius ?? 10)
                            .stroke(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : Color.clear, lineWidth: 2))
                    }
                    .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                }
            })

        // Explicit vertical stack cases
        /*
         A tab bar, one tab per plan, with the SELECTED plan's full card beneath it.

         The console has offered this style in its picker since it shipped and neither renderer had
         a case for it, so an author picked "Tab groups", saw the console preview draw it,
         published, and every device silently drew the default vertical stack instead.

         The shape is the console preview's (`PaywallPreview.tsx`, "6. Tab Groups") — the only
         specification that existed: equal-width tabs over a full-width rule, the selected tab's
         segment of that rule in the accent colour, and one plan card below.

         🔴 Deliberately NOT a `Picker(.segmented)`, which is what `segmented_toggle` already is.
         The point of this style is a tab bar whose selected tab owns the detail panel underneath,
         and a segmented control cannot express that — it also caps out visually at a handful of
         options, while tabs degrade predictably.
         */
        case "tab_groups":
            let tabAccent = Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))
            // Read off the PAGE, not `.primary`/`.secondary`, which follow the PHONE's
            // appearance and so drew different pixels in light and dark for the same paywall.
            let tabInactiveInk = PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7)
            let tabRule = PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.2)
            // `firstIndex` can miss (no selection yet, or a stale id), so the fallback is the
            // first plan — and it is clamped, because `plans` is author-supplied and may be empty.
            let selectedIndex = plans.firstIndex(where: { $0.id == selectedPlanId }) ?? 0
            let selectedPlan = selectedIndex < plans.count ? plans[selectedIndex] : nil
            return AnyView(VStack(spacing: 12) {
                HStack(spacing: 0) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        let isSelected = plan.id == selectedPlan?.id
                        Button { selectPlan(plan.id) } label: {
                            VStack(spacing: 8) {
                                Text(loc("plan.\(index).name", plan.displayName))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(isSelected ? tabAccent : tabInactiveInk)
                                    .lineLimit(1)
                                Rectangle()
                                    .fill(isSelected ? tabAccent : tabRule)
                                    .frame(height: 2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
                        .buttonStyle(.plain)
                    }
                }
                if let selected = selectedPlan {
                    PlanCard(plan: selected, isSelected: true,
                             onSelect: { selectPlan(selected.id) }, planIndex: selectedIndex,
                             loc: loc, sectionStyle: style, cardStyle: cardStyle)
                }
            })

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
                                    Text(loc("plan.\(index).name", plan.displayName))
                                        .font(.headline)
                                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                    Spacer()
                                    Text(loc("plan.\(index).price", plan.displayPrice))
                                        .font(.headline)
                                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
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
                                    Text(desc).font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                        .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
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
                                .foregroundColor(selectedPlanId == plan.id ? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")) : PaywallTextDefaults.readable(on: pageBackgroundHex))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
                        .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    }
                }
                .background(Color.gray.opacity(0.05))
                // Price row
                HStack(spacing: 0) {
                    Text("Price").font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    ForEach(plans, id: \.id) { plan in
                        Text(plan.displayPrice).font(.caption.bold()).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex)).frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                Divider()
                // Feature rows
                ForEach(compFeatures, id: \.self) { feature in
                    HStack(spacing: 0) {
                        Text(feature).font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
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
                            .foregroundColor(labelStyle?.color.map { Color(hex: $0) } ?? PaywallTextDefaults.readable(on: pageBackgroundHex))
                        Text(plan.displayPrice)
                            .font(priceStyle?.font_size.map { .system(size: CGFloat($0), weight: .bold) } ?? .title.bold())
                            .foregroundColor(priceStyle?.color.map { Color(hex: $0) } ?? Color(hex: cardStyle.selectedBorderColor ?? (AppDNA.brandAccentHex ?? "#6366F1")))
                        if let badge = plan.badge, !badge.isEmpty {
                            Text(badge).font(.caption.bold()).foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFF"))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))).clipShape(Capsule())
                        }
                        if let desc = plan.description, !desc.isEmpty {
                            Text(desc).font(.subheadline).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7)).multilineTextAlignment(.center)
                        }
                        if let features = plan.features, !features.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(features, id: \.self) { f in
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                        Text(f).font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
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
                                Text(plan.displayName).font(.headline).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                Text(plan.displayPrice).font(.title3.bold()).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                if let badge = plan.badge, !badge.isEmpty {
                                    Text(badge).font(.caption2.bold()).foregroundColor(Color(hex: cardStyle.badgeTextColor ?? "#FFF"))
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Color(hex: cardStyle.badgeBgColor ?? (AppDNA.brandAccentHex ?? "#6366F1"))).clipShape(Capsule())
                                }
                                if let desc = plan.description, !desc.isEmpty {
                                    Text(desc).font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                        .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
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
                                Text(plan.displayName).font(.subheadline.weight(.semibold)).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                Spacer()
                                Text(plan.displayPrice).font(.subheadline.bold()).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
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
                                        Text(desc).font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                                    }
                                    if let savings = plan.savings_text, !savings.isEmpty {
                                        Text(savings).font(.caption.bold()).foregroundColor(Color(hex: "#22C55E"))
                                    }
                                    if let features = plan.features, !features.isEmpty {
                                        ForEach(features, id: \.self) { f in
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                                Text(f).font(.caption).foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
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
                    .accessibilityAddTraits(selectedPlanId == plan.id ? [.isSelected] : [])
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
        /*
         * The user CHOSE this plan. Only reached from a tap: `.onAppear` seeds
         * `selectedPlanId` directly rather than through here, so the default selection is not
         * reported as a change the user made.
         */
        onAction?(.planChanged)
        HapticEngine.triggerIfEnabled(config.haptic?.triggers?.on_plan_select, config: config.haptic)
    }

    // MARK: - CTA handler

    private func handleCTATap() {
        /*
         * 🔴 REPORTED BEFORE THE GUARDS, and that ordering is the whole point. The two
         * `guard`s below return SILENTLY: no delegate call, no event, no log. A user sees a button
         * do nothing, the host learns nothing, and from outside the app a swallowed tap is
         * indistinguishable from a purchase the store refused — which is exactly why a dead CTA
         * once could not be diagnosed. The action means "the user tapped the CTA", so it fires whenever they
         * did, whatever happens next.
         */
        onAction?(.ctaTapped)
        guard let planId = selectedPlanId else {
            // A CTA that buys nothing used to be silent. Say which guard stopped it.
            Log.warning("Paywall CTA tapped with no plan selected — nothing to purchase")
            return
        }
        // Plans can be in section.data.plans OR top-level config.plans
        let sectionPlans = config.sections.first(where: { $0.type == "plans" })?.data?.plans ?? []
        // Sorted for the same reason Android's `effectivePlans()` is: this lookup is by id
        // and so cannot care about order TODAY, but every one of these four resolution sites now
        // reads the same order, which once stopped being true and drew the wrong plan order.
        let allPlans = PaywallPlanOrder.sorted(sectionPlans.isEmpty ? (config.plans ?? []) : sectionPlans)
        /*
         * A plan tap can fail to take, and the CTA then buys the plan selected BEFORE it:
         * measured once in roughly ten runs, with the row's own label in the log and the CTA
         * recorded enabled and hittable. The selection state at the instant of the press is the
         * one fact that separates the two possible halves — a tap that never reached `selectPlan`
         * (the id here is the OLD plan) from a purchase path reading a stale value (the id here is
         * the NEW plan while the bought product is the old one). Neither is visible from outside.
         *
         * It also names which collection resolved the plan, because the rows and this lookup can
         * read DIFFERENT arrays — root `plans` versus a `plans` section — and that mismatch buys a
         * product the row never showed.
         */
        Log.debug("Paywall CTA: selectedPlanId=\(planId) resolvedFrom=\(sectionPlans.isEmpty ? "config.plans" : "section.data.plans") "
            + "candidates=\(allPlans.map { $0.id }.joined(separator: ","))")
        guard let plan = allPlans.first(where: { $0.id == planId }) else {
            // The selected row is not in the array this resolves from — a silent no-op before.
            Log.warning("Paywall CTA: selected plan \(planId) is not among \(allPlans.map { $0.id }.joined(separator: ",")) — nothing purchased")
            return
        }
        // Haptic on CTA tap
        HapticEngine.triggerIfEnabled(config.haptic?.triggers?.on_button_tap, config: config.haptic)
        /*
         * 🔴 THE CELEBRATION DOES NOT START HERE ANY MORE. This read
         * `trigger == "on_purchase"` and fired on the CTA TAP, which is the one moment that is
         * definitely not a purchase — so a user who cancelled the sheet or had a card declined
         * watched a congratulatory animation, and nothing ever stopped it. It now fires from
         * `.paywallPurchaseCelebrate`, posted once by `handlePostPurchaseSuccess` before it
         * branches, so every `on_success` action celebrates and no failure does.
         */
        isPurchasing = true
        // Include toggle states in purchase metadata
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

/**
 The dismiss control's footprint, as a value both platforms can be held to.

 This used to be computed inline on each platform and pinned it with a SOURCE gate: a gate that reads
 the arithmetic cannot tell you the two renderers agree, only that they contain similar text. They
 did not agree — this side reserved space for a `swipe` dismiss and Android did not, so one
 authored paywall wrapped its title differently on each platform and nothing said so.

 One function, driven by the `paywall_header_close_inset` fixture on both platforms.

 `swipe` and `swipe_down` are the same control under two spellings (the legacy `type` used
 `swipe`), and it is a capsule at the top CENTRE; `text_link` sits at the bottom. Neither steals
 width from a centred title, so neither reserves. A delayed reveal reserves from the START, or the
 title reflows the moment the button appears.
 */
enum PaywallHeaderInset {
    /// The horizontal padding a centred header title needs on BOTH sides, in points.
    static func resolve(_ dismiss: PaywallDismiss?) -> CGFloat {
        let style = dismiss?.style ?? "x_button"
        let neverDismissable = !(dismiss?.isAllowed ?? true) && (dismiss?.delaySeconds ?? 0) <= 0
        let reservesTopCorner = !neverDismissable
            && style != "text_link" && style != "swipe" && style != "swipe_down"
        guard reservesTopCorner else { return 0 }
        let glyphSize: CGFloat = dismiss?.size ?? 16
        // Mirrors the control itself: `.padding(16)` + `.frame(width: glyphSize * 2)`.
        return 16 + glyphSize * 2
    }
}

/// The paywall's own background colour, for any view choosing a default text colour.
private struct PaywallAccentHexKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The paywall's own accent: its CTA's authored colour, for elements with no colour field of their own.
    var paywallAccentHex: String? {
        get { self[PaywallAccentHexKey.self] }
        set { self[PaywallAccentHexKey.self] = newValue }
    }
}

private struct PaywallBackgroundHexKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var paywallBackgroundHex: String? {
        get { self[PaywallBackgroundHexKey.self] }
        set { self[PaywallBackgroundHexKey.self] = newValue }
    }
}

/// A paywall image section. Its own view so the accessibility label can be read back by a test.
struct PaywallImageSectionView: View {
    let data: PaywallSectionData?
    let style: SectionStyleConfig?

    @ViewBuilder
    var body: some View {
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
            .modifier(PaywallImageAltModifier(label: PaywallImageAccessibility.label(data)))
            .applyContainerStyle(style?.container)
        }
    }
}

/// The authored alt text as the image's accessibility label (one element, an image). No alt → unchanged.
private struct PaywallImageAltModifier: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(.isImage)
        } else {
            content
        }
    }
}
