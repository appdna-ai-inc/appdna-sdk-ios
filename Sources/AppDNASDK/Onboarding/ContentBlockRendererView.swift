import SwiftUI
import MapKit
import PhotosUI
// MARK: - Content Block Renderer

struct ContentBlockRendererView: View {
    let blocks: [ContentBlock]
    let onAction: (_ action: String, _ actionValue: String?) -> Void
    @Binding var toggleValues: [String: Bool]
    var loc: ((String, String) -> String)? = nil
    /// Step responses collected so far (for visibility conditions & bindings).
    var responses: [String: Any] = [:]
    /// Hook data from `onBeforeStepRender` (for visibility conditions & bindings).
    var hookData: [String: Any]? = nil
    /// Input values for form input blocks. Key = field_id, Value = field value.
    @Binding var inputValues: [String: Any]
    /// Current step index in the onboarding flow (0-based). Used for auto-binding page_indicator and progress_bar.
    var currentStepIndex: Int = 0
    /// Total number of steps in the onboarding flow. Used for auto-binding progress_bar.
    var totalSteps: Int = 1
    /// When true, vertical_align is handled by the parent ThreeZoneStepLayout (zone partitioning),
    /// so BlockPositionModifier should not map vertical_align to frame alignment.
    var isZoneManaged: Bool = false
    /// Scroll offset from parent ScrollView — used for collapse_on_scroll blocks (Sprint 7).
    var scrollOffset: CGFloat = 0
    /// SPEC-419 STEP-2 — fired by an interactive block; carries (blockId, action, value) to the step scope.
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }
    /// SPEC-419 STEP-2 — per-block field_config overrides (from `ElementInteractionResult.fieldConfigPatches`),
    /// folded onto the resolved block at render time.
    var fieldConfigOverrides: [String: [String: Any]] = [:]

    var body: some View {
        let visibleBlocks = blocks.filter { block in
            evaluateVisibilityCondition(
                block.visibility_condition,
                responses: responses,
                hookData: hookData
            )
        }
        // Entrance animation cap: max 10 animated blocks per step
        let animatedBlockIds: Set<String> = {
            var ids = Set<String>()
            for block in visibleBlocks {
                if ids.count >= 10 { break }
                if let anim = block.entrance_animation, anim.type != "none" {
                    ids.insert(block.id)
                }
            }
            return ids
        }()

        VStack(spacing: 12) {
            ForEach(visibleBlocks) { block in
                let shouldAnimate = animatedBlockIds.contains(block.id)
                // SPEC-419 STEP-2 — fold any host-pushed field_config overrides onto the resolved block
                // UNCONDITIONALLY (resolveBlockBindings early-returns raw blocks with no bindings/templates —
                // which is every EPIC-11 element — so the merge cannot live inside it). Empty overrides = no-op.
                let resolvedBlock = resolvedFieldConfig(
                    resolveBlockBindings(block, hookData: hookData, responses: responses),
                    fieldConfigOverrides
                )
                let shouldCollapse = resolvedBlock.collapse_on_scroll == true
                // Collapse threshold: how many points of scroll before this block hides
                let collapseThreshold = CGFloat(
                    (cfgDouble(resolvedBlock.field_config?["collapse_threshold"])) ?? 50
                )
                let collapseProgress = shouldCollapse ? min(max(scrollOffset / collapseThreshold, 0), 1) : 0

                // Input blocks: skip element_height at the wrapper level — it's
                // applied INSIDE each input view (to the field container directly).
                // Otherwise the field stays tiny inside a tall empty wrapper.
                let isInputBlock = resolvedBlock.type.rawValue.hasPrefix("input_")
                let effectiveHeight = isInputBlock ? nil : resolvedBlock.element_height
                let isExpandableBlock = resolvedBlock.type == .input_select

                renderBlock(resolvedBlock, animate: shouldAnimate)
                    .applyRelativeSizing(width: resolvedBlock.element_width, height: effectiveHeight, useMinHeight: isExpandableBlock)
                    .applyBlockContainerStyle(resolvedBlock)
                    // Sprint 7: Scroll-collapse — ONLY applied to blocks with collapse_on_scroll.
                    // .clipped() and .frame(maxHeight:) must NOT touch non-collapsible blocks
                    // because they clip dropdowns, overlays, and overflow content.
                    .if(shouldCollapse) { view in
                        view
                            .opacity(Double(1 - collapseProgress))
                            .frame(maxHeight: collapseProgress >= 1 ? 0 : .infinity)
                            .clipped()
                            .animation(.easeInOut(duration: 0.15), value: collapseProgress >= 1)
                    }
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: ContentBlock, animate: Bool = false) -> some View {
        let content = renderBlockContent(block)
            .applyBlockStyle(block.block_style)
            .applyBlockPosition(
                verticalAlign: block.vertical_align,
                horizontalAlign: block.horizontal_align,
                verticalOffset: block.vertical_offset,
                horizontalOffset: block.horizontal_offset,
                isZoneManaged: isZoneManaged
            )

        if animate, let anim = block.entrance_animation {
            EntranceAnimationWrapper(animation: anim) {
                AnyView(content)
            }
        } else {
            content
        }
    }

    /// AC-064/065/066: Resolves dynamic bindings and template strings on a block.
    /// Returns a new block with resolved text fields and binding overrides.
    private func resolveBlockBindings(_ block: ContentBlock, hookData: [String: Any]?, responses: [String: Any]) -> ContentBlock {
        // `inputValues` is the live map of what the user has typed on THIS step — see the note on
        // `resolveBlockTemplates`' stepInputs parameter for why passing it matters.
        resolveBlockTemplates(block, hookData: hookData, responses: responses, stepInputs: inputValues)
    }

    /// Check if a block contains `{{...}}` template patterns in its text fields.
    private func containsTemplates(_ block: ContentBlock) -> Bool { blockContainsTemplates(block) }

    /// Uses AnyView type erasure to avoid exponential Swift type-checking
    /// on the 45-case switch statement (was causing 30+ min compile times).
    private func renderBlockContent(_ block: ContentBlock) -> AnyView {
        switch block.type {
        case .heading: return AnyView(headingBlock(block))
        case .text: return AnyView(textBlock(block))
        case .image: return AnyView(imageBlock(block))
        case .media_gallery: return AnyView(mediaGalleryBlock(block))
        case .section_background: return AnyView(sectionBackgroundBlock(block))
        case .carousel: return AnyView(CarouselBlockView(block: block, onAction: onAction, toggleValues: $toggleValues, inputValues: $inputValues))
        case .otp_input: return AnyView(OTPInputBlockView(block: block, inputValues: $inputValues, onInteract: onInteract))
        case .warning_banner: return AnyView(warningBannerBlock(block))
        case .password_strength: return AnyView(passwordStrengthBlock(block))
        case .speech_bubble: return AnyView(speechBubbleBlock(block))
        case .feedback_panel: return AnyView(feedbackPanelBlock(block))
        case .summary_screen: return AnyView(summaryScreenBlock(block))
        case .press_hold_confirm: return AnyView(PressHoldConfirmBlockView(block: block, inputValues: $inputValues, onInteract: onInteract))
        case .health_connect: return AnyView(healthConnectBlock(block))
        case .settings_footer: return AnyView(settingsFooterBlock(block))
        case .memory_match: return AnyView(MemoryMatchBlockView(block: block, onInteract: onInteract))
        case .calendar_month: return AnyView(CalendarMonthBlockView(block: block, inputValues: $inputValues, onInteract: onInteract))
        case .button: return AnyView(buttonBlock(block))
        // Mrozu (Duolingo s20/s22) — CTA-style button that plays `audio_url` on tap.
        case .sound_button: return AnyView(soundButtonBlock(block))
        case .spacer: return AnyView(Spacer().frame(height: CGFloat(block.spacer_height ?? 24))) // SPEC-419 pass-14 #11 — unset default 24 to match editor+preview (was 16)
        case .list: return AnyView(listBlock(block))
        case .divider: return AnyView(dividerBlock(block))
        case .badge: return AnyView(badgeBlock(block))
        case .icon: return AnyView(iconBlock(block))
        case .toggle: return AnyView(toggleBlock(block))
        case .video: return AnyView(videoBlock(block))
        case .lottie: return AnyView(lottieBlock(block))
        case .rive: return AnyView(riveBlock(block))
        case .page_indicator: return AnyView(pageIndicatorBlock(block))
        case .wheel_picker: return AnyView(WheelPickerBlockView(block: block, inputValues: $inputValues, onInteract: onInteract))
        case .pulsing_avatar: return AnyView(PulsingAvatarBlockView(block: block))
        case .social_login: return AnyView(socialLoginBlock(block))
        case .timeline: return AnyView(timelineBlock(block))
        case .animated_loading: return AnyView(AnimatedLoadingBlockView(block: block, onAction: onAction))
        case .star_background: return AnyView(StarBackgroundBlockView(block: block))
        case .countdown_timer: return AnyView(CountdownTimerBlockView(block: block, onAction: onAction))
        case .rating: return AnyView(RatingBlockView(block: block, onAction: onAction))
        case .rich_text: return AnyView(richTextBlock(block))
        case .progress_bar: return AnyView(progressBarBlock(block))
        case .stack: return AnyView(stackBlock(block))
        case .custom_view: return AnyView(customViewBlock(block))
        case .map: return AnyView(mapBlock(block))
        case .date_wheel_picker: return AnyView(DateWheelPickerBlockView(block: block, inputValues: $inputValues))
        case .circular_gauge: return AnyView(CircularGaugeBlockView(block: block))
        case .row: return AnyView(rowBlock(block))
        case .pricing_card: return AnyView(PricingCardBlockView(block: block, onAction: onAction, inputValues: $inputValues))
        case .input_text: return AnyView(FormInputTextBlock(block: block, inputValues: $inputValues, keyboardType: .default))
        case .input_textarea: return AnyView(FormInputTextAreaBlock(block: block, inputValues: $inputValues))
        case .input_number: return AnyView(FormInputTextBlock(block: block, inputValues: $inputValues, keyboardType: .numberPad))
        case .input_email: return AnyView(FormInputTextBlock(block: block, inputValues: $inputValues, keyboardType: .emailAddress))
        case .input_phone: return AnyView(FormInputTextBlock(block: block, inputValues: $inputValues, keyboardType: .phonePad))
        case .input_url: return AnyView(FormInputTextBlock(block: block, inputValues: $inputValues, keyboardType: .URL))
        case .input_password: return AnyView(FormInputPasswordBlock(block: block, inputValues: $inputValues))
        case .input_date: return AnyView(FormInputDateBlock(block: block, inputValues: $inputValues, components: .date))
        case .input_time: return AnyView(FormInputDateBlock(block: block, inputValues: $inputValues, components: .hourAndMinute))
        case .input_datetime: return AnyView(FormInputDateBlock(block: block, inputValues: $inputValues, components: [.date, .hourAndMinute]))
        case .input_select: return AnyView(FormInputSelectBlock(block: block, inputValues: $inputValues))
        case .input_slider: return AnyView(FormInputSliderBlock(block: block, inputValues: $inputValues))
        case .input_toggle: return AnyView(FormInputToggleBlock(block: block, inputValues: $inputValues))
        case .input_stepper: return AnyView(FormInputStepperBlock(block: block, inputValues: $inputValues))
        case .input_segmented: return AnyView(FormInputSegmentedBlock(block: block, inputValues: $inputValues))
        case .input_rating: return AnyView(FormInputRatingBlock(block: block, inputValues: $inputValues))
        case .input_range_slider: return AnyView(FormInputRangeSliderBlock(block: block, inputValues: $inputValues))
        case .input_chips: return AnyView(FormInputChipsBlock(block: block, inputValues: $inputValues))
        case .input_location: return AnyView(FormInputLocationPlaceholderBlock(block: block, inputValues: $inputValues))
        case .input_image_picker: return AnyView(FormInputImagePickerPlaceholderBlock(block: block, inputValues: $inputValues))
        case .input_color: return AnyView(FormInputColorBlock(block: block, inputValues: $inputValues))
        case .input_signature: return AnyView(FormInputSignatureBlock(block: block, inputValues: $inputValues))
        // Mrozu QA (2026-08-04, Flo s1) — standalone consent/agreement (checkbox + rich links → Bool).
        case .agreement: return AnyView(AgreementBlock(block: block, inputValues: $inputValues))
        case .unknown: return AnyView(EmptyView())
        }
    }

    // MARK: - Stub Placeholder (SPEC-089d)

    /// Placeholder view for new block types whose full renderers are not yet implemented.
    /// Renders a subtle label in DEBUG builds; EmptyView in release builds.
    @ViewBuilder
    private func stubBlockPlaceholder(_ typeName: String) -> some View {
        #if DEBUG
        Text("[\(typeName)]")
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
        #else
        EmptyView()
        #endif
    }

    // MARK: - Heading

    private func headingBlock(_ block: ContentBlock) -> some View {
        let fallbackSize: CGFloat = {
            switch block.level ?? 1 {
            case 1: return 28
            case 2: return 22
            case 3: return 18
            default: return 28
            }
        }()

        let text = block.text ?? ""
        // EPIC-9 parity fix — honor style.alignment (what the console sets + Android reads via effectiveStyle)
        // first, then fall back to the top-level horizontal_align. Was: read horizontal_align only → a heading
        // authored with style.alignment:center rendered CENTER on Android but LEFT on iOS.
        let alignSource = block.style?.alignment ?? block.horizontal_align
        let textAlignment: TextAlignment = {
            switch alignSource {
            case "center": return .center
            case "right", "trailing": return .trailing
            default: return .leading
            }
        }()
        let frameAlignment: Alignment = {
            switch alignSource {
            case "center": return .center
            case "right", "trailing": return .trailing
            default: return .leading
            }
        }()
        // IMPORTANT: apply the resolved font DIRECTLY on `Text(...)` so SwiftUI
        // treats it as the Text-specific .font() overload (which wins over any
        // ambient .font() env modifier from parent containers and over the
        // env .font() applied later by `.applyTextStyle`). Previously we
        // chained `.font(.system(...)).applyTextStyle(block.style)` — but
        // applyTextStyle is `extension View` so its inner `.font(font)` uses
        // the View env-modifier overload, which does NOT override the direct
        // `.font()` already baked into the Text. Result: author-set font_size
        // and font_weight were silently ignored in nested rows (q4.png).
        let styleFont = FontResolver.font(
            family: block.style?.font_family,
            size: block.style?.font_size ?? Double(fallbackSize),
            weight: block.style?.font_weight ?? 700
        )
        let styleColor: Color = (block.style?.color).map { Color(hex: $0) } ?? .primary
        return Text(loc?("block.\(block.id).text", text) ?? text)
            .font(styleFont)
            .foregroundColor(styleColor)
            .applyTextStyleDecorations(block.style)
            .multilineTextAlignment(textAlignment)
            // SPEC — honor max_lines on heading/text (only rich_text did before);
            // nil → no limit (unchanged). Parity with Android maxLines.
            .lineLimit(block.max_lines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    // MARK: - Text

    // Mrozu QA — trailing animated ellipsis ("", ".", "..", "...") for loading-style text
    // (text block with field_config.show_trailing_dots). Parity with Android AnimatedTrailingDots
    // + console preview's pulsing-dots span.
    private struct AnimatedTrailingDots: View {
        let font: Font
        let color: Color
        var body: some View {
            TimelineView(.animation(minimumInterval: 0.4, paused: false)) { timeline in
                let n = Int(timeline.date.timeIntervalSinceReferenceDate / 0.4) % 4
                // Reserve the full "..." width so the baseline text does not shift as dots cycle.
                Text(String(repeating: ".", count: n))
                    .font(font)
                    .foregroundColor(color)
                    .frame(minWidth: 14, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func textBlock(_ block: ContentBlock) -> some View {
        let text = block.text ?? ""
        // EPIC-9 parity fix — honor style.alignment (what the console sets + Android reads via effectiveStyle)
        // first, then fall back to the top-level horizontal_align. Was: read horizontal_align only → a heading
        // authored with style.alignment:center rendered CENTER on Android but LEFT on iOS.
        let alignSource = block.style?.alignment ?? block.horizontal_align
        let textAlignment: TextAlignment = {
            switch alignSource {
            case "center": return .center
            case "right", "trailing": return .trailing
            default: return .leading
            }
        }()
        let frameAlignment: Alignment = {
            switch alignSource {
            case "center": return .center
            case "right", "trailing": return .trailing
            default: return .leading
            }
        }()
        // See headingBlock for the SwiftUI font-precedence rationale — we
        // resolve the font here and apply it directly on Text(...).
        let styleFont = FontResolver.font(
            family: block.style?.font_family,
            size: block.style?.font_size ?? 16,
            weight: block.style?.font_weight ?? 400
        )
        let styleColor: Color = (block.style?.color).map { Color(hex: $0) } ?? .primary
        let showTrailingDots = (block.field_config?["show_trailing_dots"]?.value as? Bool) ?? false
        let base = Text(loc?("block.\(block.id).text", text) ?? text)
            .font(styleFont)
            .foregroundColor(styleColor)
            .applyTextStyleDecorations(block.style)
            .multilineTextAlignment(textAlignment)
            // SPEC — honor max_lines on heading/text (only rich_text did before);
            // nil → no limit (unchanged). Parity with Android maxLines.
            .lineLimit(block.max_lines)
            .fixedSize(horizontal: false, vertical: true)
        if showTrailingDots {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                base
                AnimatedTrailingDots(font: styleFont, color: styleColor)
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        } else {
            base
                .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }

    // MARK: - Image

    // EPIC-4b — section_background: vertical proportional color zones painted behind overlaid content.
    // Zones + arrangement come through field_config (parity with Android, which is at the JVM arg limit).
    @ViewBuilder
    private func sectionBackgroundBlock(_ block: ContentBlock) -> some View {
        let zonesRaw = (block.field_config?["background_zones"]?.value as? [Any]) ?? []
        let zones: [(CGFloat, Color)] = zonesRaw.compactMap { item in
            guard let m = item as? [String: Any] else { return nil }
            let w = max((m["weight"] as? Double) ?? Double((m["weight"] as? Int) ?? 1), 0.01) // clamp ≥0.01 — a 0-weight zone renders a hairline sliver like Android (coerceAtLeast 0.01) + preview (Compose weight() can't be 0)
            return (CGFloat(w), Color(hex: (m["color"] as? String) ?? "#000000"))
        }
        let totalW = max(zones.reduce(0) { $0 + $1.0 }, 0.0001)
        let children = block.children ?? block.stack_children ?? []
        let arrangement = (block.field_config?["content_arrangement"]?.value as? String) ?? "space_between"
        // EPIC-4b v2 — background_extent (% of screen height, 1–100) lets the section fill the screen
        // or reach a configured % from the top. When absent, fall back to the fixed height (parity with
        // Android SectionBackgroundBlock + the console preview). Screen-relative height mirrors the
        // `UIScreen.main.bounds.height * fraction` pattern already used in ContentBlockTypes.swift.
        let extentPct: Double? = (block.field_config?["background_extent"]?.value as? Double)
            ?? (block.field_config?["background_extent"]?.value as? Int).map(Double.init)
        let height: CGFloat = {
            if let pct = extentPct { return UIScreen.main.bounds.height * CGFloat(min(max(pct, 1), 100)) / 100 }
            return CGFloat(block.height ?? 480)
        }()
        ZStack {
            // Background: vertical weighted color zones.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                        zone.1.frame(maxWidth: .infinity).frame(height: geo.size.height * zone.0 / totalW)
                    }
                }
            }
            // Foreground: content overlaid on the zones.
            VStack(spacing: 12) {
                if arrangement == "center" || arrangement == "bottom" { Spacer() }
                ForEach(Array(children.enumerated()), id: \.offset) { idx, child in
                    if arrangement == "space_between" && idx > 0 { Spacer() }
                    renderBlock(child)
                }
                if arrangement == "center" || arrangement == "top" { Spacer() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    // EPIC-3 — media_gallery: horizontal scrollable row of image tiles (rounded, fixed size, placeholder bg).
    // Media-gallery v2 (Mrozu QA): gallery_fill = full-width edge-to-edge cover tiles; gallery_autoscroll =
    // seamless marquee loop (gallery_autoscroll_speed = seconds per full cycle, default 20). Both default
    // off → identical to the existing static tile row (no timer/animation cost when off — non-breaking).
    @ViewBuilder
    private func mediaGalleryBlock(_ block: ContentBlock) -> some View {
        let images = block.gallery_images ?? []
        let itemW = CGFloat(block.gallery_item_width ?? 140)
        let itemH = CGFloat(block.gallery_item_height ?? 180)
        let cr = CGFloat(block.gallery_corner_radius ?? 12)
        let spacing = CGFloat(block.gallery_spacing ?? 10)
        let fill = block.gallery_fill ?? false
        let autoscroll = block.gallery_autoscroll ?? false
        let cycle = block.gallery_autoscroll_speed ?? 20
        // Mrozu QA (2026-08-04) — alarmy selectable gallery: gallery_preview_on_select opens a full-screen
        // enlarged overlay of the tapped image. Default off → the existing static/marquee row (non-breaking).
        // Image preview only — video/gif/sound preview playback is net-new host media infra (deferred).
        let previewOnSelect = (block.field_config?["gallery_preview_on_select"]?.value as? Bool) ?? false
        let galleryAlignment: Alignment = block.gallery_align == "start" ? .leading : (block.gallery_align == "end" ? .trailing : .center)
        if images.isEmpty {
            // Parity with Android (ContentBlockRenderer.kt:1841 `if (images.isEmpty()) return`) and
            // preview: a cleared gallery renders nothing rather than reserving a blank itemH-tall gap.
            EmptyView()
        } else if autoscroll {
            MediaGalleryAutoScrollRow(images: images, itemW: itemW, itemH: itemH, cornerRadius: cr, spacing: spacing, fill: fill, cycleSeconds: cycle)
        } else if previewOnSelect {
            MediaGalleryPreviewRow(images: images, itemW: itemW, itemH: itemH, cornerRadius: cr, spacing: spacing, fill: fill, galleryAlignment: galleryAlignment)
        } else {
            GeometryReader { geo in
                let tileW = fill ? geo.size.width : itemW
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: fill ? 0 : spacing) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, urlString in
                            mediaGalleryTile(urlString, width: tileW, height: itemH, cornerRadius: fill ? 0 : cr)
                        }
                    }
                    .padding(.horizontal, fill ? 0 : 2)
                    // EPIC-3 — settable align (start/center/end) when tiles fit; scrolls when they overflow.
                    .frame(minWidth: geo.size.width, alignment: fill ? .leading : galleryAlignment)
                }
            }
            .frame(height: itemH)
        }
    }

    // Media-gallery v2 — shared tile builder (placeholder bg + cover image, rounded/clipped).
    @ViewBuilder
    private func mediaGalleryTile(_ urlString: String, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            Color(hex: "#2A2A2E")
            if let url = URL(string: urlString) {
                BundledAsyncPhaseImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// SPEC-419 — shared image styling: image_fit (cover/contain/fill/none), aspect_ratio,
    /// and image_position alignment. Mirrors the console preview + Android ImageBlock.
    @ViewBuilder
    private func styledImage(_ image: Image, fit: String, aspect: CGFloat?, maxHeight: CGFloat, alignment: Alignment) -> some View {
        let fitMode: ContentMode = (fit == "contain" || fit == "fit") ? .fit : .fill
        if fit == "none" {
            // No resize — intrinsic pixels; objectFit: none. aspect_ratio (when set) still
            // constrains the FRAME ratio independently of fit — Android/preview apply the ratio
            // frame regardless of image_fit, so a 1:1 ratio is honored even with fit=none.
            if let aspect {
                image
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: maxHeight, alignment: alignment)
            } else {
                image
                    .frame(maxHeight: maxHeight, alignment: alignment)
            }
        } else if fit == "fill" {
            // True stretch — fill BOTH dimensions ignoring the image's own ratio (objectFit: fill /
            // Android ContentScale.FillBounds). When aspect_ratio is set the FRAME takes that ratio
            // and the resizable image stretches to fill it; otherwise stretch to width × maxHeight.
            if let aspect {
                image.resizable()
                    .aspectRatio(aspect, contentMode: fitMode)
                    .frame(maxHeight: maxHeight, alignment: alignment)
            } else {
                image.resizable()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: alignment)
            }
        } else if let aspect {
            image.resizable()
                .aspectRatio(aspect, contentMode: fitMode)
                .frame(maxHeight: maxHeight, alignment: alignment)
        } else {
            image.resizable()
                .aspectRatio(contentMode: fitMode)
                .frame(maxHeight: maxHeight, alignment: alignment)
        }
    }

    private func imageBlock(_ block: ContentBlock) -> some View {
        let cr = CGFloat(block.corner_radius ?? 0)
        let isCircle = (block.corner_radius ?? 0) >= 9999
        let imgHeight = CGFloat(block.height ?? 200)
        // SPEC-419 — image_fit. Match preview objectFit values + Android ContentScale:
        // contain/fit → .fit; fill → .fill (stretch-fill); none → no resize (intrinsic); else cover → .fill.
        let imageFit = block.image_fit ?? "cover"
        // SPEC-419 (P2) — aspect_ratio routed through field_config (JVM-255 budget); preview applies it too.
        let aspectRatioValue: CGFloat? = {
            switch block.field_config?["aspect_ratio"]?.value as? String {
            case "16:9": return 16.0 / 9.0
            case "4:3": return 4.0 / 3.0
            case "1:1": return 1.0
            case "3:4": return 3.0 / 4.0
            case "9:16": return 9.0 / 16.0
            default: return nil
            }
        }()
        // SPEC-419 (P3) — image_position top/bottom routed through field_config; preview uses objectPosition.
        let positionAlignment: Alignment = {
            switch block.field_config?["image_position"]?.value as? String {
            case "top": return .top
            case "bottom": return .bottom
            default: return .center
            }
        }()

        return Group {
            if block.image_frame == "phone" || block.image_frame == "phone_thin",
               let urlString = block.image_url, let url = URL(string: urlString) {
                phoneMockup(url: url, height: imgHeight, alt: block.alt, thin: block.image_frame == "phone_thin")
            } else if block.image_frame == "glow" || block.image_frame == "color_frame",
                      let urlString = block.image_url, let url = URL(string: urlString) {
                // #581 — effects on the plain image rather than mockups. Settings come from
                // `field_config`: ContentBlock sits at the JVM 255-argument ceiling, so a new
                // top-level field would compile and then die at runtime with a bare ClassFormatError.
                let isGlow = block.image_frame == "glow"
                let glowColor = Color(hex: (block.field_config?["frame_glow_color"]?.value as? String) ?? "#6366F1")
                let frameColor = Color(hex: (block.field_config?["frame_color"]?.value as? String) ?? "#374151")
                // Authored numbers arrive as Int or Double depending on how the console serialised
                // them, so both are read — a Double-only cast silently falls back to the default.
                let frameRadius: CGFloat = {
                    if let d = block.field_config?["frame_corner_radius"]?.value as? Double { return CGFloat(d) }
                    if let i = block.field_config?["frame_corner_radius"]?.value as? Int { return CGFloat(i) }
                    return 16
                }()
                // 🔴 The frame and the glow wrap the WHOLE phase view, not just `.success`.
                //
                // Nested inside the success case they vanished whenever the image was slow or
                // failed: an author sets an amber frame, the image 404s, and the frame is gone too
                // — leaving a bare placeholder that looks like the setting did nothing. Android
                // already decorated the container rather than the loaded image, so this was also a
                // silent divergence between the two.
                BundledAsyncPhaseImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        styledImage(image, fit: imageFit, aspect: aspectRatioValue, maxHeight: imgHeight, alignment: positionAlignment)
                            .clipShape(RoundedRectangle(cornerRadius: isGlow ? cr : max(0, frameRadius - 6)))
                            .accessibilityLabel(block.alt ?? "Image")
                    default:
                        imagePlaceholder
                            .clipShape(RoundedRectangle(cornerRadius: isGlow ? cr : max(0, frameRadius - 6)))
                    }
                }
                .padding(isGlow ? 0 : 6)
                .background(
                    RoundedRectangle(cornerRadius: isGlow ? cr : frameRadius)
                        .fill(isGlow ? Color.clear : frameColor)
                )
                // A coloured bloom BEHIND the image, not a border — "color added on the bg to make
                // it glowing" is a shadow, and a border is the other option this dropdown offers.
                .shadow(color: isGlow ? glowColor : .clear, radius: 16)
            } else if let urlString = block.image_url, let url = URL(string: urlString) {
                BundledAsyncPhaseImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        // SPEC-419 pass-15 #24 — honor overflow="visible" (no clip), matching Android + preview.
                        if block.overflow == "visible" {
                            styledImage(image, fit: imageFit, aspect: aspectRatioValue, maxHeight: imgHeight, alignment: positionAlignment)
                                .accessibilityLabel(block.alt ?? "Image")
                        } else if isCircle {
                            styledImage(image, fit: imageFit, aspect: aspectRatioValue, maxHeight: imgHeight, alignment: positionAlignment)
                                .clipShape(Circle())
                                .accessibilityLabel(block.alt ?? "Image")
                        } else {
                            styledImage(image, fit: imageFit, aspect: aspectRatioValue, maxHeight: imgHeight, alignment: positionAlignment)
                                .clipShape(RoundedRectangle(cornerRadius: cr))
                                .accessibilityLabel(block.alt ?? "Image")
                        }
                    case .failure:
                        imagePlaceholder
                    default:
                        ProgressView().frame(height: CGFloat(block.height ?? 200))
                    }
                }
            } else {
                // No image URL — render nothing (don't show broken placeholder)
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// EPIC-3 — phone mockup: device bezel + dynamic-island notch, image as the "screen".
    /// #581 — `thin: true` is the same mockup with a narrower bezel. One function rather than two,
    /// because everything except the padding and the two radii is identical, and a copy is how the
    /// notch or the width cap ends up different between them.
    private func phoneMockup(url: URL, height: CGFloat, alt: String?, thin: Bool = false) -> some View {
        let pad: CGFloat = thin ? 4 : 10
        let outerR: CGFloat = thin ? 32 : 40
        let innerR: CGFloat = thin ? 28 : 30
        return ZStack(alignment: .top) {
            BundledAsyncPhaseImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(hex: "#2A2A2E")
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: innerR))
            Capsule()
                .fill(Color.black)
                .frame(width: 96, height: 26)
                .padding(.top, 8)
        }
        .padding(pad)
        .background(RoundedRectangle(cornerRadius: outerR).fill(Color(hex: "#101012")))
        .frame(maxWidth: 260)
        .accessibilityLabel(alt ?? "Image")
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .frame(height: 120)
            .overlay(Image(systemName: "photo").foregroundColor(.gray))
    }

    // MARK: - Button (with outline variant — SPEC-089d §3.18)

    private func buttonBlock(_ block: ContentBlock, onTapOverride: (() -> Void)? = nil) -> some View {
        let btnVariant = block.variant ?? "primary"
        let radius = CGFloat(block.button_corner_radius ?? 12)
        // Mrozu QA (2026-08-04) — Flo consent CTA: `cta_enabled_bg_color` / `cta_disabled_bg_color` drive the
        // button background off whether the step's required fields (incl. a consent checkbox) are satisfied.
        // Reuses the SAME RequiredFieldGate the advance gate uses (over `blocks` + live `inputValues`), so the
        // CTA recolors reactively as the user toggles consent. Both nil → plain `bg_color` (non-breaking).
        let bgColor: Color = {
            let enabledHex = block.field_config?["cta_enabled_bg_color"]?.value as? String
            let disabledHex = block.field_config?["cta_disabled_bg_color"]?.value as? String
            let fallback = block.bg_color ?? (AppDNA.brandAccentHex ?? "#6366F1")
            guard enabledHex != nil || disabledHex != nil else { return Color(hex: fallback) }
            let satisfied = RequiredFieldGate.evaluate(blocks: blocks, inputValues: inputValues).canAdvance
            return Color(hex: satisfied ? (enabledHex ?? fallback) : (disabledHex ?? enabledHex ?? fallback))
        }()
        let txtColor = Color(hex: block.text_color ?? "#FFFFFF")
        let labelText = loc?("block.\(block.id).text", block.text ?? "Continue") ?? block.text ?? "Continue"
        let fgColor = btnVariant == "outline" ? bgColor : (btnVariant == "text" ? bgColor : txtColor)

        return Button {
            if let onTapOverride {
                onTapOverride()
            } else {
                onAction(block.action ?? "next", block.action_value)
            }
        } label: {
            // #580 — the icon and its spacing are authored. `sound_icon_gap` defaults to the 8 the
            // button has always used, so a button with no icon settings lays out identically.
            HStack(spacing: CGFloat(numFromConfig(block, "sound_icon_gap") ?? 8)) {
                // Gap 6: icon_emoji
                if let emoji = block.icon_emoji, !emoji.isEmpty {
                    Text(emoji)
                }
                // #580 — an authored icon: a built-in play triangle, or an uploaded image.
                //
                // Defaults to "none". The button has never drawn an icon, so anything else would
                // change the appearance of every sound button already authored — a fix nobody asked
                // for arriving as a surprise on customers' screens.
                soundButtonIcon(block)
                // Gap 6: image_url icon
                if let imageUrl = block.image_url, let url = URL(string: imageUrl) {
                    BundledAsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                    } placeholder: {
                        EmptyView()
                    }
                }
                // #594 — the button-specific `text_color` beats the generic Typography colour.
                // 
                // It was the other way round: `block.style.color` was applied last and silently won, so the "Text"
                // picker sitting right beside "Background" did nothing whenever a Typography colour was also set —
                // "only the separate Color setting works", exactly as reported.
                // 
                // Specificity decides, the same rule used everywhere else here (a per-plan price colour beats the
                // section's price style). Only an EXPLICITLY set `text_color` wins; unset leaves Typography in
                // charge, so a flow that styles its buttons through Typography alone is untouched.
                // 
                // ⚠️ A flow with BOTH set changes appearance — it now shows the button's own colour instead of the
                // typography one. That is the point of the fix, and it is why the override is gated on the field
                // being set rather than on its non-nil default.
                //
                // `applyTextStyle` BAKES a colour into the Text when the style sets one, so a later
                // `.foregroundColor` on the wrapping stack is a no-op — the override has to be
                // applied to the Text itself, after the style.
                // 🔴 Applied CONDITIONALLY. `.foregroundColor(nil)` does not mean "inherit" in
                // SwiftUI — it RESETS to the default foreground, which would override the
                // `fgColor` the enclosing stack sets for every button that never authored a
                // `text_color`. A nil-passing version of this shipped briefly and changed three
                // goldens on CI while rendering identically on a Mac, because the default it reset
                // to follows the system appearance.
                if let hex = block.text_color, !hex.isEmpty {
                    Text(labelText)
                        .font(.body.weight(.semibold))
                        .applyTextStyle(block.style)
                        .foregroundColor(Color(hex: hex))
                } else {
                    Text(labelText)
                        .font(.body.weight(.semibold))
                        .applyTextStyle(block.style)
                }
            }
            .foregroundColor(fgColor)
            // EPIC-6 — apply authored button_height (resize the button) instead of only intrinsic padding.
            .padding(.vertical, block.button_height == nil ? 14 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: block.button_height.map { CGFloat($0) })
            .background(buttonBackground(block: block, btnVariant: btnVariant, bgColor: bgColor))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                btnVariant == "outline"
                    ? RoundedRectangle(cornerRadius: radius).stroke(bgColor, lineWidth: 1.5)
                    : nil
            )
        }
        .applyPressedStyle(block.pressed_style)
    }

    // MARK: - Sound Button (Mrozu Duolingo s20/s22)

    /// A CTA-style button that plays an uploaded/remote audio clip (mp3/wav/aac)
    /// from `block.audio_url` on tap — reuses ALL button styling fields via
    /// `buttonBlock`. When `block.autoplay == true`, the clip plays as the block
    /// appears. Playback is routed through the shared `AudioPlayer` helper.
    /// A number out of `field_config`, tolerating Int or Double — the console serialises either.
    private func numFromConfig(_ block: ContentBlock, _ key: String) -> Double? {
        if let d = block.field_config?[key]?.value as? Double { return d }
        if let i = block.field_config?[key]?.value as? Int { return Double(i) }
        return nil
    }

    /// #580 — the Sound Button's icon. Authored source, size, colour and spacing.
    @ViewBuilder
    private func soundButtonIcon(_ block: ContentBlock) -> some View {
        let kind = (block.field_config?["sound_icon"]?.value as? String) ?? "none"
        let size = CGFloat(numFromConfig(block, "sound_icon_size") ?? 18)
        let tint = Color(hex: (block.field_config?["sound_icon_color"]?.value as? String) ?? "#FFFFFF")
        if kind == "play" {
            // The built-in fallback the issue asks for: a filled triangle, tinted.
            Image(systemName: "play.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(tint)
        } else if kind == "custom",
                  let raw = block.field_config?["sound_icon_url"]?.value as? String,
                  !raw.isEmpty, let url = URL(string: raw) {
            BundledAsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
            } placeholder: {
                EmptyView()
            }
        }
    }

    private func soundButtonBlock(_ block: ContentBlock) -> some View {
        buttonBlock(block, onTapOverride: {
            AudioPlayer.shared.play(urlString: block.audio_url)
        })
        .onAppear {
            if block.autoplay == true {
                AudioPlayer.shared.play(urlString: block.audio_url)
            }
        }
        // Stop playback + release the AVAudioSession when the block leaves the
        // hierarchy (step change / dismiss); otherwise autoplayed audio keeps
        // playing after the user navigates away.
        .onDisappear {
            AudioPlayer.shared.stop()
        }
    }

    /// Gap 5: Button background — gradient or solid color.
    @ViewBuilder
    private func buttonBackground(block: ContentBlock, btnVariant: String, bgColor: Color) -> some View {
        if btnVariant == "outline" || btnVariant == "text" {
            Color.clear
        } else if let grad = block.block_style?.background_gradient {
            LinearGradient(
                colors: [Color(hex: grad.start ?? "#000000"), Color(hex: grad.end ?? "#FFFFFF")],
                startPoint: gradientStartPointForButton(angle: grad.angle ?? 0),
                endPoint: gradientEndPointForButton(angle: grad.angle ?? 0)
            )
        } else {
            bgColor
        }
    }

    private func gradientStartPointForButton(angle: Double) -> UnitPoint {
        let rads = angle * .pi / 180
        return UnitPoint(x: 0.5 - sin(rads) / 2, y: 0.5 + cos(rads) / 2)
    }

    private func gradientEndPointForButton(angle: Double) -> UnitPoint {
        let rads = angle * .pi / 180
        return UnitPoint(x: 0.5 + sin(rads) / 2, y: 0.5 - cos(rads) / 2)
    }

    // EPIC-11 — warning/info banner: tinted rounded card + leading icon + message. Parity with Android.
    private func warningBannerBlock(_ block: ContentBlock) -> some View {
        let variant = (block.field_config?["banner_variant"]?.value as? String) ?? "warning"
        let accentHex: String
        let defaultIcon: String
        switch variant {
        case "error": accentHex = "#EF4444"; defaultIcon = "⛔"
        case "info": accentHex = "#3B82F6"; defaultIcon = "ℹ️"
        case "success": accentHex = "#10B981"; defaultIcon = "✓"
        default: accentHex = "#F59E0B"; defaultIcon = "⚠️"
        }
        let accent = Color(hex: block.active_color ?? accentHex)
        let icon = (block.field_config?["banner_icon"]?.value as? String) ?? defaultIcon
        let text = loc?("block.\(block.id).text", block.text ?? "") ?? block.text ?? ""
        // Mrozu QA (2026-08-04): bg_color/text_color were uneditable. When set they override the
        // accent-tinted background / white message text; unset keeps the variant defaults (parity w/ Android).
        let bgOverride = block.bg_color.map { Color(hex: $0) }
        let textColor = Color(hex: block.text_color ?? "#FFFFFF")
        return HStack(spacing: 10) {
            Text(icon).font(.system(size: 18))
            Text(text).font(.system(size: 14, weight: .medium)).foregroundColor(textColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgOverride ?? accent.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.45), lineWidth: 1))
    }

    // EPIC-11 — password-strength meter: 4 segment bars + label, red→amber→yellow→green ramp. Parity w/ Android.
    private func passwordStrengthBlock(_ block: ContentBlock) -> some View {
        let rawLevel = (block.field_config?["strength_level"]?.value as? Int)
            ?? cfgDouble(block.field_config?["strength_level"]).map { Int($0) } ?? 0
        let level = min(max(rawLevel, 0), 4)
        let colorHex: String
        let defLabel: String
        switch level {
        case 1: colorHex = "#EF4444"; defLabel = "Weak"
        case 2: colorHex = "#F59E0B"; defLabel = "Fair"
        case 3: colorHex = "#EAB308"; defLabel = "Good"
        case 4: colorHex = "#10B981"; defLabel = "Strong"
        default: colorHex = "#6B7280"; defLabel = ""
        }
        let accent = Color(hex: block.active_color ?? colorHex)
        let label = (block.field_config?["strength_label"]?.value as? String) ?? defLabel
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i < level ? accent : Color(hex: "#374151"))
                        .frame(height: 6)
                }
            }
            if !label.isEmpty {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // EPIC-11 — speech bubble (mascot dialogue): rounded card + downward tail triangle. Parity with Android.
    private func speechBubbleBlock(_ block: ContentBlock) -> some View {
        let bubbleColor = Color(hex: block.bg_color ?? "#FFFFFF")
        let textColor = Color(hex: block.text_color ?? "#111827")
        let tailPos = (block.field_config?["bubble_tail"]?.value as? String) ?? "left"
        // Mrozu QA — bubble interior font family (bubble_font_family; nil → system) + tail geometry
        // (tail_width/tail_length; default 18×9). Parity w/ Android SpeechBubbleBlock + console preview.
        let bubbleFont = FontResolver.font(
            family: block.field_config?["bubble_font_family"]?.value as? String,
            size: 15, weight: 500)
        let tailWidth = CGFloat(cfgDouble(block.field_config?["tail_width"]) ?? 18)
        let tailLength = CGFloat(cfgDouble(block.field_config?["tail_length"]) ?? 9)
        let text = loc?("block.\(block.id).text", block.text ?? "") ?? block.text ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(bubbleFont)
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 0) {
                if tailPos == "left" { Spacer().frame(width: 24) }
                if tailPos == "center" || tailPos == "right" { Spacer() }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: tailWidth, y: 0))
                    p.addLine(to: CGPoint(x: tailWidth / 2, y: tailLength))
                    p.closeSubpath()
                }
                .fill(bubbleColor)
                .frame(width: tailWidth, height: tailLength)
                if tailPos == "right" { Spacer().frame(width: 24) }
                if tailPos == "center" || tailPos == "left" { Spacer() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // EPIC-11 — quiz feedback panel (Duolingo correct/wrong): tinted panel + circled icon + headline + detail.
    private func feedbackPanelBlock(_ block: ContentBlock) -> some View {
        let state = (block.field_config?["feedback_state"]?.value as? String) ?? "correct"
        let accentHex: String
        let icon: String
        let defHead: String
        switch state {
        case "wrong": accentHex = "#EF4444"; icon = "✗"; defHead = "Not quite"
        case "info": accentHex = "#3B82F6"; icon = "ℹ"; defHead = "Heads up"
        default: accentHex = "#10B981"; icon = "✓"; defHead = "Great job!"
        }
        let accent = Color(hex: block.active_color ?? accentHex)
        // Mrozu QA (2026-08-04) — duolingo above-CTA feedback: `feedback_bg_color` overrides the tinted
        // panel background; `feedback_graphic_url` swaps the built-in ✓/✗ glyph for a custom image. Both
        // default nil → identical to the existing accent-tinted glyph panel (non-breaking). The runtime
        // correct/wrong EVENT that flips `feedback_state` is a host-driven behavioral concern (deferred);
        // this is the static/config render + state-driven styling.
        let panelBg = (block.field_config?["feedback_bg_color"]?.value as? String).map { Color(hex: $0) } ?? accent.opacity(0.15)
        let graphicURL = (block.field_config?["feedback_graphic_url"]?.value as? String).flatMap { URL(string: $0) }
        let headline = loc?("block.\(block.id).text", block.text ?? defHead) ?? block.text ?? defHead
        let detail = block.field_config?["feedback_detail"]?.value as? String
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(accent).frame(width: 40, height: 40)
                if let graphicURL = graphicURL {
                    BundledAsyncImage(url: graphicURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill).frame(width: 40, height: 40).clipShape(Circle())
                    } placeholder: {
                        Text(icon).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                    }
                } else {
                    Text(icon).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 17, weight: .bold)).foregroundColor(accent)
                if let detail = detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 14)).foregroundColor(.white.opacity(0.85))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // EPIC-11 — session summary screen (Duolingo end-of-lesson): optional headline + 2-column stat-card grid.
    /// #593 — stat sizes ride in the same string bag as `min`/`max`/`step`, so they arrive as
    /// strings from the console. Coerced the same way `statDouble` coerces those, with a fallback
    /// rather than a zero-size font on anything unparseable.
    private func summaryStatSize(_ stat: [String: Any], _ key: String, _ fallback: CGFloat) -> CGFloat {
        let raw = stat[key]
        if let d = raw as? Double, d > 0 { return CGFloat(d) }
        if let i = raw as? Int, i > 0 { return CGFloat(i) }
        if let s = raw as? String, let d = Double(s), d > 0 { return CGFloat(d) }
        return fallback
    }

    /// A stat's string value by key. Key-as-argument like `statDouble`, so the authorability gate
    /// can see WHICH key is read — a bare subscript on the loop variable tells it nothing.
    private func summaryStatString(_ stat: [String: Any], _ key: String) -> String? {
        stat[key] as? String
    }

    private func summaryStatAlignment(_ stat: [String: Any], _ key: String) -> Alignment {
        switch stat[key] as? String {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private func summaryScreenBlock(_ block: ContentBlock) -> some View {
        let statsRaw = (block.field_config?["summary_stats"]?.value as? [Any]) ?? []
        let stats: [[String: Any]] = statsRaw.compactMap { $0 as? [String: Any] }
        let headline = loc?("block.\(block.id).text", block.text ?? "") ?? block.text ?? ""
        let defaultAccent = AppDNA.brandAccentHex ?? "#6366F1"
        // Mrozu QA (2026-08-04): cards/headline were hardcoded (#1F2937 bg, white text, center, 2-col).
        // bg_color = card bg, text_color = headline + label, summary_align = headline align,
        // stats_layout = horizontal (2-col, default) | vertical (single full-width column). Parity w/ Android.
        let cardBg = Color(hex: block.bg_color ?? "#1F2937")
        // #595 was a CONSOLE defect (the preview's step surface is light by default, so a white
        // headline was invisible there). On DEVICE the default stays #FFFFFF deliberately.
        //
        // 🔴 `.primary` was tried here and reverted: it follows the SYSTEM appearance, not the
        // step's painted background. An onboarding step paints its own background — usually dark —
        // so on a light-mode device `.primary` renders the headline BLACK ON DARK: the same
        // invisibility bug, inverted. It also made three goldens render differently on CI than on
        // a developer's Mac, purely because the two simulators were in different appearance modes,
        // which is how it was caught.
        let textColor = Color(hex: block.text_color ?? "#FFFFFF")
        let headlineColor = textColor
        let alignStr = (block.field_config?["summary_align"]?.value as? String) ?? "center"
        let headlineAlign: Alignment = alignStr == "left" ? .leading : (alignStr == "right" ? .trailing : .center)
        let headlineTextAlign: TextAlignment = alignStr == "left" ? .leading : (alignStr == "right" ? .trailing : .center)
        let perRow = (block.field_config?["stats_layout"]?.value as? String) == "vertical" ? 1 : 2
        let rows: [[[String: Any]]] = stride(from: 0, to: stats.count, by: perRow).map {
            Array(stats[$0..<min($0 + perRow, stats.count)])
        }
        return VStack(spacing: 12) {
            if !headline.isEmpty {
                Text(headline).font(.system(size: 22, weight: .bold)).foregroundColor(headlineColor)
                    .multilineTextAlignment(headlineTextAlign)
                    .frame(maxWidth: .infinity, alignment: headlineAlign)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowStats in
                HStack(spacing: 12) {
                    ForEach(Array(rowStats.enumerated()), id: \.offset) { _, m in
                        // Coerce — a numeric stat value (Int/Double) cast `as? String` would blank the card.
                        let value = (m["value"] as? String) ?? (m["value"]).map { "\($0)" } ?? ""
                        let label = (m["label"] as? String) ?? (m["label"]).map { "\($0)" } ?? ""
                        let color = Color(hex: (m["color"] as? String) ?? defaultAccent)
                        // SPEC-446 §3 — a stat may HOST a control instead of showing a fixed value.
                        // The required-gate half of this shipped without the rendering half, on both
                        // platforms: `RequiredFieldGate` blocks on an unanswered stat input while nothing
                        // ever drew one, so a stat marked required could not be satisfied and the step
                        // could not be advanced at all. A gate for a control that does not exist is worse
                        // than neither.
                        let statInput = (m["input"] as? String) ?? "none"
                        let statFieldId = (m["field_id"] as? String) ?? ""
                        // #593 — the sub-headline's own type. `color` above styles the VALUE; the
                        // label under it had no colour, size or alignment at all, and neither did a
                        // slider/stepper's displayed number — the same text through a different
                        // control. An authored label colour drops the 0.7 opacity with it: an
                        // author who picked a colour meant that colour.
                        let statLabelColor = (summaryStatString(m, "label_color")).flatMap { $0.isEmpty ? nil : Color(hex: $0) }
                            ?? textColor.opacity(0.7)
                        let statLabelSize = summaryStatSize(m, "label_font_size", 13)
                        let statValueSize = summaryStatSize(m, "value_font_size", 24)
                        let statAlign = summaryStatAlignment(m, "align")
                        VStack(alignment: statAlign.horizontal, spacing: 4) {
                            if statInput != "none" && !statFieldId.isEmpty {
                                SummaryStatInput(
                                    stat: m,
                                    fieldId: statFieldId,
                                    valueColor: color,
                                    labelColor: statLabelColor,
                                    labelSize: statLabelSize,
                                    valueSize: statValueSize,
                                    label: label,
                                    inputValues: $inputValues,
                                    onInteract: onInteract,
                                    blockId: block.id,
                                )
                            } else {
                                Text(value).font(.system(size: statValueSize, weight: .bold)).foregroundColor(color)
                                Text(label).font(.system(size: statLabelSize)).foregroundColor(statLabelColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: statAlign)
                        .padding(16)
                        .background(cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if perRow == 2 && rowStats.count == 1 { Spacer().frame(maxWidth: .infinity) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // EPIC-11 — Health/HealthKit connect: a tappable card (icon + title + subtitle + chevron/✓). Native connect
    // flow is host-driven via onAction("health_connect"). Parity with Android.
    private func healthConnectBlock(_ block: ContentBlock) -> some View {
        // EPIC-11 — provider is PLATFORM-FIXED: iOS always shows Apple Health (Google Fit is Android-only).
        let connected = (block.field_config?["connected"]?.value as? Bool) ?? false
        let icon = "❤️"
        let defLabel = "Connect Apple Health"
        let iconBgHex = "#FF2D55"
        let label = loc?("block.\(block.id).text", block.text ?? defLabel) ?? block.text ?? defLabel
        let subtitle = (block.field_config?["health_subtitle"]?.value as? String) ?? "Sync steps, workouts & vitals"
        return Button {
            onAction("health_connect", nil)
            // SPEC-419 STEP-2 — provider is platform-fixed on iOS (Apple Health).
            onInteract(block.id, "health_connect", "apple_health")
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color(hex: iconBgHex).opacity(0.18)).frame(width: 44, height: 44)
                    Text(icon).font(.system(size: 22))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                if connected {
                    Text("✓").font(.system(size: 20, weight: .bold)).foregroundColor(Color(hex: "#10B981"))
                } else {
                    Text("›").font(.system(size: 26)).foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "#1F2937"))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // EPIC-11 — interactive footer: dark-mode capsule toggle + language switcher pill. Custom capsule switch
    // (not the native widget) so both platforms pixel-match. Parity with Android.
    private func settingsFooterBlock(_ block: ContentBlock) -> some View {
        let darkMode = (block.field_config?["dark_mode"]?.value as? Bool) ?? false
        let language = (block.field_config?["language"]?.value as? String) ?? "English"
        let accent = Color(hex: block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        return HStack {
            HStack(spacing: 10) {
                Text("🌙").font(.system(size: 18))
                Button {
                    onAction("toggle_dark_mode", nil)
                    onInteract(block.id, "toggle_dark_mode", String(!darkMode))
                } label: {
                    ZStack(alignment: darkMode ? .trailing : .leading) {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(darkMode ? accent : Color.white.opacity(0.22))
                            .frame(width: 46, height: 28)
                        Circle().fill(Color.white).frame(width: 22, height: 22).padding(3)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                onAction("switch_language", nil)
                onInteract(block.id, "switch_language", language)
            } label: {
                HStack(spacing: 7) {
                    Text("🌐").font(.system(size: 15))
                    Text(language).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                    Text("▾").font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(hex: "#1F2937"))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - List

    private func listBlock(_ block: ContentBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                HStack(spacing: 10) {
                    listMarker(style: block.list_style ?? "bullet", index: index, checkColor: block.check_color)
                    // SPEC-084 Gap #9: localize each list item using block id + index key
                    Text(loc?("block.\(block.id).item.\(index)", item) ?? item)
                        .applyTextStyle(block.style)
                }
            }
        }
    }

    private func listMarker(style: String, index: Int, checkColor: String? = nil) -> AnyView {
        switch style {
        case "numbered":
            return AnyView(Text("\(index + 1).")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary))
        case "check":
            // SPEC-419 pass-15 #5 — honor authored check_color (editor default green #22C55E); was hardcoded brandAccent.
            return AnyView(Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundColor(Color(hex: checkColor ?? "#22C55E")))
        default:
            return AnyView(Circle()
                .fill(Color.primary.opacity(0.5))
                .frame(width: 6, height: 6))
        }
    }

    // MARK: - Divider

    private func dividerBlock(_ block: ContentBlock) -> some View {
        Rectangle()
            .fill(Color(hex: block.divider_color ?? "#E5E7EB"))
            .frame(height: CGFloat(block.divider_thickness ?? 1))
            .padding(.vertical, CGFloat(block.divider_margin_y ?? 16)) // SPEC-419 pass-14 #12 — unset default 16 to match editor+preview (was 8)
    }

    // MARK: - Badge

    private func badgeBlock(_ block: ContentBlock) -> some View {
        Text(loc?("block.\(block.id).badge", block.badge_text ?? "") ?? block.badge_text ?? "")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(hex: block.badge_bg_color ?? (AppDNA.brandAccentHex ?? "#6366F1")))
            .foregroundColor(Color(hex: block.badge_text_color ?? "#FFFFFF"))
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(block.badge_corner_radius ?? 999)))
    }

    // MARK: - Icon

    private func iconBlock(_ block: ContentBlock) -> some View {
        let alignment: Alignment = {
            switch block.icon_alignment {
            case "left": return .leading
            case "right": return .trailing
            default: return .center
            }
        }()

        return Group {
            // SPEC-085: Support IconReference (structured icon) or plain emoji string
            if let iconRef = block.icon_ref {
                IconView(ref: iconRef, size: CGFloat(block.icon_size ?? 32))
            } else {
                Text(block.icon_emoji ?? "")
                    .font(.system(size: CGFloat(block.icon_size ?? 32)))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    // MARK: - Toggle

    private func toggleBlock(_ block: ContentBlock) -> some View {
        let binding = Binding<Bool>(
            get: { toggleValues[block.id] ?? (block.toggle_default ?? false) },
            set: { toggleValues[block.id] = $0 }
        )

        return VStack(alignment: .leading, spacing: 4) {
            Toggle(loc?("block.\(block.id).label", block.toggle_label ?? "") ?? block.toggle_label ?? "", isOn: binding)
                .tint(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
            if let desc = block.toggle_description {
                Text(loc?("block.\(block.id).description", desc) ?? desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Video (SPEC-085: Full VideoBlockView with playback)

    private func videoBlock(_ block: ContentBlock) -> some View {
        let effectiveHeight = CGFloat(block.video_height ?? block.height ?? 200)
        let effectiveCornerRadius = CGFloat(block.video_corner_radius ?? block.corner_radius ?? 8)

        return Group {
            // SPEC-085: Use VideoBlockView for full playback when video_url is present
            if let videoUrl = block.video_url {
                let videoBlock = VideoBlock(
                    video_url: videoUrl,
                    video_thumbnail_url: block.video_thumbnail_url ?? block.image_url,
                    video_height: Double(effectiveHeight),
                    video_corner_radius: Double(effectiveCornerRadius),
                    // SPEC-419 pass-14 #3 — fall back to the video_*-prefixed
                    // keys the console editor + preview + Android write, so an
                    // authored video_autoplay/_loop/_muted/_controls is honored.
                    autoplay: block.autoplay ?? block.video_autoplay,
                    loop: block.loop ?? block.video_loop,
                    muted: block.muted ?? block.video_muted,
                    controls: block.controls ?? block.video_controls,
                    inline_playback: true
                )
                VideoBlockView(block: videoBlock)
            } else if let thumbUrl = block.video_thumbnail_url ?? block.image_url,
                      let url = URL(string: thumbUrl) {
                // Fallback: thumbnail-only display when no video_url
                BundledAsyncPhaseImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        ZStack {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxHeight: effectiveHeight)
                                .clipShape(RoundedRectangle(cornerRadius: effectiveCornerRadius))
                                .accessibilityLabel(block.alt ?? "Video")
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.9))
                                .shadow(radius: 4)
                        }
                    default:
                        ProgressView().frame(height: effectiveHeight)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: effectiveCornerRadius)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: effectiveHeight)
                    .overlay(Image(systemName: "play.circle").font(.largeTitle).foregroundColor(.gray))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Lottie (SPEC-085)

    private func lottieBlock(_ block: ContentBlock) -> some View {
        Group {
            if let lottieUrl = block.lottie_url {
                let lottieData = LottieBlock(
                    lottie_url: lottieUrl,
                    lottie_json: nil,
                    autoplay: block.autoplay ?? true,
                    loop: block.loop ?? true,
                    speed: block.lottie_speed ?? 1.0,  // SPEC-419 pass-23 — editor now authors lottie_speed (decoupled from the overloaded string `speed` particle key)
                    width: block.lottie_width,
                    height: block.lottie_height ?? block.height ?? 160,
                    alignment: block.icon_alignment ?? block.alignment ?? "center",  // SPEC-419 pass-22 — editor writes block.alignment
                    play_on_scroll: block.play_on_scroll,
                    play_on_tap: block.play_on_tap,
                    color_overrides: nil
                )
                LottieBlockView(block: lottieData)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Rive (SPEC-085)

    private func riveBlock(_ block: ContentBlock) -> some View {
        Group {
            if let riveUrl = block.rive_url {
                let riveData = RiveBlock(
                    rive_url: riveUrl,
                    artboard: block.artboard,
                    state_machine: block.state_machine,
                    autoplay: block.autoplay ?? true,
                    height: block.height ?? 160,
                    alignment: block.icon_alignment ?? block.alignment ?? "center",  // SPEC-419 pass-22 — editor writes block.alignment
                    inputs: nil,
                    trigger_on_step_complete: block.trigger_on_step_complete
                )
                RiveBlockView(block: riveData)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Page Indicator (SPEC-089d AC-012)

    private func pageIndicatorBlock(_ block: ContentBlock) -> some View {
        // SPEC-419 — clamp to a sane range; ForEach(0..<dotCount) crashes on a negative/huge count.
        let dotCount = min(max(block.dot_count ?? totalSteps, 0), 50)
        // AC-012: Auto-bind active_index to current step index when not explicitly set
        let activeIdx = block.active_index ?? currentStepIndex
        let dotSize = CGFloat(block.dot_size ?? 8)
        let dotSpacing = CGFloat(block.dot_spacing ?? 8)
        let activeW = block.active_dot_width.map { CGFloat($0) }
        let activeColor = Color(hex: block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let inactiveColor = Color(hex: block.inactive_color ?? "#D1D5DB")
        // SPEC — per-dot shape (default "circle" preserves the legacy Capsule/Circle look).
        let dotShape = (block.dot_shape ?? "circle").lowercased()

        let align: Alignment = {
            switch block.alignment {
            case "left": return .leading
            case "right": return .trailing
            default: return .center
            }
        }()

        return HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                let isActive = index == activeIdx
                let color = isActive ? activeColor : inactiveColor
                let w = isActive ? (activeW ?? dotSize) : dotSize
                pageDot(shape: dotShape, color: color, width: w, height: dotSize, isActive: isActive)
            }
        }
        .frame(maxWidth: .infinity, alignment: align)
        .accessibilityLabel("Page \(activeIdx + 1) of \(dotCount)")
    }

    /// One page-indicator dot rendered in the configured shape. Circle keeps the
    /// legacy behaviour exactly: active pill (active_dot_width set) → Capsule,
    /// otherwise Circle.
    @ViewBuilder
    private func pageDot(shape: String, color: Color, width: CGFloat, height: CGFloat, isActive: Bool) -> some View {
        switch shape {
        case "rectangle":
            Rectangle().fill(color).frame(width: width, height: height)
        case "triangle":
            PageDotTriangle().fill(color).frame(width: width, height: height)
        case "star":
            Image(systemName: "star.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(color)
                .frame(width: width, height: height)
        default: // "circle"
            if isActive && width != height {
                Capsule().fill(color).frame(width: width, height: height)
            } else {
                Circle().fill(color).frame(width: width, height: height)
            }
        }
    }

    // MARK: - Social Login (SPEC-089d AC-015)

    private func socialLoginBlock(_ block: ContentBlock) -> some View {
        let providerList = (block.providers ?? []).filter { $0.enabled != false }
        let btnStyle = block.button_style ?? "filled"
        let btnHeight = CGFloat(block.button_height ?? 50)
        let btnSpacing = CGFloat(block.spacing ?? 12)
        let btnRadius = CGFloat(block.button_corner_radius ?? 12)

        // SPEC-089e amendment — when email_login_placement == "below_inputs"
        // the email provider renders first, then a spacer, then the other
        // providers. This is the expected layout when the social_login block
        // sits directly under email+password input blocks.
        let placement = block.email_login_placement ?? "with_providers"
        let emailSpacer = CGFloat(block.email_cta_spacing_below ?? 16)
        let textAlign = block.button_text_align ?? "center"
        // Social-Login styling v2 — divider color + placement.
        let dividerColor: Color = {
            if let hex = block.divider_color, !hex.isEmpty { return Color(hex: hex) }
            return Color.gray.opacity(0.3)
        }()
        let dividerPosition = block.divider_position ?? "bottom"
        let (topGroup, bottomGroup): ([SocialProviderConfig], [SocialProviderConfig]) = {
            if placement == "below_inputs", let emailIdx = providerList.firstIndex(where: { ($0.type ?? "") == "email" }) {
                var rest = providerList
                let email = rest.remove(at: emailIdx)
                return ([email], rest)
            }
            return (providerList, [])
        }()

        // Optional divider between social login and other options. Placement is
        // controlled by divider_position ("top" | "bottom").
        let divider = Group {
            if block.show_divider == true {
                HStack(spacing: 12) {
                    Rectangle().fill(dividerColor).frame(height: 1)
                    Text(loc?("block.\(block.id).divider", block.divider_text ?? "or") ?? block.divider_text ?? "or")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Rectangle().fill(dividerColor).frame(height: 1)
                }
            }
        }

        // #578 — the divider is a SLOT in the stack, not one of two fixed ends.
        //
        // `top` is slot 0 and `bottom` is the last slot, kept as their own values so no flow
        // authored before this release changes and an older SDK build still understands them.
        // `after` names an interior slot through `field_config.divider_after_index` (0-based, the
        // divider sits AFTER that provider) — ContentBlock is at the JVM argument ceiling, so the
        // index cannot be a top-level field.
        let dividerSlot: Int = {
            if dividerPosition == "top" { return 0 }
            guard dividerPosition == "after" else { return topGroup.count }
            let raw: Int = {
                if let i = block.field_config?["divider_after_index"]?.value as? Int { return i }
                if let d = block.field_config?["divider_after_index"]?.value as? Double { return Int(d) }
                return 0
            }()
            return min(max(raw + 1, 0), topGroup.count)
        }()

        return VStack(spacing: btnSpacing) {
            if dividerSlot == 0 { divider }
            ForEach(Array(topGroup.enumerated()), id: \.offset) { index, provider in
                socialLoginButton(provider, index: index, blockId: block.id, btnStyle: btnStyle, btnHeight: btnHeight, blockRadius: btnRadius, textAlign: textAlign, blockAccentColor: block.accent_color, blockBgColor: block.bg_color, pressedStyle: block.pressed_style)
                if dividerSlot == index + 1 { divider }
            }
            if placement == "below_inputs" && !topGroup.isEmpty && !bottomGroup.isEmpty {
                // Subtract the VStack's own spacing so the visual gap between the
                // email button and the first OAuth button equals emailSpacer.
                Color.clear.frame(height: max(0, emailSpacer - btnSpacing))
            }
            ForEach(Array(bottomGroup.enumerated()), id: \.offset) { idx, provider in
                // Mirror Android's post-split index scheme: bottomGroup labels are
                // localized under topGroup.count + idx (see ContentBlockRenderer.kt).
                socialLoginButton(provider, index: topGroup.count + idx, blockId: block.id, btnStyle: btnStyle, btnHeight: btnHeight, blockRadius: btnRadius, textAlign: textAlign, blockAccentColor: block.accent_color, blockBgColor: block.bg_color, pressedStyle: block.pressed_style)
            }
            // The end slot. Guarded on the slot rather than "not top", so an interior slot does
            // not also draw one down here — which is what a `!= top` test would do.
            if dividerSlot >= topGroup.count { divider }
        }
    }

    /// One social-login button with per-provider color/radius overrides applied.
    /// SPEC-089e amendment — any nil override falls back to the brand default
    /// (Apple=black, Google=#4285F4, email=#6366F1, etc.).
    private func socialLoginButton(_ provider: SocialProviderConfig, index: Int, blockId: String, btnStyle: String, btnHeight: CGFloat, blockRadius: CGFloat, textAlign: String = "center", blockAccentColor: String? = nil, blockBgColor: String? = nil, pressedStyle: PressedStyle? = nil) -> some View {
        let providerType = provider.type ?? ""
        let radius = CGFloat(provider.corner_radius ?? Double(blockRadius))
        let bgColor: Color = {
            if let hex = provider.bg_color, !hex.isEmpty { return Color(hex: hex) }
            return socialLoginBgColor(providerType, style: btnStyle, blockAccent: blockAccentColor, blockBg: blockBgColor)
        }()
        let textColor: Color = {
            if let hex = provider.text_color, !hex.isEmpty { return Color(hex: hex) }
            return socialLoginTextColor(providerType, style: btnStyle)
        }()
        let borderColor: Color = {
            if let hex = provider.border_color, !hex.isEmpty { return Color(hex: hex) }
            return socialLoginBorderColor(providerType, style: btnStyle)
        }()
        let borderWidth: CGFloat = {
            if let w = provider.border_width { return CGFloat(w) }
            return btnStyle == "outlined" ? 1.5 : 0
        }()
        return Button {
            for emit in SocialLoginActionDispatcher.actions(forProviderType: providerType) {
                onAction(emit.action, emit.value)
            }
        } label: {
            HStack(spacing: 10) {
                // Social-Login styling v2 — a custom icon_url overrides the built-in
                // provider glyph (email still suppresses its glyph unless a URL is set).
                if let iconURL = provider.icon_url, !iconURL.isEmpty, let url = URL(string: iconURL) {
                    BundledAsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                    } placeholder: {
                        EmptyView()
                    }
                } else if providerType != "email" {
                    // SPEC-419 — no glyph for the email provider (parity with Android): the
                    // envelope rendered awkwardly on the brand-tinted "Continue with Email"
                    // button and its reserved spacing offset the label. Plain centered CTA.
                    socialLoginIcon(providerType, iconStyle: provider.icon_style, buttonTextColor: textColor, btnStyle: btnStyle)
                }
                // Localize the provider label like Android (loc "block.<id>.provider.<index>"),
                // falling back to the authored label then the brand default.
                Text(loc?("block.\(blockId).provider.\(index)", provider.label ?? socialLoginDefaultLabel(providerType)) ?? provider.label ?? socialLoginDefaultLabel(providerType))
                    // #560 — per-provider label size. `.body` is ~17pt, which is the size this
                    // rendered at before the field existed, so an unset value is byte-identical to
                    // the previous behaviour rather than a silent restyle of every existing flow.
                    .font(.system(size: provider.font_size.map { CGFloat($0) } ?? 17, weight: .semibold))
            }
            .padding(.horizontal, textAlign == "leading" ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: textAlign == "leading" ? .leading : .center)
            .frame(height: btnHeight)
            .foregroundColor(textColor)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
        }
        .applyPressedStyle(pressedStyle)
    }

    // Social login helpers

    /// Social login icon with configurable style.
    /// icon_style: "default", "monochrome_light" (white icons), "monochrome_dark" (black icons),
    ///             "filled" (colored bg), "outline" (border only).
    private func socialLoginIcon(_ type: String, iconStyle: String? = nil, buttonTextColor: Color = .primary, btnStyle: String = "filled") -> AnyView {
        let style = iconStyle ?? "default"
        // Monochrome styles force icon color; default uses provider-native colors
        let monoColor: Color? = style == "monochrome_light" ? .white
            : style == "monochrome_dark" ? .black
            : nil

        switch type {
        case "apple":
            return AnyView(Image(systemName: "applelogo")
                .font(.body.weight(.medium))
                .foregroundColor(monoColor))
        case "google":
            if let mono = monoColor {
                return AnyView(Text("G")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(mono))
            }
            return AnyView(Text("G")
                .font(.system(size: 18, weight: .bold, design: .rounded)))
        case "email":
            return AnyView(Image(systemName: "envelope.fill")
                .font(.body)
                .foregroundColor(monoColor))
        case "facebook":
            // Brand-blue "f" is only legible on transparent-background buttons
            // (outlined/minimal). On a FILLED facebook button the background is
            // already #1877F2, so a blue glyph would be invisible — use the button
            // textColor (white) there. A monochrome icon_style override still wins.
            // Matches Android + console preview.
            let fbColor: Color = monoColor
                ?? ((btnStyle == "outlined" || btnStyle == "minimal") ? Color(hex: "#1877F2") : buttonTextColor)
            return AnyView(Text("f")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(fbColor))
        case "github":
            // No glyph (parity with Android, which renders no github icon, + console preview).
            return AnyView(EmptyView())
        default:
            // Unknown/custom provider types render NO glyph (parity with Android
            // ContentBlockRenderer.kt — empty icon for unrecognized providers). Known
            // providers above keep their real icons; only the fallback is now empty.
            return AnyView(EmptyView())
        }
    }

    private func socialLoginDefaultLabel(_ type: String) -> String {
        switch type {
        case "apple": return "Continue with Apple"
        case "google": return "Continue with Google"
        case "email": return "Continue with Email"
        case "facebook": return "Continue with Facebook"
        case "github": return "Continue with GitHub"
        // Parity with Android (ContentBlockRenderer.kt:3636) + preview (OnboardingStepPreview.tsx:1572):
        // unknown/custom provider types use "Continue with {Type}" (type capitalized).
        default:
            guard !type.isEmpty else { return "Continue" }
            return "Continue with " + type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    private func socialLoginBgColor(_ type: String, style: String, blockAccent: String? = nil, blockBg: String? = nil) -> Color {
        if style == "outlined" || style == "minimal" { return .clear }
        switch type {
        case "apple": return .black
        case "google": return Color(hex: "#4285F4") // Google brand blue
        case "facebook": return Color(hex: "#1877F2")
        case "github": return Color(hex: "#24292E")
        // Parity with Android (ContentBlockRenderer.kt:3656-3660): email/unknown provider
        // honors block-level accent_color then bg_color before falling back to the brand accent.
        default:
            if let hex = blockAccent, !hex.isEmpty { return Color(hex: hex) }
            if let hex = blockBg, !hex.isEmpty { return Color(hex: hex) }
            return Color(hex: (AppDNA.brandAccentHex ?? "#6366F1"))
        }
    }

    private func socialLoginTextColor(_ type: String, style: String) -> Color {
        if style == "outlined" || style == "minimal" {
            return type == "apple" ? .primary : .primary
        }
        switch type {
        case "apple": return .white
        case "google": return .white // White text on Google brand blue
        case "facebook": return .white
        case "github": return .white
        default: return .white
        }
    }

    private func socialLoginBorderColor(_ type: String, style: String) -> Color {
        if style != "outlined" { return .clear }
        switch type {
        case "google": return Color(hex: "#DADCE0")
        default: return Color.gray.opacity(0.4)
        }
    }

    // MARK: - Timeline (SPEC-089d AC-016)

    private func timelineBlock(_ block: ContentBlock) -> some View {
        let itemList = block.timeline_items ?? []
        let isCompact = block.compact ?? false
        let showConnector = block.show_line ?? true
        let completedCol = Color(hex: block.completed_color ?? "#22C55E")
        let currentCol = Color(hex: block.current_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let upcomingCol = Color(hex: block.upcoming_color ?? "#D1D5DB")

        return VStack(alignment: .leading, spacing: isCompact ? 0 : 8) {
            ForEach(Array(itemList.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 16) {
                    // Left column: status indicator + connecting line
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(timelineStatusColor(item.status ?? "upcoming", completed: completedCol, current: currentCol, upcoming: upcomingCol))
                                .frame(width: 28, height: 28)

                            if item.status == "completed" {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            } else if item.status == "current" {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                            }
                        }

                        if showConnector && index < itemList.count - 1 {
                            Rectangle()
                                .fill(Color(hex: block.line_color ?? "#E5E7EB"))
                                .frame(width: 2)
                                .frame(minHeight: isCompact ? 20 : 32)
                        }
                    }

                    // Right column: title + subtitle
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .applyTextStyle(block.title_style)
                            .foregroundColor(item.status == "upcoming" ? .secondary : .primary)

                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .applyTextStyle(block.subtitle_style)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, isCompact ? 8 : 12)

                    Spacer()
                }
            }
        }
    }

    private func timelineStatusColor(_ status: String, completed: Color, current: Color, upcoming: Color) -> Color {
        switch status {
        case "completed": return completed
        case "current": return current
        default: return upcoming
        }
    }

    // MARK: - Rich Text (SPEC-089d AC-020)

    private func richTextBlock(_ block: ContentBlock) -> some View {
        let rawContent = block.markdown_content ?? block.text ?? ""
        let content = loc?("block.\(block.id).content", rawContent) ?? rawContent  // localize like Android (block.<id>.content)
        let isLegal = block.rich_text_variant == "legal"
        let linkCol = Color(hex: block.link_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        // Mirror Android + preview: rich_text resolves its font/color/decorations/
        // alignment from base_style, falling back to `style` when base_style is nil,
        // so a style-only rich_text block renders identically across platforms.
        let rtStyle = block.base_style ?? block.style

        // SPEC-205 adjacent fix: honor `base_style.alignment` for rich_text.
        // Previously both `.multilineTextAlignment` and the outer frame alignment
        // were hardcoded based ONLY on `rich_text_variant == "legal"`, which
        // meant authored center/right alignment was silently dropped — most
        // visible inside `child_row` where the frame fills the cell and the
        // left-alignment overrode the authored value. Now: authored alignment
        // wins; legal keeps its center default when author didn't set one.
        let authored = rtStyle?.alignment
        let textAlign: TextAlignment = {
            switch authored {
            case "center": return .center
            case "right": return .trailing
            case "left": return .leading
            default: return isLegal ? .center : .leading
            }
        }()
        let frameAlign: Alignment = {
            switch authored {
            case "center": return .center
            case "right": return .trailing
            case "left": return .leading
            default: return isLegal ? .center : .leading
            }
        }()

        return Group {
            // Resolve the authored base_style font DIRECTLY on the Text so it wins
            // over the env .font() applyTextStyle would apply (see heading/text
            // pattern at ~line 314). Previously `.font(isLegal ? .caption : .body)`
            // baked a font onto the Text that silently dropped base_style.font_family
            // / font_size / font_weight on iOS.
            let styleFont = FontResolver.font(
                family: rtStyle?.font_family,
                size: rtStyle?.font_size ?? (isLegal ? 12 : 17),
                weight: rtStyle?.font_weight
            )
            if #available(iOS 15.0, *) {
                let textCol: Color? = rtStyle?.color.map { Color(hex: $0) }
                let attributed = parseMarkdownToAttributedString(content, linkColor: linkCol, textColor: textCol)
                Text(attributed)
                    .font(styleFont)
                    .foregroundColor(isLegal ? .secondary : .primary)
                    .applyTextStyleDecorations(rtStyle)
                    // SPEC-419 pass-15 #23 — honor max_lines like Android (ClickableText maxLines)
                    .lineLimit(block.max_lines)
                    // Apply AFTER applyTextStyleDecorations — its internal multilineTextAlignment
                    // would otherwise override ours when base_style.alignment is unset.
                    .multilineTextAlignment(textAlign)
                    .frame(maxWidth: .infinity, alignment: frameAlign)
            } else {
                // Fallback: render as plain text, stripping markdown tokens
                Text(stripMarkdown(content))
                    .font(styleFont)
                    .foregroundColor(isLegal ? .secondary : .primary)
                    .applyTextStyleDecorations(rtStyle)
                    .lineLimit(block.max_lines)
                    .multilineTextAlignment(textAlign)
                    .frame(maxWidth: .infinity, alignment: frameAlign)
            }
        }
    }

    /// Parse subset of markdown (**bold**, *italic*, [link](url), ++underline++)
    /// to AttributedString. `++text++` is a custom extension — native
    /// CommonMark has no underline syntax, but the parser leaves `++`
    /// pairs verbatim so we can post-process them here.
    @available(iOS 15.0, *)
    private func parseMarkdownToAttributedString(_ markdown: String, linkColor: Color, textColor: Color? = nil) -> AttributedString {
        // EPIC-9 two fixes: (1) `.inlineOnlyPreservingWhitespace` STOPS at the first paragraph
        // break (\n\n), so multi-paragraph content previously rendered only its first line — parse
        // each line separately and rejoin with newlines. (2) `Text(AttributedString)` ignores the
        // `.foregroundColor` view modifier because the markdown runs carry their own label color —
        // so force the authored `base_style.color` onto every non-link run (matches Android).
        let lines = markdown.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            if var parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in parsed.runs {
                    if run.link != nil {
                        parsed[run.range].foregroundColor = UIColor(linkColor)
                        parsed[run.range].underlineStyle = .single  // match Android's underlined links
                    } else if let textColor {
                        parsed[run.range].foregroundColor = UIColor(textColor)
                    }
                }
                result.append(parsed)
            } else {
                result.append(AttributedString(line))
            }
        }
        // Apply AppDNA-specific `++underline++` after native parsing.
        applyUnderlineMarkers(&result)
        return result
    }

    /// Post-process `++text++` markers in the parsed AttributedString:
    /// apply `.underlineStyle = .single` to the inner range and remove
    /// the `++` marker characters. Collects ranges forward, then mutates
    /// back-to-front so prior deletions don't invalidate later indices.
    @available(iOS 15.0, *)
    private func applyUnderlineMarkers(_ attr: inout AttributedString) {
        var marks: [(Range<AttributedString.Index>, Range<AttributedString.Index>)] = []
        var cursor = attr.startIndex
        while cursor < attr.endIndex {
            guard let openRange = attr[cursor...].range(of: "++") else { break }
            let afterOpen = openRange.upperBound
            guard afterOpen < attr.endIndex,
                  let closeRange = attr[afterOpen...].range(of: "++") else { break }
            marks.append((openRange, closeRange))
            cursor = closeRange.upperBound
        }
        for (openRange, closeRange) in marks.reversed() {
            let innerRange = openRange.upperBound..<closeRange.lowerBound
            attr[innerRange].underlineStyle = .single
            attr.removeSubrange(closeRange)
            attr.removeSubrange(openRange)
        }
    }

    /// Strip markdown tokens for pre-iOS 15 fallback.
    private func stripMarkdown(_ text: String) -> String {
        var result = text
        // Bold: **text** or __text__
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
        // Italic: *text* or _text_
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "_(.+?)_", with: "$1", options: .regularExpression)
        // Links: [text](url)
        result = result.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
        return result
    }

    // MARK: - Progress Bar (SPEC-089d AC-021)

    private func progressBarBlock(_ block: ContentBlock) -> some View {
        let variant = block.progress_variant ?? "continuous"
        // AC-021: Auto-bind to step index when no explicit values set
        // SPEC-419 — clamp; ForEach(0..<totalSegs) crashes on a negative/huge count.
        let totalSegs = min(max(block.total_segments ?? totalSteps, 0), 50)
        let filledSegs: Int = {
            if let explicit = block.filled_segments { return explicit }
            // Auto-bind: current step index + 1 (1-based fill). Note: when only
            // progress_value is set (continuous fill), the label still tracks the
            // step index — matching Android + the console preview. (Previously a
            // `progress_value != nil` branch here forced this to 1, freezing the
            // label at "Step 1".)
            return currentStepIndex + 1
        }()
        // Progress/Loading v2 — clamp to the console slider max (24) so an
        // out-of-range published value can't render a giant bar the editor
        // can't reproduce (duolingo s7). Default 8 matches editor+preview.
        let barH = min(CGFloat(block.bar_height ?? 8), 24)
        let barRadius = CGFloat(block.corner_radius ?? 3)
        let fillColor = Color(hex: block.bar_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        // EPIC-2 — multiple progress colors at once (horizontal gradient across the fill).
        let gradCols = (block.bar_gradient_colors ?? []).map { Color(hex: $0) }
        let fillStyle: AnyShapeStyle = gradCols.count >= 2
            ? AnyShapeStyle(LinearGradient(colors: gradCols, startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(fillColor)
        let trackCol = Color(hex: block.track_color ?? "#E5E7EB")
        let gap = CGFloat(block.segment_gap ?? 4)
        // SPEC-419 gap#2 — explicit continuous fill from `progress_value`
        // (0–1 fraction OR 0–100 percent), clamped. When unset the bar keeps
        // auto-binding to the step index (filledSegs/totalSegs). Matches the
        // console preview which fills `width: progress_value%`.
        let pvFraction: CGFloat? = block.progress_value.map {
            min(1, max(0, CGFloat($0 > 1 ? $0 / 100 : $0)))
        }
        // SPEC-419 pass-13 correctness — the percentage/fraction label must use
        // the SAME normalization as the fill (`pvFraction`). Previously the
        // label rendered the RAW `progress_value` → `progress_value=0.75` filled
        // 75% but the label read "0%". Matches Android pvPercent.
        let effFraction = pvFraction ?? (variant == "segmented" ? 0 : (totalSegs > 0 ? CGFloat(filledSegs) / CGFloat(totalSegs) : 0))
        let pvPercent = Int((effFraction * 100).rounded())
        // SPEC-419 gap#6 — honor `label_format`/`custom_label`; default keeps
        // the existing "Step X of Y" when no format is authored. Mirrors the
        // console preview progress_bar label logic.
        let labelText: String = {
            guard let fmt = block.label_format else { return "Step \(filledSegs) of \(totalSegs)" }
            switch fmt {
            case "fraction":
                return variant == "segmented" ? "\(filledSegs)/\(totalSegs)" : "\(pvPercent)/100"
            case "custom":
                return block.custom_label ?? ""
            default: // percentage
                return variant == "segmented"
                    ? "\(Int((Double(filledSegs) / Double(max(totalSegs, 1))) * 100))%"
                    : "\(pvPercent)%"
            }
        }()

        // SPEC-419 pass-14 #13 — show_label defaults TRUE (unset) to match the
        // editor (inits true) + preview (`show_label !== false`).
        let showLbl = block.show_label != false
        // Progress/Loading v2 — label placement relative to the bar.
        let placement = block.label_placement ?? "above"
        // #584 — the label's own colour and size. It rendered in `.secondary` with no control at
        // all, so an author could style the bar and its track and not the words beside them. Every
        // displayed piece of text should be colourable on its own.
        let labelView = AnyView(
            Text(labelText)
                .font(.system(size: cfgDouble(block.field_config?["progress_label_font_size"]).map { CGFloat($0) } ?? 12))
                .foregroundColor(
                    (block.field_config?["progress_label_color"]?.value as? String)
                        .flatMap { $0.isEmpty ? nil : Color(hex: $0) } ?? .secondary
                )
        )
        let barView = AnyView(
            Group {
                if variant == "segmented" {
                    // Segmented: individual rounded bars
                    HStack(spacing: gap) {
                        ForEach(0..<totalSegs, id: \.self) { index in
                            RoundedRectangle(cornerRadius: barRadius)
                                .fill(index < filledSegs ? fillColor : trackCol)
                                .frame(height: barH)
                        }
                    }
                } else {
                    // Continuous: single track + fill
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: barRadius)
                                .fill(trackCol)
                                .frame(height: barH)

                            let fraction = pvFraction ?? (totalSegs > 0 ? CGFloat(filledSegs) / CGFloat(totalSegs) : 0)
                            RoundedRectangle(cornerRadius: barRadius)
                                .fill(fillStyle)
                                .frame(width: geometry.size.width * min(fraction, 1.0), height: barH)
                        }
                    }
                    .frame(height: barH)
                }
            }
        )

        return Group {
            switch placement {
            case "left":
                HStack(spacing: 8) {
                    if showLbl { labelView }
                    barView
                }
            case "right":
                HStack(spacing: 8) {
                    barView
                    if showLbl { labelView }
                }
            case "below":
                VStack(spacing: 8) {
                    barView
                    if showLbl { labelView.frame(maxWidth: .infinity, alignment: .leading) }
                }
            default: // "above"
                VStack(spacing: 8) {
                    if showLbl { labelView.frame(maxWidth: .infinity, alignment: .leading) }
                    barView
                }
            }
        }
    }

    // MARK: - Stack (ZStack container — SPEC-089d AC-024)

    @ViewBuilder
    private func stackBlock(_ block: ContentBlock) -> some View {
        let childBlocks = (block.children ?? block.stack_children ?? []).sorted { ($0.z_index ?? 0) < ($1.z_index ?? 0) } // stack_children = the editor's key (match rowBlock); was dropped → ZStack rendered empty
        let align: Alignment = {
            // SPEC-419 — normalize hyphenated editor values (top-left, center-left, bottom-center)
            // to underscores so they map; also handle the *-center / center-* variants.
            switch (block.alignment ?? "").replacingOccurrences(of: "-", with: "_") {
            case "top_left", "topLeading": return .topLeading
            case "top", "top_center", "topCenter": return .top
            case "top_right", "topTrailing": return .topTrailing
            case "left", "leading", "center_left": return .leading
            case "right", "trailing", "center_right": return .trailing
            case "bottom_left", "bottomLeading": return .bottomLeading
            case "bottom", "bottom_center", "bottomCenter": return .bottom
            case "bottom_right", "bottomTrailing": return .bottomTrailing
            default: return .center
            }
        }()

        ZStack(alignment: align) {
            ForEach(childBlocks) { child in
                renderBlock(child)
            }
        }
        // SPEC-419 pass-14 #4 — apply authored `height` to the stack container
        // (the editor default-inits 200; preview applies block.height at
        // OnboardingStepPreview.tsx:1735). A bare ZStack only sized to its
        // children, so authored heights were dropped on-device.
        .frame(height: block.height.map { CGFloat($0) }, alignment: align)
    }

    // MARK: - Row (HStack container — SPEC-089d AC-025)

    @ViewBuilder
    private func rowBlock(_ block: ContentBlock) -> some View {
        // Mrozu QA: `row.wrap == true` must flow children onto multiple lines
        // (chips/badges) instead of a single clipped HStack. iOS 16+ Layout;
        // pre-16 falls back to the normal HStack. Parity with Android FlowRow.
        if block.wrap == true, (block.row_direction ?? "horizontal") == "horizontal",
           parseColumnRatios((block.field_config?["column_ratios"]?.value as? String) ?? block.column_ratios).isEmpty {
            wrappedRowBlock(block)
        } else {
            standardRowBlock(block)
        }
    }

    @ViewBuilder
    private func wrappedRowBlock(_ block: ContentBlock) -> some View {
        let childBlocks = block.children ?? block.stack_children ?? []
        let rowGap = CGFloat(block.spacing ?? block.gap ?? 8)
        let rowBgOpacity = CGFloat((cfgDouble(block.field_config?["background_opacity"])) ?? 1.0)
        let rowUseBlur = (block.field_config?["blur_background"]?.value as? Bool) == true
        let rowBorderW = CGFloat((cfgDouble(block.field_config?["border_width"])) ?? 0)
        let rowBorderCol = (block.field_config?["border_color"]?.value as? String).map { Color(hex: $0) }
        let rowBgCol = (block.field_config?["bg_color"]?.value as? String).map { Color(hex: $0) }
        let rowCornerR = CGFloat((cfgDouble(block.field_config?["corner_radius"])) ?? 0)
        // Leading icon slot — must render inside the wrap too (parity with
        // standardRowBlock + Android FlowRow's LeadingIconSlot()).
        let leadingIcon = block.field_config?["leading_icon"]?.value as? String
        let leadingIconSize = CGFloat((cfgDouble(block.field_config?["leading_icon_size"])) ?? 24)
        let leadingIconColor = (block.field_config?["leading_icon_color"]?.value as? String).map { Color(hex: $0) }
        let leadingIconBgColor = (block.field_config?["leading_icon_bg_color"]?.value as? String).map { Color(hex: $0) }
        let leadingIconBgSize = CGFloat((cfgDouble(block.field_config?["leading_icon_bg_size"])) ?? (leadingIconSize + 16))
        Group {
            if #available(iOS 16.0, *) {
                WrapLayout(hSpacing: rowGap, vSpacing: rowGap) {
                    if let icon = leadingIcon {
                        rowLeadingIconView(icon: icon, size: leadingIconSize, color: leadingIconColor, bgColor: leadingIconBgColor, bgSize: leadingIconBgSize)
                    }
                    ForEach(childBlocks) { child in
                        renderBlock(child)
                            .applyRelativeSizing(width: child.element_width, height: child.element_height)
                            .zIndex(child.overflow == "visible" ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Pre-iOS16 fallback: standard single-line row.
                standardRowBlock(block)
            }
        }
        .if(rowBgCol != nil || rowBorderW > 0 || rowUseBlur) { view in
            view
                .padding(rowBorderW > 0 ? 12 : 0)
                .background {
                    ZStack {
                        if rowUseBlur { RoundedRectangle(cornerRadius: rowCornerR).fill(.ultraThinMaterial) }
                        if let bg = rowBgCol { RoundedRectangle(cornerRadius: rowCornerR).fill(bg.opacity(rowBgOpacity)) }
                        if rowBorderW > 0, let bc = rowBorderCol { RoundedRectangle(cornerRadius: rowCornerR).strokeBorder(bc, lineWidth: rowBorderW) }
                    }
                }
        }
    }

    @ViewBuilder
    private func standardRowBlock(_ block: ContentBlock) -> some View {
        let childBlocks = block.children ?? block.stack_children ?? []
        // SPEC-419 — the editor writes `spacing` (preview reads `spacing`); `gap` is the legacy/
        // imported key. Read spacing first so authored row gap isn't lost on-device.
        let rowGap = CGFloat(block.spacing ?? block.gap ?? 8)
        let direction = block.row_direction ?? "horizontal"
        let childFill = block.row_child_fill ?? true

        // Column ratios: "1:2", "1:1:2", "2:3" — proportional widths for horizontal layout.
        // Each number is a flex weight. Children map 1:1 to ratios; extra children get equal weight.
        let ratioStr = (block.field_config?["column_ratios"]?.value as? String) ?? block.column_ratios
        let ratios: [CGFloat] = parseColumnRatios(ratioStr)

        // Row background: opacity + blur (same as select options)
        let rowBgOpacity = CGFloat((cfgDouble(block.field_config?["background_opacity"])) ?? 1.0)
        let rowUseBlur = (block.field_config?["blur_background"]?.value as? Bool) == true
        let rowBorderW = CGFloat((cfgDouble(block.field_config?["border_width"])) ?? 0)
        let rowBorderCol = (block.field_config?["border_color"]?.value as? String).map { Color(hex: $0) }
        let rowBgCol = (block.field_config?["bg_color"]?.value as? String).map { Color(hex: $0) }
        let rowCornerR = CGFloat((cfgDouble(block.field_config?["corner_radius"])) ?? 0)

        // Leading icon slot (for info-card pattern: icon + children layout)
        let leadingIcon = block.field_config?["leading_icon"]?.value as? String
        let leadingIconSize = CGFloat((cfgDouble(block.field_config?["leading_icon_size"])) ?? 24)
        let leadingIconColor = (block.field_config?["leading_icon_color"]?.value as? String).map { Color(hex: $0) }
        let leadingIconBgColor = (block.field_config?["leading_icon_bg_color"]?.value as? String).map { Color(hex: $0) }
        let leadingIconBgSize = CGFloat((cfgDouble(block.field_config?["leading_icon_bg_size"])) ?? (leadingIconSize + 16))

        // Vertical alignment for HStack, horizontal for VStack
        let vAlign: VerticalAlignment = {
            switch block.align_items {
            case "top": return .top
            case "bottom": return .bottom
            default: return .center
            }
        }()
        let hAlign: HorizontalAlignment = {
            switch block.align_items {
            case "leading", "start": return .leading
            case "trailing", "end": return .trailing
            default: return .center
            }
        }()

        // SPEC-419 — row_distribution for the horizontal HStack. iOS decoded this but never applied
        // it (Android maps it to Arrangement; preview to justifyContent). Like the preview
        // (`justifyContent: rowChildFill ? undefined : rowDist`) + Android (weight(1f) when childFill),
        // distribution only takes effect when children DON'T fill — filling children make it moot.
        // Ratio-driven rows ignore it entirely (column_ratios path is untouched below).
        let distribution = (block.row_distribution ?? "start").replacingOccurrences(of: "-", with: "_")
        let applyDistribution = !childFill
        let useSpacers = applyDistribution &&
            (distribution == "space_between" || distribution == "space_around" || distribution == "space_evenly")
        let edgeSpacers = applyDistribution &&
            (distribution == "space_around" || distribution == "space_evenly")
        // space_around: edge gaps are HALF the between gaps. Double-spacer trick — between gaps get 2
        // adjacent Spacers (2 units) while edges stay 1 Spacer (1 unit). space_evenly keeps all gaps
        // equal (single); space_between has no edges. Matches Android SpaceAround + CSS space-around.
        let doubleBetweenSpacer = applyDistribution && distribution == "space_around"
        // Horizontal alignment for center/end (HStack) ...
        let distAlignment: Alignment = {
            switch distribution {
            case "center": return .center
            case "end": return .trailing
            default: return .leading // start
            }
        }()
        // ... and the vertical equivalent for direction == "vertical" (VStack).
        let distAlignmentV: Alignment = {
            switch distribution {
            case "center": return .center
            case "end": return .bottom
            default: return .top // start
            }
        }()

        Group {
            if direction == "vertical" {
                // SPEC-419 — apply row_distribution vertically too (Android applies vArrangement for
                // Column; preview applies justifyContent regardless of direction). Inert without a
                // bounded height (Spacers→0, maxHeight:.infinity→content) — matches Android/preview.
                VStack(alignment: hAlign, spacing: useSpacers ? 0 : rowGap) {
                    if edgeSpacers { Spacer(minLength: 0) }
                    if let icon = leadingIcon {
                        rowLeadingIconView(icon: icon, size: leadingIconSize, color: leadingIconColor, bgColor: leadingIconBgColor, bgSize: leadingIconBgSize)
                        if useSpacers { Spacer(minLength: 0); if doubleBetweenSpacer { Spacer(minLength: 0) } }
                    }
                    ForEach(Array(childBlocks.enumerated()), id: \.element.id) { idx, child in
                        renderBlock(child)
                            .applyRelativeSizing(width: child.element_width, height: child.element_height)
                            .frame(maxWidth: childFill ? .infinity : nil)
                            .zIndex(child.overflow == "visible" ? 1 : 0)
                        if useSpacers && idx < childBlocks.count - 1 {
                            Spacer(minLength: 0)
                            if doubleBetweenSpacer { Spacer(minLength: 0) }
                        }
                    }
                    if edgeSpacers { Spacer(minLength: 0) }
                }
                .if(applyDistribution) { view in
                    view.frame(maxHeight: .infinity, alignment: distAlignmentV)
                }
            } else if !ratios.isEmpty {
                // Ratio-driven horizontal row — explicit proportional
                // widths. Leading icon (if present) sits outside the
                // proportional block since it has its own intrinsic
                // size; the ratio applies only to the actual children.
                HStack(alignment: vAlign, spacing: rowGap) {
                    if let icon = leadingIcon {
                        rowLeadingIconView(icon: icon, size: leadingIconSize, color: leadingIconColor, bgColor: leadingIconBgColor, bgSize: leadingIconBgSize)
                    }
                    ProportionalHStack(ratios: ratios, spacing: rowGap, alignment: vAlign) {
                        ForEach(childBlocks) { child in
                            renderBlock(child)
                                .applyRelativeSizing(width: child.element_width, height: child.element_height)
                                .zIndex(child.overflow == "visible" ? 1 : 0)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // SPEC-419 — apply row_distribution. When children fill (childFill), distribution is
                // moot (matches preview/Android). When they don't, center/end use frame alignment;
                // space_between/around/evenly interleave Spacers (around/evenly add leading+trailing).
                HStack(alignment: vAlign, spacing: useSpacers ? 0 : rowGap) {
                    if edgeSpacers { Spacer(minLength: 0) }
                    if let icon = leadingIcon {
                        rowLeadingIconView(icon: icon, size: leadingIconSize, color: leadingIconColor, bgColor: leadingIconBgColor, bgSize: leadingIconBgSize)
                        if useSpacers { Spacer(minLength: 0); if doubleBetweenSpacer { Spacer(minLength: 0) } }
                    }
                    ForEach(Array(childBlocks.enumerated()), id: \.element.id) { idx, child in
                        renderBlock(child)
                            .applyRelativeSizing(width: child.element_width, height: child.element_height)
                            .frame(maxWidth: childFill ? .infinity : nil)
                            .zIndex(child.overflow == "visible" ? 1 : 0)
                        // space_around → between gaps are 2 Spacers (= 2× the single-Spacer edge gap).
                        if useSpacers && idx < childBlocks.count - 1 {
                            Spacer(minLength: 0)
                            if doubleBetweenSpacer { Spacer(minLength: 0) }
                        }
                    }
                    if edgeSpacers { Spacer(minLength: 0) }
                }
                .if(applyDistribution) { view in
                    view.frame(maxWidth: .infinity, alignment: distAlignment)
                }
            }
        }
        // Row container styling: bg, border, blur, opacity
        .if(rowBgCol != nil || rowBorderW > 0 || rowUseBlur) { view in
            view
                .padding(rowBorderW > 0 ? 12 : 0)
                .background {
                    ZStack {
                        if rowUseBlur {
                            RoundedRectangle(cornerRadius: rowCornerR).fill(.ultraThinMaterial)
                        }
                        if let bg = rowBgCol {
                            RoundedRectangle(cornerRadius: rowCornerR).fill(bg.opacity(rowBgOpacity))
                        }
                        if rowBorderW > 0, let bc = rowBorderCol {
                            RoundedRectangle(cornerRadius: rowCornerR).strokeBorder(bc, lineWidth: rowBorderW)
                        }
                    }
                }
        }
    }

    /// Leading icon with optional circle background (for screenshot 11 info-card rows).
    @ViewBuilder
    private func rowLeadingIconView(icon: String, size: CGFloat, color: Color?, bgColor: Color?, bgSize: CGFloat) -> some View {
        ZStack {
            if let bgColor {
                Circle()
                    .fill(bgColor.opacity(0.15))
                    .frame(width: bgSize, height: bgSize)
            }
            if UIImage(systemName: icon) != nil {
                Image(systemName: icon)
                    // SPEC-419 — render the glyph at the CONFIGURED leading_icon_size (was
                    // size * 0.6, which shrank a 24pt setting to a tiny 14pt glyph). Now the
                    // console's leading_icon_size IS the glyph point size, so it scales
                    // directly. .fixedSize() keeps it from being clipped/compressed when the
                    // icon is enlarged.
                    .font(.system(size: size))
                    .foregroundColor(color ?? .primary)
                    .fixedSize()
            } else {
                Text(icon).font(.system(size: size)).fixedSize()
            }
        }
        // Reserve at least the glyph's own footprint (and the bg circle when present) so a
        // larger icon is never cut by a tight row/frame.
        .frame(minWidth: bgColor != nil ? bgSize : size, minHeight: bgColor != nil ? bgSize : size)
    }

    /// Parse "1:2" or "1:1:2" into proportional CGFloat weights.
    private func parseColumnRatios(_ str: String?) -> [CGFloat] {
        guard let str, !str.isEmpty else { return [] }
        return str.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
    }

    /// Proportional horizontal layout for row children. Previously the
    /// renderer used `.layoutPriority(weight)` which SwiftUI interprets
    /// as "first in line for ideal size when space is tight" — it is NOT
    /// a proportional width ratio. On a row like [image, text] with
    /// ratios "1:2" that meant the text's higher priority squeezed the
    /// image down to near-zero width → the image silently disappeared
    /// from the render.
    ///
    /// This Layout assigns each child an explicit fraction of the
    /// available width via the real weights, so "1:2" produces a true
    /// 1/3 and 2/3 split regardless of the child's intrinsic size.
    private struct ProportionalHStack: Layout {
        let ratios: [CGFloat]
        let spacing: CGFloat
        let alignment: VerticalAlignment

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let proposedWidth = proposal.width ?? 0
            // Propose each child its fractional width and take the tallest.
            let widths = allocate(width: proposedWidth, count: subviews.count)
            var maxH: CGFloat = 0
            for (idx, sv) in subviews.enumerated() {
                let w = idx < widths.count ? widths[idx] : 0
                let h = sv.sizeThatFits(ProposedViewSize(width: w, height: proposal.height)).height
                if h > maxH { maxH = h }
            }
            return CGSize(width: proposedWidth, height: maxH)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let widths = allocate(width: bounds.width, count: subviews.count)
            var x = bounds.minX
            for (idx, sv) in subviews.enumerated() {
                let w = idx < widths.count ? widths[idx] : 0
                let anchorY: CGFloat
                switch alignment {
                case .top: anchorY = bounds.minY
                case .bottom: anchorY = bounds.maxY
                default: anchorY = bounds.midY
                }
                sv.place(
                    at: CGPoint(x: x, y: anchorY),
                    anchor: (alignment == .top) ? .topLeading : ((alignment == .bottom) ? .bottomLeading : .leading),
                    proposal: ProposedViewSize(width: w, height: bounds.height)
                )
                x += w + spacing
            }
        }

        private func allocate(width: CGFloat, count: Int) -> [CGFloat] {
            guard count > 0 else { return [] }
            let gapTotal = spacing * CGFloat(max(count - 1, 0))
            let avail = max(width - gapTotal, 0)
            // Extend/truncate ratios to match child count. If fewer ratios
            // than children, extra children each get the last ratio's
            // weight (matches existing behavior at the HStack call site).
            var weights: [CGFloat] = []
            for i in 0..<count {
                if i < ratios.count {
                    weights.append(ratios[i])
                } else {
                    weights.append(ratios.last ?? 1)
                }
            }
            let total = weights.reduce(0, +)
            guard total > 0 else { return Array(repeating: avail / CGFloat(count), count: count) }
            return weights.map { avail * ($0 / total) }
        }
    }

    /// The Map block, resolved through the ladder in SPEC-451 §2:
    ///   1. a host-registered map view, handed the authored config
    ///   2. the Mapbox static image
    ///   3. the authored fallback text
    /// Only rung 3 is a visible degradation, and it is labelled rather than blank.
    @ViewBuilder
    private func mapBlock(_ block: ContentBlock) -> some View {
        let height = mapHeight(block)
        let radius = CGFloat(mapDouble(block, "map_corner_radius") ?? 12)
        // Read straight off `field_config` rather than through `mapCfg`: the authorability gate
        // classifies `<read> ?? "#hex"` as a default behind an editable field, and a helper call on
        // the left of the `??` hides the read from it. Same value, honest shape.
        let surface = Color(hex: (block.field_config?["map_surface_color"]?.value as? String) ?? "#E5E7EB")
        let viewKey = (mapCfg(block, "map_view_key") as? String) ?? "default"
        // An author who turned interactivity OFF wants a picture, not a map the user can drag away
        // from the place the step is about. So this is a gate on the host tier, not a flag passed
        // into it: a registered map view is skipped entirely rather than asked to behave.
        let interactive = (mapCfg(block, "map_interactive") as? Bool) != false
        let infoPosition = (mapCfg(block, "place_info_position") as? String) ?? "overlay_bottom"
        let card = mapInfoCard(block)

        VStack(spacing: 8) {
            if infoPosition == "overlay_top", card != nil {
                // Overlaid by a negative offset rather than a ZStack: the card keeps its natural
                // height, which a fixed inset guess would get wrong the moment a subtitle wraps.
                EmptyView()
            }
            ZStack(alignment: infoPosition == "overlay_top" ? .top : .bottom) {
                Group {
                    if interactive, let factory = AppDNA.registeredMapViews[viewKey] {
                        // Tier 2 — the host's own map, given everything the author set.
                        factory(mapResolvedConfig(block))
                    } else if let url = mapStaticURL(block, token: AppDNA.mapboxToken, width: 390, height: height) {
                        BundledAsyncPhaseImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                surface
                            }
                        }
                    } else {
                        ZStack {
                            surface
                            Text((mapCfg(block, "map_fallback_text") as? String) ?? "Map unavailable")
                                .font(.footnote)
                                .foregroundColor(Color(hex: mapFallbackTextColor(
                                    block.field_config?["map_surface_color"]?.value as? String,
                                    block.field_config?["map_fallback_text_color"]?.value as? String)))
                        }
                    }
                }
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: radius))

                if infoPosition != "below", let card {
                    card.padding(8)
                }
            }
            if infoPosition == "below", let card {
                card
            }
        }
        // Full-bleed cancels the step's horizontal padding so the map meets both screen edges. The
        // negative margin is applied to the WHOLE stack, card included, so an overlaid card stays
        // inset relative to the map rather than sliding off it.
        .padding(.horizontal, (mapCfg(block, "map_full_bleed") as? Bool) == true ? -20 : 0)
        // `map_alt`, not the top-level `alt`: every Map setting rides in `field_config` (ContentBlock
        // is at the JVM 255-argument ceiling), so `alt` has no control in the Map panel and reading
        // it would be a field the SDK honours and no author can set.
        .accessibilityLabel(mapCfg(block, "map_alt") as? String ?? "Map")
    }

    /// The map's drawn height, from whichever sizing mode the author chose.
    ///
    /// `aspect` is resolved against a 390pt reference width rather than the live container width.
    /// The container's width is not known at this point without a `GeometryReader`, and wrapping
    /// the block in one changes how it lays out inside a stack; 390 is the width the console
    /// preview composes at, so the two agree.
    private func mapHeight(_ block: ContentBlock) -> CGFloat {
        switch (mapCfg(block, "map_height_mode") as? String) ?? "fixed" {
        case "aspect":
            let ratio = (mapCfg(block, "map_aspect") as? String) ?? "16:9"
            let parts = ratio.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0 else { return 220 }
            return CGFloat(390.0 * parts[1] / parts[0])
        case "fill":
            // "Fill the step" is a tall block, not an unbounded one: a greedy `maxHeight: .infinity`
            // inside the step's scrolling stack collapses every sibling to nothing.
            return 520
        default:
            return CGFloat(mapDouble(block, "map_height") ?? 220)
        }
    }

    /// The place info card — a name, a line of description and optionally a photo.
    ///
    /// Only in `place` mode, and only when there is something to say: an empty card floating over a
    /// map is worse than no card. Returns nil rather than an empty view so the caller can decide
    /// the layout without reserving space for nothing.
    @ViewBuilder
    private func mapInfoCard(_ block: ContentBlock) -> (some View)? {
        let title = (mapCfg(block, "place_title") as? String) ?? ""
        let subtitle = (mapCfg(block, "place_subtitle") as? String) ?? ""
        let show = (mapCfg(block, "map_mode") as? String) == "place"
            && (mapCfg(block, "place_show_info") as? Bool) != false
            && !(title.isEmpty && subtitle.isEmpty)
        if show {
            HStack(spacing: 8) {
                if let img = (mapCfg(block, "place_image_url") as? String), !img.isEmpty,
                   let url = URL(string: img) {
                    BundledAsyncPhaseImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color.clear
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !title.isEmpty {
                        Text(title).font(.footnote.weight(.semibold))
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).opacity(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(hex: (block.field_config?["place_info_bg"]?.value as? String) ?? "#FFFFFF"))
            .foregroundColor(Color(hex: (block.field_config?["place_info_text"]?.value as? String) ?? "#111827"))
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(mapDouble(block, "place_info_radius") ?? 12)))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }

    /// What a host map view receives. Plain Foundation types only — a host should not have to
    /// import our DTOs to draw a map.
    private func mapResolvedConfig(_ block: ContentBlock) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in block.field_config ?? [:] { out[k] = v.value }
        out["resolved_stops"] = mapStops(block).map { ["lat": $0.lat, "lng": $0.lng] }
        return out
    }

    // MARK: - Custom View (SPEC-089d AC-026)

    @ViewBuilder
    private func customViewBlock(_ block: ContentBlock) -> some View {
        let key = block.view_key ?? ""
        if let factory = AppDNA.registeredCustomViews[key] {
            factory()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: block.height.map { CGFloat($0) }
                )
        } else if let placeholderUrl = block.placeholder_image_url, let url = URL(string: placeholderUrl) {
            BundledAsyncPhaseImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    placeholderTextView(block.placeholder_text ?? "[\(key)]")
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: block.height.map { CGFloat($0) })
        } else {
            placeholderTextView(block.placeholder_text ?? "[\(key)]")
        }
    }

    private func placeholderTextView(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(8)
    }
}

// MARK: - Social-login action dispatch

/// Which host actions a social-login provider button fires, in order.
///
/// The email provider in a `social_login` block is not actually OAuth — it emits `email_login` so
/// hosts can branch their auth handler cleanly. The legacy `social_login` action is dual-emitted this
/// release so existing handlers that switch on `social_login` + value == "email" keep working; the
/// legacy emit is removed in v1.1.0. Extracted from the button closure because a dual-emit that
/// silently degrades to a single emit is invisible to every test that can't reach inside a SwiftUI
/// `Button` action.
enum SocialLoginActionDispatcher {
    static func actions(forProviderType providerType: String) -> [(action: String, value: String?)] {
        if providerType == "email" {
            return [
                ("email_login", providerType),
                ("social_login", providerType), // deprecated; remove in v1.1.0
            ]
        }
        return [("social_login", providerType)]
    }
}

// MARK: - WrapLayout (Mrozu QA: row.wrap == true → FlowRow parity)

/// Flow layout that lays subviews left-to-right and wraps to the next line when
/// the available width is exceeded (chip/badge behavior). Mirrors Android
/// Compose FlowRow. iOS 16+ only; the row renderer falls back to HStack below that.
@available(iOS 16.0, *)
struct WrapLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxWidth {
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            x += sz.width + hSpacing
            rowHeight = max(rowHeight, sz.height)
            widest = max(widest, x - hSpacing)
        }
        let w = maxWidth.isFinite ? min(maxWidth, widest) : widest
        return CGSize(width: max(0, w), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + vSpacing; rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + hSpacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}

/// Upward-pointing triangle used by the page_indicator `dot_shape = "triangle"`.
struct PageDotTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// Media-gallery v2 (Mrozu QA) — continuous auto-scroll marquee. The image track is duplicated and
// offset by exactly one copy-width per cycle, so the loop wraps seamlessly (no jump). Only instantiated
// when gallery_autoscroll == true; a static gallery pays zero animation cost.
struct MediaGalleryAutoScrollRow: View {
    let images: [String]
    let itemW: CGFloat
    let itemH: CGFloat
    let cornerRadius: CGFloat
    let spacing: CGFloat
    let fill: Bool
    let cycleSeconds: Double

    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let tileW = fill ? geo.size.width : itemW
            let gap = fill ? 0 : spacing
            // One copy = n tiles + n gaps; shifting by this aligns the 2nd copy onto the 1st → seamless.
            let copyWidth = (tileW + gap) * CGFloat(images.count)
            HStack(spacing: gap) {
                ForEach(0..<(images.count * 2), id: \.self) { idx in
                    tile(images[idx % images.count], width: tileW)
                }
            }
            .offset(x: offset)
            .onAppear {
                offset = 0
                withAnimation(.linear(duration: max(cycleSeconds, 1)).repeatForever(autoreverses: false)) {
                    offset = -copyWidth
                }
            }
        }
        .frame(height: itemH)
        .clipped()
    }

    @ViewBuilder
    private func tile(_ urlString: String, width: CGFloat) -> some View {
        ZStack {
            Color(hex: "#2A2A2E")
            if let url = URL(string: urlString) {
                BundledAsyncPhaseImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .frame(width: width, height: itemH)
        .clipShape(RoundedRectangle(cornerRadius: fill ? 0 : cornerRadius))
    }
}

/// Mrozu QA (2026-08-04) — alarmy selectable gallery: the same static tile row as `mediaGalleryBlock`, but each
/// tile is tappable and opens a full-screen enlarged overlay of the selected image (`gallery_preview_on_select`).
/// Image preview only — video/gif/sound preview playback is net-new host media infra (deferred).
struct MediaGalleryPreviewRow: View {
    let images: [String]
    let itemW: CGFloat
    let itemH: CGFloat
    let cornerRadius: CGFloat
    let spacing: CGFloat
    let fill: Bool
    let galleryAlignment: Alignment

    @State private var previewURL: String? = nil

    var body: some View {
        GeometryReader { geo in
            let tileW = fill ? geo.size.width : itemW
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: fill ? 0 : spacing) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, urlString in
                        tile(urlString, width: tileW)
                            .contentShape(Rectangle())
                            .onTapGesture { previewURL = urlString }
                    }
                }
                .padding(.horizontal, fill ? 0 : 2)
                .frame(minWidth: geo.size.width, alignment: fill ? .leading : galleryAlignment)
            }
        }
        .frame(height: itemH)
        .fullScreenCover(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let urlString = previewURL, let url = URL(string: urlString) {
                    BundledAsyncPhaseImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                    .padding(20)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button { previewURL = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(20)
                    }
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { previewURL = nil }
        }
    }

    @ViewBuilder
    private func tile(_ urlString: String, width: CGFloat) -> some View {
        ZStack {
            Color(hex: "#2A2A2E")
            if let url = URL(string: urlString) {
                BundledAsyncPhaseImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .frame(width: width, height: itemH)
        .clipShape(RoundedRectangle(cornerRadius: fill ? 0 : cornerRadius))
    }
}


// MARK: - Template resolution (file scope)

/// The real whitelist + binding pass. It lived as a `private` method on the View above, which made
/// the WHITELIST untestable: a fixture could only call `resolveTemplateString` directly, proving the
/// resolver handles a token while proving nothing about whether this pass applies it to a given key.
/// Round-4 bug injection deleted the `label` line and the whole suite stayed green.
/// Same reason `RequiredFieldGate` and `mergeFieldConfigOverrides` are free functions.
func resolveBlockTemplates(
    _ block: ContentBlock,
    hookData: [String: Any]?,
    responses: [String: Any],
    // SPEC-446 R4 — the LIVE values typed on the current step, addressable as `{{step.field_id}}`.
    // resolveTemplateString has accepted a stepInputs map since the `step` root landed, but NO caller
    // ever passed one, so the console's "This Step (live)" picker group offered authors a namespace
    // that resolved to nothing on device. Declaring the parameter is not wiring it.
    stepInputs: [String: Any]? = nil
) -> ContentBlock {
        guard block.bindings != nil || blockContainsTemplates(block) else { return block }

        // Since ContentBlock is a struct with let properties, we use JSON round-trip to create a mutable copy.
        // This is the simplest approach without refactoring the entire model to use var properties.
        guard let data = try? JSONEncoder().encode(block),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return block
        }

        // AC-066: Resolve bindings map — override block properties from data context
        if let bindings = block.bindings {
            for (property, path) in bindings {
                if let resolved = resolveDotPath(path, responses: responses, hookData: hookData, userTraits: nil, sessionData: nil, stepInputs: stepInputs) {
                    json[property] = resolved
                }
            }
        }

        // AC-064: Resolve template strings in text fields
        if let text = json["text"] as? String, text.contains("{{") {
            json["text"] = resolveTemplateString(text, hookData: hookData, responses: responses, stepInputs: stepInputs)
        }
        if let label = json["field_label"] as? String, label.contains("{{") {
            json["field_label"] = resolveTemplateString(label, hookData: hookData, responses: responses, stepInputs: stepInputs)
        }
        if let placeholder = json["field_placeholder"] as? String, placeholder.contains("{{") {
            json["field_placeholder"] = resolveTemplateString(placeholder, hookData: hookData, responses: responses, stepInputs: stepInputs)
        }
        if let badgeText = json["badge_text"] as? String, badgeText.contains("{{") {
            json["badge_text"] = resolveTemplateString(badgeText, hookData: hookData, responses: responses, stepInputs: stepInputs)
        }
        if let toggleLabel = json["toggle_label"] as? String, toggleLabel.contains("{{") {
            json["toggle_label"] = resolveTemplateString(toggleLabel, hookData: hookData, responses: responses, stepInputs: stepInputs)
        }
        // RichText v2 — rich_text's primary content field is `markdown_content`;
        // it must run the SAME `{{var}}` interpolation as `text` so a rich_text
        // block referencing a prior-screen answer (e.g. "{{email}}", "{{word_count}}
        // words") resolves on device instead of rendering the literal token.
        // NOT a `label` entry here, deliberately. SPEC-446 §3c originally claimed Android resolving
        // block-level `label` and iOS not was a live parity bug; it is not. That field is a legacy
        // RATING key, and SPEC-401-A R61 removed `?: block.label` from the renderers precisely so it
        // stops reaching the screen — iOS never declaring it is the same decision, reached from the
        // other side. Writing json["label"] on iOS was a no-op that the JSON round-trip discarded on
        // decode, which is why deleting it left every test green. The REAL gap was option text, above.
        // SPEC-446 — a sibling stat reading `{{step.<field_id>}}` must resolve on the FIRST frame.
        // The control seeds its authored default after composition, so on that first pass the id is
        // absent from `stepInputs`, the token does not resolve, and the suppression below then DROPS
        // the stat entirely: the live-value card the reporter asked for simply was not there until
        // the user touched the slider. Authored defaults are therefore merged in UNDER the live
        // values, which always win.
        var effectiveStepInputs = stepInputs ?? [:]
        if let cfgForDefaults = json["field_config"] as? [String: Any],
           let statsForDefaults = cfgForDefaults["summary_stats"] as? [[String: Any]] {
            for s in statsForDefaults {
                guard let fid = s["field_id"] as? String, !fid.isEmpty,
                      effectiveStepInputs[fid] == nil, let def = s["default"] else { continue }
                effectiveStepInputs[fid] = def
            }
        }
        let stepInputs = effectiveStepInputs.isEmpty ? stepInputs : effectiveStepInputs

        // SPEC-446 R4 — OPTION text. `{{var}}` in a select/image-tile option was resolved by NOTHING
        // on either platform: the whitelist only ever touched the block's own top-level `label`. The
        // console's variable picker is available wherever an author types, options included, so this
        // rendered a raw token on BOTH platforms rather than differing between them — which is why
        // symmetric fixtures never noticed it.
        if let rawOpts = json["field_options"] as? [[String: Any]] {
            var optChanged = false
            let nextOpts: [[String: Any]] = rawOpts.map { opt in
                var next = opt
                for key in ["label", "subtitle", "leading_text"] {
                    if let s = opt[key] as? String, s.contains("{{") {
                        next[key] = resolveTemplateString(s, hookData: hookData, responses: responses, stepInputs: stepInputs)
                        optChanged = true
                    }
                }
                return next
            }
            if optChanged { json["field_options"] = nextOpts }
        }
        // SPEC-446 §2 — stats are an ARRAY OF DICTS nested inside field_config, so the resolver
        // has to walk into it. Every other entry here is a flat `json["key"] as? String`.
        if var cfg = json["field_config"] as? [String: Any],
           let rawStats = cfg["summary_stats"] as? [[String: Any]] {
            var changed = false
            let resolvedStats: [[String: Any]] = rawStats.map { stat in
                var next = stat
                for key in ["value", "label"] {
                    if let s = stat[key] as? String, s.contains("{{") {
                        next[key] = resolveTemplateString(s, hookData: hookData, responses: responses, stepInputs: stepInputs)
                        changed = true
                    }
                }
                return next
            }
            // SPEC-446 AC — "no raw {{token}} can reach the screen from a stat". resolveTemplateString
            // returns the LITERAL when a path misses and no `| fallback` was written, which is correct
            // for a headline (an author sees their typo) and wrong for a stat: it puts `{{responses.x}}`
            // in the big colored number on a summary card. Dropping the stat here rather than in the
            // renderer means no current or future renderer can leak it, and a fixture can see it as a
            // count. A stat whose LABEL alone is unresolved keeps its value and loses the caption.
            let safeStats: [[String: Any]] = resolvedStats.compactMap { stat in
                if let v = stat["value"] as? String, v.contains("{{") { return nil }
                if let l = stat["label"] as? String, l.contains("{{") {
                    var next = stat; next.removeValue(forKey: "label"); return next
                }
                return stat
            }
            if changed || safeStats.count != resolvedStats.count {
                cfg["summary_stats"] = safeStats
                json["field_config"] = cfg
            }
        }
        if let markdown = json["markdown_content"] as? String, markdown.contains("{{") {
            json["markdown_content"] = resolveTemplateString(markdown, hookData: hookData, responses: responses, stepInputs: stepInputs)
        }

        // SPEC-452 — RECURSE into container children.
        //
        // 🔴 Children never reached this resolver. `body` resolves each top-level block and then
        // hands it to `renderBlock`, but a container's children are rendered by `renderBlock(child)`
        // straight from `block.children`/`block.stack_children` — bypassing resolution entirely.
        // Resolving the container did not help either: everything above rewrites the container's OWN
        // top-level keys and never descended.
        //
        // So a `{{…}}` token or a `bindings` entry on a card INSIDE a row rendered unresolved, while
        // the identical block one level up resolved fine — and that is the ordinary recommendation-
        // card shape (image + title + subtitle nested in a `row`), i.e. exactly where per-item host
        // data lives. Android had the same gap, so no symmetric fixture could see it.
        //
        // Done here, rather than at each container's child-render site, because this is the one place
        // every container type passes through: row, stack, carousel, section_background and anything
        // added later all get it for free, and iOS/Android stay reachable-surface-identical.
        for key in ["children", "stack_children"] {
            guard let rawChildren = json[key] as? [[String: Any]] else { continue }
            let resolvedChildren: [[String: Any]] = rawChildren.map { childJSON in
                guard let childData = try? JSONSerialization.data(withJSONObject: childJSON),
                      let child = try? JSONDecoder().decode(ContentBlock.self, from: childData) else {
                    // Undecodable child: hand back the authored JSON untouched rather than dropping it.
                    return childJSON
                }
                let resolved = resolveBlockTemplates(
                    child, hookData: hookData, responses: responses, stepInputs: stepInputs
                )
                guard let outData = try? JSONEncoder().encode(resolved),
                      let out = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
                    return childJSON
                }
                return out
            }
            json[key] = resolvedChildren
        }

        // Decode back to ContentBlock
        if let updatedData = try? JSONSerialization.data(withJSONObject: json),
           let resolved = try? JSONDecoder().decode(ContentBlock.self, from: updatedData) {
            return resolved
        }
        return block
}

/// Gate for the pass above. Returning `false` here SKIPS resolution entirely, so every key the
/// resolver handles must be represented — otherwise the block short-circuits and ships raw `{{tokens}}`.
func blockContainsTemplates(_ block: ContentBlock) -> Bool {
        if let text = block.text, text.contains("{{") { return true }
        if let label = block.field_label, label.contains("{{") { return true }
        if let placeholder = block.field_placeholder, placeholder.contains("{{") { return true }
        if let badgeText = block.badge_text, badgeText.contains("{{") { return true }
        if let toggleLabel = block.toggle_label, toggleLabel.contains("{{") { return true }
        // RichText v2 — gate the resolve pass on rich_text markdown too.
        if let markdown = block.markdown_content, markdown.contains("{{") { return true }
        // SPEC-446 R4 — the resolver handles OPTION text and the nested `field_config.summary_stats`,
        // but this gate did not, so a block whose ONLY templates live there returned early and rendered
        // the raw token. That is the COMMON summary-screen shape: static headline, variables in the
        // stats. Android was missing the same two.
        if let opts = block.field_options {
            for o in opts {
                for s in [o.label, o.subtitle, o.leading_text] {
                    if let s, s.contains("{{") { return true }
                }
            }
        }
        if let stats = block.field_config?["summary_stats"]?.value as? [Any] {
            for case let stat as [String: Any] in stats {
                for key in ["value", "label"] {
                    if let s = stat[key] as? String, s.contains("{{") { return true }
                }
            }
        }
        // SPEC-452 — a CONTAINER whose own keys hold no tokens but whose CHILDREN do must not
        // short-circuit, or the recursion added to the resolver never runs. This is the same trap
        // the note above this function warns about: every key the resolver handles has to be
        // represented here, and the resolver now handles children.
        for child in (block.children ?? []) + (block.stack_children ?? []) {
            if child.bindings != nil || blockContainsTemplates(child) { return true }
        }
        return false
}

/// SPEC-446 §3 — the control a Summary Screen stat can host.
///
/// Kept as its own View, not inlined into `summaryScreenBlock`, because it owns writes to
/// `inputValues` and a `@Binding` mutated inside a `ForEach` closure in a large `some View`
/// builder is where SwiftUI type-checking gets slow and where a stale-value bug hides.
///
/// The value it writes is what a LATER step reads through `{{responses.<field_id>}}` and what a
/// stat on the SAME card reads live through `{{step.<field_id>}}` — the case the reporter actually
/// described. That live path works because the renderer passes `inputValues` into the template
/// resolver as `stepInputs`, so a write here recomposes the sibling stat.
struct SummaryStatInput: View {
    let stat: [String: Any]
    let fieldId: String
    let valueColor: Color
    let labelColor: Color
    /// #593 — authored sizes, so a stat hosting a control matches one that shows a fixed value.
    var labelSize: CGFloat = 13
    var valueSize: CGFloat = 24
    let label: String
    @Binding var inputValues: [String: Any]
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }
    var blockId: String = ""

    private func statDouble(_ key: String, _ fallback: Double) -> Double {
        if let d = stat[key] as? Double { return d }
        if let i = stat[key] as? Int { return Double(i) }
        // A numeric STRING survives here even though normalize-step-numerics coerces on save:
        // a flow imported or AI-generated outside that path still reaches the device as a string.
        if let s = stat[key] as? String, let d = Double(s) { return d }
        return fallback
    }

    /// Seed order, and the middle entry is the point of #558.
    ///
    /// 1. what the user has already set on this step
    /// 2. the stat's own resolved `value` — this is the PRE-FILL. `value: "{{responses.group_size}}"`
    ///    has already been through the resolver by the time this renders, so it is the number an
    ///    earlier answer produced. Without this the control ignored it and opened on the authored
    ///    default, which is the "pre-filled value I cannot adjust" the reporter described: the
    ///    number shown before was not the number the control started from.
    /// 3. the authored `default`, for a stat with no binding
    /// 4. `min`
    ///
    /// Real data beats a static default, which is why `value` is checked first of the two.
    private var current: Double {
        if let d = inputValues[fieldId] as? Double { return d }
        if let i = inputValues[fieldId] as? Int { return Double(i) }
        if let s = inputValues[fieldId] as? String, let d = Double(s) { return d }
        if let v = statDoubleOrNil("value") { return v }
        return statDouble("default", statDouble("min", 0))
    }

    /// `value` is display text and is often NOT numeric ("3 nights", an unresolved token). Only a
    /// cleanly numeric one can seed a control, so this returns nil rather than a fallback.
    private func statDoubleOrNil(_ key: String) -> Double? {
        if let d = stat[key] as? Double { return d }
        if let i = stat[key] as? Int { return Double(i) }
        if let s = stat[key] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private func write(_ v: Double) {
        // Only the range matters here: snapping is the control's own job, so this path does not
        // need the step at all.
        let lo = statDouble("min", 0)
        let hi = max(statDouble("max", 100), lo + 0.0001)
        let clamped = Swift.min(Swift.max(v, lo), hi)
        // Whole numbers go back as Int so `{{step.x}}` renders "4" and not "4.0" — the raw Double
        // is what a summary card shows the user, so the formatting is the feature.
        inputValues[fieldId] = clamped.rounded() == clamped ? Int(clamped) : clamped
        onInteract(blockId, "change", String(describing: inputValues[fieldId] ?? ""))
    }

    var body: some View {
        // A step at or below zero means "continuous" — the whole range in one stride — rather than
        // a 0.0001 floor, which on Android handed Compose 290,001 tick marks to lay out and would
        // hang the device on one `step: 0` typed into the editor. Kept identical here so the two
        // platforms agree about what a degenerate step means.
        let rawStep = statDouble("step", 1)
        let lo = statDouble("min", 0)
        let hi = max(statDouble("max", 100), lo + 0.0001)
        let stepV = rawStep > 0 ? rawStep : (hi - lo)
        let shown = current.rounded() == current ? String(Int(current)) : String(current)

        VStack(alignment: .leading, spacing: 6) {
            Text(shown).font(.system(size: valueSize, weight: .bold)).foregroundColor(valueColor)
            Text(label).font(.system(size: labelSize)).foregroundColor(labelColor)
            if (stat["input"] as? String) == "stepper" {
                HStack(spacing: 12) {
                    Button { write(current - stepV) } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 22)).foregroundColor(valueColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Decrease \(label)")
                    Button { write(current + stepV) } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundColor(valueColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Increase \(label)")
                }
            } else {
                // Two Sliders, not one with a computed step. `step: (hi - lo)` is NOT continuous —
                // it snaps to the two endpoints, so a stat authored with `step: 0` would let the user
                // pick only the minimum or the maximum. Android reads the same input as continuous
                // (Compose `steps = 0`), so the single-expression version was a silent divergence in
                // the degenerate case round 14 introduced.
                if rawStep > 0 {
                    Slider(value: Binding(get: { current }, set: { write($0) }), in: lo...hi, step: stepV)
                        .accentColor(valueColor)
                        .accessibilityLabel(label)
                        .accessibilityValue(shown)
                } else {
                    Slider(value: Binding(get: { current }, set: { write($0) }), in: lo...hi)
                        .accentColor(valueColor)
                        .accessibilityLabel(label)
                        .accessibilityValue(shown)
                }
            }
        }
        .onAppear {
            // Seed the authored default so a stat that is NOT required still reports a value, and
            // so the sibling `{{step.x}}` stat has something to show before the first drag.
            if inputValues[fieldId] == nil, stat["default"] != nil || statDoubleOrNil("value") != nil {
                write(current)
            }
        }
    }
}

// MARK: - Map URL composition (SPEC-451)
//
// File scope rather than methods on the renderer view, and `internal` rather than `private`, so the
// shared-fixture runner drives the SAME code the renderer does. A test-only copy of a URL recipe
// that exists three times already would pass forever while the renderer drifted underneath it —
// which is the exact failure the fixture exists to catch.

/// Google's encoded-polyline format, which is what Mapbox's `path` overlay takes.
///
/// 🔴 Implemented here, in TypeScript for the console preview, and again in Kotlin — three
/// times, because Mapbox forbids us proxying or caching the image, so there is no server-side
/// composer to be the single source of truth. A shared fixture pins the composed URL across all
/// three; without it a divergence would show a customer a different map than the console did.
internal func encodePolyline(_ points: [(Double, Double)]) -> String {
    var lastLat = 0, lastLng = 0
    var out = ""
    func chunk(_ v: Int) -> String {
        var value = v < 0 ? ~(v << 1) : (v << 1)
        var s = ""
        while value >= 0x20 {
            s.append(Character(UnicodeScalar(UInt8(0x20 | (value & 0x1f)) + 63)))
            value >>= 5
        }
        s.append(Character(UnicodeScalar(UInt8(value) + 63)))
        return s
    }
    for (lat, lng) in points {
        let iLat = Int((lat * 1e5).rounded()), iLng = Int((lng * 1e5).rounded())
        out += chunk(iLat - lastLat) + chunk(iLng - lastLng)
        lastLat = iLat; lastLng = iLng
    }
    return out
}

/// `#6366F1` -> `6366f1`. Mapbox overlays take a bare hex; anything else falls back rather
/// than emitting an overlay the API will reject.
/// A readable text colour for the map's fallback state, given the authored surface behind it.
///
/// 🔴 Found by a golden, not by reading: the label used `.secondary`, so on a dark authored surface
/// it rendered dark-grey-on-near-black and was effectively invisible. The fallback exists so a map
/// that cannot be drawn is LABELLED rather than blank, and an unreadable label is a blank space
/// with extra steps.
///
/// Relative luminance with the sRGB coefficients, thresholded at 0.5 — deliberately the plainest
/// formula all three implementations can share, since the console preview must agree with both
/// natives about a colour nobody authored.
internal func mapFallbackTextColor(_ surface: String?, _ authored: String?) -> String {
    // The authored value stays on the LEFT of the coalescer in every return below, rather than
    // being short-circuited at the top. Same result, and it keeps the shape the authorability gate
    // reads as "a default behind an editable field" — which these literals genuinely are.
    let trimmed = authored?.trimmingCharacters(in: .whitespaces)
    let picked = (trimmed?.isEmpty == false) ? trimmed : nil
    let hex = (surface ?? "#E5E7EB").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
    guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return picked ?? "#374151" }
    func channel(_ range: Range<String.Index>) -> Double {
        Double(UInt8(hex[range], radix: 16) ?? 0) / 255.0
    }
    let s = hex.startIndex
    let r = channel(s..<hex.index(s, offsetBy: 2))
    let g = channel(hex.index(s, offsetBy: 2)..<hex.index(s, offsetBy: 4))
    let b = channel(hex.index(s, offsetBy: 4)..<hex.index(s, offsetBy: 6))
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.5 ? (picked ?? "#F9FAFB") : (picked ?? "#374151")
}

internal func mapboxHex(_ raw: String?, _ fallback: String) -> String {
    let s = (raw ?? fallback).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
    let ok = s.count == 6 && s.allSatisfy { $0.isHexDigit }
    return (ok ? s : fallback.replacingOccurrences(of: "#", with: "")).lowercased()
}

internal func mapCfg(_ block: ContentBlock, _ key: String) -> Any? {
    block.field_config?[key]?.value
}

internal func mapDouble(_ block: ContentBlock, _ key: String) -> Double? {
    if let d = mapCfg(block, key) as? Double { return d }
    if let i = mapCfg(block, key) as? Int { return Double(i) }
    return nil
}

/// The stops this map draws, from whichever source won.
///
/// Precedence is delegate > variable > authored, and it is resolved BEFORE this point — the
/// renderer only ever sees the winner in `field_config.map_stops`. Anything without both
/// coordinates is dropped: a title alone is not a place.
internal func mapStops(_ block: ContentBlock) -> [(lat: Double, lng: Double)] {
    if (mapCfg(block, "map_mode") as? String) == "place" {
        guard let lat = mapDouble(block, "place_lat"), let lng = mapDouble(block, "place_lng") else { return [] }
        return [(lat, lng)]
    }
    let raw = (mapCfg(block, "map_stops") as? [Any]) ?? []
    return raw.compactMap { item in
        // `stop`, not `m`: a one-letter name here matches the authorability scanner's DTO read
        // shape and reports `lat`/`lng` as unauthorable BLOCK fields. They are a stop's members.
        guard let stop = item as? [String: Any] else { return nil }
        let lat = (stop["lat"] as? Double) ?? (stop["lat"] as? Int).map(Double.init)
        let lng = (stop["lng"] as? Double) ?? (stop["lng"] as? Int).map(Double.init)
        guard let la = lat, let ln = lng, la.isFinite, ln.isFinite else { return nil }
        return (la, ln)
    }
}

/// Percent-encode everything that is not an ASCII letter or digit.
///
/// 🔴 Deliberately stricter than any built-in, and NOT interchangeable with one. The three
/// implementations have three different escapers — JavaScript's `encodeURIComponent` leaves
/// `!\'()*-._~` alone, Java's `URLEncoder` turns a space into `+` and escapes `~`, Swift's
/// `.urlQueryAllowed` leaves more still. An encoded polyline contains `~`, backtick, `@`, `?`
/// and backslashes, so those differences produce three different URLs for one route. Escaping
/// everything non-alphanumeric is the one rule all three can implement identically.
internal func percentEncodeStrict(_ input: String) -> String {
    var out = ""
    for byte in Array(input.utf8) {
        let c = Character(UnicodeScalar(byte))
        if c.isASCII && (c.isLetter || c.isNumber) {
            out.append(c)
        } else {
            out += String(format: "%%%02X", byte)
        }
    }
    return out
}

/// `12.0` -> `"12"`, `0.85` -> `"0.85"`. Swift and Kotlin print a trailing `.0` where
/// JavaScript does not, which alone would break the shared fixture on a whole-number latitude.
internal func formatCoord(_ v: Double) -> String {
    v == v.rounded() && v.isFinite ? String(Int(v)) : String(v)
}

/// The encoded polyline this map draws, from whichever of the three route sources won.
///
/// Precedence — and it is a real ordering, not a tidy-looking chain:
///
///  1. `map_route_polyline` set by the DELEGATE. The merge writes it and clears
///     `map_route_variable`, so a host that answers `onBeforeStepRender` always wins.
///  2. `map_route_variable` — a `{{token}}` resolved against the flow's own state. Beats an
///     authored polyline because an author who wired a variable meant the variable; the static
///     one is the value they left behind for when it does not resolve.
///  3. `map_route_polyline` as authored — a fixed route pasted into the panel.
///  4. the stops, joined in order, which is a straight line between them and not a road route.
internal func mapRoutePolyline(_ block: ContentBlock) -> String? {
    if let variable = (mapCfg(block, "map_route_variable") as? String), !variable.isEmpty {
        let resolved = variable.interpolated().trimmingCharacters(in: .whitespacesAndNewlines)
        // An unresolved `{{token}}` comes back verbatim. Drawing it as a polyline would produce
        // a line through the Atlantic, so an unresolved variable falls through to the authored
        // route rather than replacing it with nonsense.
        if !resolved.isEmpty && !resolved.contains("{{") { return resolved }
    }
    return (mapCfg(block, "map_route_polyline") as? String).flatMap { $0.isEmpty ? nil : $0 }
}

internal func mapStaticURL(_ block: ContentBlock, token: String?, width: CGFloat, height: CGFloat) -> URL? {
    guard let token, !token.isEmpty else { return nil }
    let styles = [
        "streets": "mapbox/streets-v12", "outdoors": "mapbox/outdoors-v12",
        "satellite": "mapbox/satellite-v9", "satellite_streets": "mapbox/satellite-streets-v12",
        "light": "mapbox/light-v11", "dark": "mapbox/dark-v11",
    ]
    let style = styles[(mapCfg(block, "map_style") as? String) ?? "streets"] ?? styles["streets"]!
    let isPlace = (mapCfg(block, "map_mode") as? String) == "place"
    let stops = mapStops(block)
    var overlays: [String] = []

    // Route BEFORE markers, so pins draw on top of the line rather than under it.
    let routeOn = !isPlace && (mapCfg(block, "route_show") as? Bool) != false
    if routeOn {
        let encoded = mapRoutePolyline(block)
            ?? (stops.count >= 2 ? encodePolyline(stops.map { ($0.lat, $0.lng) }) : nil)
        if let e = encoded, !e.isEmpty {
            let w = Int(mapDouble(block, "route_width") ?? 4)
            let c = mapboxHex(mapCfg(block, "route_color") as? String, "6366f1")
            let o = min(max(mapDouble(block, "route_opacity") ?? 1, 0), 1)
            let escaped = percentEncodeStrict(e)
            // The casing is a SECOND, WIDER path emitted BEFORE the route, so the route draws
            // on top of it and what shows is an outline. Mapbox's static API has no
            // stroke-outline primitive; two stacked paths is how every static-map product does
            // this. Opaque on purpose — a translucent outline over satellite imagery is none.
            let casingW = Int(mapDouble(block, "route_casing_width") ?? 2)
            if casingW > 0 {
                let casing = mapboxHex(mapCfg(block, "route_casing_color") as? String, "ffffff")
                overlays.append("path-\(w + casingW * 2)+\(casing)-1(\(escaped))")
            }
            overlays.append("path-\(w)+\(c)-\(formatCoord(o))(\(escaped))")
        }
    }
    let marker = mapboxHex(mapCfg(block, "marker_color") as? String, "6366f1")
    let startMarker = mapboxHex(mapCfg(block, "marker_start_color") as? String,
                                (mapCfg(block, "marker_color") as? String) ?? "6366f1")
    let markerStyle = (mapCfg(block, "marker_style") as? String) ?? "numbered"
    // Mapbox static offers exactly two marker sizes, `pin-s` and `pin-l`. The console's slider
    // is a pixel value because that is what an author thinks in; it lands in whichever of the
    // two is closer. Pretending to honour 41px exactly would be a nicer control and a false one.
    let pinSize = (mapDouble(block, "marker_size") ?? 28) >= 32 ? "pin-l" : "pin-s"
    let customMarker: String? = markerStyle == "custom"
        ? (mapCfg(block, "marker_image_url") as? String).flatMap { $0.isEmpty ? nil : $0 }
        : nil
    for (i, s) in stops.enumerated() {
        let at = "(\(formatCoord(s.lng)),\(formatCoord(s.lat)))"
        if let custom = customMarker {
            // `url-` takes a percent-encoded PNG/JPG URL. Mapbox fetches it itself, so it must
            // be publicly reachable — the console's uploader requires a remote URL for exactly
            // this reason.
            overlays.append("url-\(percentEncodeStrict(custom))\(at)")
            continue
        }
        // `pin-s-<label>` holds ONE character, so past 9 stops the number is dropped rather
        // than rendering a truncated, wrong one. `pin` style never labels.
        let label = (markerStyle == "numbered" && stops.count <= 9) ? "-\(i + 1)" : ""
        overlays.append("\(pinSize)\(label)+\(i == 0 ? startMarker : marker)\(at)")
    }
    let overlayPart = overlays.isEmpty ? "" : overlays.joined(separator: ",") + "/"

    // `auto` fits the overlays. With none there is nothing to fit and Mapbox treats it as an
    // error, so an explicit viewport is required; a single place is always centred on itself.
    let fit = !isPlace && (mapCfg(block, "map_fit_to_stops") as? Bool) != false && !overlays.isEmpty
    let centreLat = isPlace ? (mapDouble(block, "place_lat") ?? 47.6205) : (mapDouble(block, "map_center_lat") ?? 47.6205)
    let centreLng = isPlace ? (mapDouble(block, "place_lng") ?? -122.3493) : (mapDouble(block, "map_center_lng") ?? -122.3493)
    let viewport = fit
        ? "auto"
        : "\(formatCoord(centreLng)),\(formatCoord(centreLat)),\(Int(mapDouble(block, "map_zoom") ?? 12)),0"

    let w = Int(max(1, width.rounded())), h = Int(max(1, height.rounded()))
    // The token is `[A-Za-z0-9._-]` by construction, so it goes through unescaped — the same
    // choice the other two implementations make, and it keeps the URL readable in a log.
    return URL(string: "https://api.mapbox.com/styles/v1/\(style)/static/\(overlayPart)\(viewport)/\(w)x\(h)@2x?access_token=\(token)")
}
