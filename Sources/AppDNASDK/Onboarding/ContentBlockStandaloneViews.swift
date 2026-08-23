import SwiftUI
import MapKit
import PhotosUI
// MARK: - Rating Block View (SPEC-089d AC-019)

/// Stateful star rating input rendered as an independent SwiftUI view.
struct RatingBlockView: View {
    let block: ContentBlock
    let onAction: (_ action: String, _ actionValue: String?) -> Void

    @State private var selectedRating: Double = 0

    var body: some View {
        let maxStars = max(1, block.max_stars ?? 5)  // clamp ≥1 — ForEach(1...maxStars) traps on 0/negative (mirrors FormInputRatingBlock)
        let starSz = CGFloat(block.star_size ?? 32)
        let filledCol = Color(hex: block.filled_color ?? "#FBBF24")
        let emptyCol = Color(hex: block.empty_color ?? "#D1D5DB")
        let halfEnabled = block.allow_half ?? false

        VStack(spacing: 8) {
            if let label = block.rating_label {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            HStack(spacing: 4) {
                ForEach(1...maxStars, id: \.self) { index in
                    starImage(for: Double(index), filled: filledCol, empty: emptyCol, halfEnabled: halfEnabled)
                        .font(.system(size: starSz))
                        .onTapGesture {
                            selectedRating = Double(index)
                        }
                        .gesture(
                            halfEnabled ?
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let halfThreshold = starSz / 2
                                    if value.location.x < halfThreshold {
                                        selectedRating = Double(index) - 0.5
                                    } else {
                                        selectedRating = Double(index)
                                    }
                                }
                            : nil
                        )
                        .accessibilityLabel("\(index) star\(index > 1 ? "s" : "")")
                }
            }
        }
        .onAppear {
            selectedRating = block.default_rating ?? 0
        }
        .accessibilityElement(children: .combine)
        // Round-29 — announce the half value when allow_half is on (matches Android TalkBack); was
        // unconditional Int() so VoiceOver said "2 of 5 stars" for a 2.5 selection.
        .accessibilityValue(halfEnabled
            ? "\(String(format: "%.1f", selectedRating)) of \(maxStars) stars"
            : "\(Int(selectedRating)) of \(maxStars) stars")
    }

    @ViewBuilder
    private func starImage(for value: Double, filled: Color, empty: Color, halfEnabled: Bool) -> some View {
        if selectedRating >= value {
            Image(systemName: "star.fill")
                .foregroundColor(filled)
        } else if halfEnabled && selectedRating >= value - 0.5 {
            Image(systemName: "star.leadinghalf.filled")
                .foregroundColor(filled)
        } else {
            Image(systemName: "star")
                .foregroundColor(empty)
        }
    }
}

// MARK: - Countdown Timer Block View (SPEC-089d AC-018)

/// Stateful countdown timer driven by `Timer.publish`.
struct CountdownTimerBlockView: View {
    let block: ContentBlock
    let onAction: (_ action: String, _ actionValue: String?) -> Void

    @State private var remainingSeconds: Int = 0
    @State private var initialSeconds: Int = 0
    @State private var expired: Bool = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if expired {
                expiredView
            } else {
                // SPEC-419 pass-15 #10 — honor timer_variant (digital | circular | flip | bar)
                switch block.timer_variant ?? "digital" {
                case "circular": circularTimerView
                case "flip": flipTimerView
                case "bar": barTimerView
                default: digitalTimerView
                }
            }
        }
        .onAppear {
            initialSeconds = initialRemainingSeconds
            remainingSeconds = initialSeconds
        }
        .onReceive(timer) { _ in
            guard !expired else { return }
            if remainingSeconds > 0 {
                remainingSeconds -= 1
            }
            if remainingSeconds <= 0 {
                expired = true
                handleExpiry()
            }
        }
    }

    // Initial countdown value. For target_type == "fixed_datetime" (parity with Android
    // ContentBlockRenderer.kt) parse target_datetime as an absolute ISO-8601 UTC instant
    // and count down the remaining seconds; otherwise fall back to duration_seconds.
    private var initialRemainingSeconds: Int {
        if block.target_type == "fixed_datetime", let iso = block.target_datetime, !iso.isEmpty {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let target = fmt.date(from: iso) {
                let remaining = Int(target.timeIntervalSinceNow)
                return max(0, remaining)
            }
        }
        return block.duration_seconds ?? 300
    }

    // Accent color shared across all timer variants.
    private var accentColor: Color {
        Color(hex: block.accent_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
    }

    // h/m/s segment strings (gated by show_* flags), matching the preview.
    private var segmentStrings: [String] {
        let days = remainingSeconds / 86400
        let hours = (remainingSeconds % 86400) / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60
        var segs: [String] = []
        if block.show_days != false && days > 0 { segs.append(String(format: "%02d", days)) }
        if block.show_hours != false { segs.append(String(format: "%02d", hours)) }
        if block.show_minutes != false { segs.append(String(format: "%02d", minutes)) }
        if block.show_seconds != false { segs.append(String(format: "%02d", seconds)) }
        return segs
    }

    // SPEC-419 pass-15 #28 — default unit labels hrs/min/sec to match preview (was Hours/Min/Sec).
    private var labelStrings: [String] {
        let lbls = block.labels
        let days = remainingSeconds / 86400
        var arr: [String] = []
        if block.show_days != false && days > 0 { arr.append(lbls?.days ?? "days") }
        if block.show_hours != false { arr.append(lbls?.hours ?? "hrs") }
        if block.show_minutes != false { arr.append(lbls?.minutes ?? "min") }
        if block.show_seconds != false { arr.append(lbls?.seconds ?? "sec") }
        return arr
    }

    private var barFraction: CGFloat {
        // Denominator is the captured initial value (parity with Android's initialSeconds),
        // NOT duration_seconds — fixed_datetime bars would otherwise stay pinned at 100%.
        return min(max(CGFloat(remainingSeconds) / CGFloat(max(initialSeconds, 1)), 0), 1)
    }

    // Digital variant (default): HStack of time unit columns
    private var digitalTimerView: some View {
        let accentCol = accentColor
        let fontSize = CGFloat(block.font_size ?? 28)
        let lbls = block.labels

        let days = remainingSeconds / 86400
        let hours = (remainingSeconds % 86400) / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60

        return HStack(spacing: 16) {
            if block.show_days != false && days > 0 {
                timerUnit(value: days, label: lbls?.days ?? "days", fontSize: fontSize, accent: accentCol)
            }
            if block.show_hours != false {
                timerUnit(value: hours, label: lbls?.hours ?? "hrs", fontSize: fontSize, accent: accentCol)
            }
            if block.show_minutes != false {
                timerUnit(value: minutes, label: lbls?.minutes ?? "min", fontSize: fontSize, accent: accentCol)
            }
            if block.show_seconds != false {
                timerUnit(value: seconds, label: lbls?.seconds ?? "sec", fontSize: fontSize, accent: accentCol)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // SPEC-419 pass-15 #11 — digits use accent_color, unit labels use secondary grey (matches preview).
    private func timerUnit(value: Int, label: String, fontSize: CGFloat, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%02d", value))
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // SPEC-419 pass-15 #10 — circular variant: 75% accent ring + joined digits in center.
    private var circularTimerView: some View {
        let accentCol = accentColor
        return ZStack {
            Circle().stroke(Color(hex: "#E5E7EB"), lineWidth: 4)
            Circle().trim(from: 0, to: 0.75)
                .stroke(accentCol, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(segmentStrings.joined(separator: ":"))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(accentCol)
        }
        .frame(width: 80, height: 80)
        .frame(maxWidth: .infinity)
    }

    // SPEC-419 pass-15 #10 — flip variant: each segment in a tinted card, label below.
    private var flipTimerView: some View {
        let accentCol = accentColor
        let lbls = labelStrings
        return HStack(spacing: 8) {
            ForEach(Array(segmentStrings.enumerated()), id: \.offset) { i, seg in
                VStack(spacing: 4) {
                    Text(seg)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(accentCol)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#F1F5F9")))
                    Text(i < lbls.count ? lbls[i] : "")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // SPEC-419 pass-15 #10 — bar variant: time + "remaining" + shrinking accent bar.
    private var barTimerView: some View {
        let accentCol = accentColor
        return VStack(spacing: 8) {
            HStack {
                Text(segmentStrings.joined(separator: ":"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(accentCol)
                Spacer()
                Text("remaining")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: "#E5E7EB")).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(accentCol).frame(width: geo.size.width * barFraction, height: 8)
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var expiredView: some View {
        switch block.on_expire_action {
        case "hide":
            EmptyView()
        case "show_expired_text":
            Text(block.expired_text ?? "Time's up!")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        default:
            // auto_advance or no action specified -- show brief expired text
            Text(block.expired_text ?? "Time's up!")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func handleExpiry() {
        if block.on_expire_action == "auto_advance" {
            onAction("next", nil)
        }
    }
}

// MARK: - Animated Loading Block View (SPEC-089d AC-017)

/// Stateful animated loading / checklist block driven by sequential timers.
struct AnimatedLoadingBlockView: View {
    let block: ContentBlock
    let onAction: (_ action: String, _ actionValue: String?) -> Void

    @State private var completedCount: Int = 0
    @State private var overallProgress: CGFloat = 0
    @State private var timerCancellable: Timer? = nil
    @State private var spinAngle: Double = 0

    var body: some View {
        let variant = block.loading_variant ?? "checklist"
        let itemList = block.loading_items ?? []
        let progressCol = Color(hex: block.progress_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let checkCol = Color(hex: block.check_color ?? "#22C55E")
        let totalMs = block.total_duration_ms ?? itemList.reduce(0) { $0 + ($1.duration_ms ?? 1000) }

        let loadingMsg = block.loading_text
        let loadingMsgPos = block.loading_text_position ?? "below"
        let loadingMsgSize = CGFloat(block.loading_text_size ?? 15)
        let loadingMsgColor = block.loading_text_color.map { Color(hex: $0) } ?? Color(hex: block.text_color ?? "#9CA3AF")
        // Progress/Loading v2 — loading message horizontal alignment (default center).
        let loadingMsgAlign = block.loading_text_align ?? "center"
        let loadingMsgTextAlign: TextAlignment = loadingMsgAlign == "left" ? .leading : loadingMsgAlign == "right" ? .trailing : .center
        let loadingMsgFrameAlign: Alignment = loadingMsgAlign == "left" ? .leading : loadingMsgAlign == "right" ? .trailing : .center

        VStack(spacing: 16) {
            // Percentage is rendered inside each variant (circular ring center, linear bar, etc.)
            // to avoid duplicate display. See loadingVariantView for per-variant rendering.

            // EPIC-3 — configurable loading message with independent position/size/color/align.
            // SPEC-443 (#547) — when an explicit order is authored on the linear variant, the
            // variant view places the message itself, so it must not also be drawn here.
            let orderOwnsMessage = (variant == "linear" && loadingOrder != nil)
            if let loadingMsg, loadingMsgPos == "above", !orderOwnsMessage {
                Text(loadingMsg)
                    .font(.system(size: loadingMsgSize))
                    .foregroundColor(loadingMsgColor)
                    .multilineTextAlignment(loadingMsgTextAlign)
                    .frame(maxWidth: .infinity, alignment: loadingMsgFrameAlign)
            }
            loadingVariantView(variant: variant, itemList: itemList, progressCol: progressCol, checkCol: checkCol)
            if let loadingMsg, loadingMsgPos == "below", !orderOwnsMessage {
                Text(loadingMsg)
                    .font(.system(size: loadingMsgSize))
                    .foregroundColor(loadingMsgColor)
                    .multilineTextAlignment(loadingMsgTextAlign)
                    .frame(maxWidth: .infinity, alignment: loadingMsgFrameAlign)
            }
        }
        .onAppear {
            // EPIC-3 — static progress_value override (snapshot/preview): hold the value, no timer.
            if let pv = block.progress_value {
                overallProgress = CGFloat(pv > 1 ? pv / 100 : pv)
            } else {
                startSequentialTimer(items: itemList, totalMs: totalMs)
            }
        }
        .onDisappear {
            timerCancellable?.invalidate()
        }
    }

    /// Type-erased loading variant to avoid @ViewBuilder switch in body.
    /// SPEC-440 (#547) — per-sub-element sizing. Both were hardcoded, so the element's single
    /// size parameter scaled the bar and the item text together. Computed properties rather
    /// than locals in `body` because the variant builders below need them too.
    /// Read off `field_config`, NOT as top-level ContentBlock params: the Kotlin data class
    /// mirroring this type is at the JVM 255-constructor-arg ceiling, and two more top-level
    /// fields broke Android's ContentBlock at runtime with a ClassFormatError.
    private var loadingBarHeight: CGFloat {
        CGFloat((block.field_config?["loading_bar_height"]?.value as? Double)
            ?? (block.field_config?["loading_bar_height"]?.value as? Int).map(Double.init)
            ?? 8)
    }
    private var loadingItemSize: CGFloat {
        CGFloat((block.field_config?["loading_item_size"]?.value as? Double)
            ?? (block.field_config?["loading_item_size"]?.value as? Int).map(Double.init)
            ?? 14)
    }

    /// SPEC-443 (#547) — explicit top-to-bottom order of the Loading element's sub-elements.
    /// The only control before this was "message above/below the indicator", which cannot
    /// express bar -> message -> items. Absent = today's arrangement, so existing flows are
    /// unchanged. Applies to the `linear` variant, the one with all three sub-elements.
    private var loadingOrder: [String]? {
        (block.field_config?["loading_order"]?.value as? [Any])?.compactMap { $0 as? String }
    }

    // The variant builders run outside `body`, so these mirror the locals it computes.
    private var loadingMsgPosValue: String { block.loading_text_position ?? "below" }
    private var loadingMsgSizeValue: CGFloat { CGFloat(block.loading_text_size ?? 15) }
    private var loadingMsgColorValue: Color {
        block.loading_text_color.map { Color(hex: $0) } ?? Color(hex: block.text_color ?? "#9CA3AF")
    }

    private func loadingVariantView(variant: String, itemList: [LoadingItemConfig], progressCol: Color, checkCol: Color) -> AnyView {
        switch variant {
        case "orbiting_icons":
            return AnyView(OrbitingIconsLoaderView(
                block: block,
                items: itemList,
                progress: overallProgress,
                completedCount: completedCount,
                progressCol: progressCol
            ))

        case "circular":
            return AnyView(
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: max(0.05, overallProgress))
                            .stroke(progressCol, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90 + spinAngle))
                            .animation(.linear(duration: 0.3), value: overallProgress)
                        if block.show_percentage == true {
                            Text("\(Int(overallProgress * 100))%")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(progressCol)
                        }
                    }
                    .frame(width: 80, height: 80)
                    .padding(8) // Ensure circle stroke isn't clipped
                    .onAppear { withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { spinAngle = 360 } }

                    // Show current loading item label
                    if completedCount < itemList.count {
                        Text(itemList[completedCount].label ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                            .animation(.easeInOut, value: completedCount)
                    }
                }
                .frame(maxWidth: .infinity)
            )

        case "ring":
            // EPIC-3 — large radial % ring (Duolingo/Flo "loading N%"): big ring + prominent %.
            let ringProgress = block.progress_value.map { CGFloat($0 > 1 ? $0 / 100 : $0) } ?? overallProgress
            return AnyView(
                ZStack {
                    Circle().stroke(progressCol.opacity(0.2), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: max(0.0, min(1.0, ringProgress)))
                        .stroke(progressCol, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(ringProgress * 100))%")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(progressCol)
                }
                .frame(width: 160, height: 160)
                .padding(8)
                .frame(maxWidth: .infinity)
            )

        case "cog":
            // EPIC-3 — cog/gear spinner (Asana settings-style loader): thick ring + 8 flat teeth, rotating.
            return AnyView(
                Canvas { ctx, size in
                    let cx = size.width / 2
                    let cy = size.height / 2
                    let outerR = min(size.width, size.height) / 2
                    let ringR = outerR * 0.60
                    let ringStroke = outerR * 0.22
                    let teethCount = 8
                    let toothW = outerR * 0.20
                    let toothH = outerR * 0.28
                    for i in 0..<teethCount {
                        var t = ctx
                        t.translateBy(x: cx, y: cy)
                        t.rotate(by: .degrees(Double(i) * 360 / Double(teethCount)))
                        let rect = CGRect(x: -toothW / 2, y: -ringR - toothH * 0.55, width: toothW, height: toothH)
                        t.fill(Path(roundedRect: rect, cornerRadius: toothW * 0.25), with: .color(progressCol))
                    }
                    let ringRect = CGRect(x: cx - ringR, y: cy - ringR, width: ringR * 2, height: ringR * 2)
                    ctx.stroke(Path(ellipseIn: ringRect), with: .color(progressCol), lineWidth: ringStroke)
                }
                .frame(width: 80, height: 80)
                .rotationEffect(.degrees(spinAngle))
                .onAppear { withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { spinAngle = 360 } }
                .frame(maxWidth: .infinity)
            )

        case "splash_bottom":
            // EPIC-3 — splash-screen loader: a small spinner anchored to the BOTTOM of the area.
            return AnyView(
                VStack {
                    Spacer()
                    Circle()
                        .trim(from: 0, to: 0.30)
                        .stroke(progressCol, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90 + spinAngle))
                        .frame(width: 32, height: 32)
                        .padding(.bottom, 24)
                        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinAngle = 360 } }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(block.height ?? 360))
            )

        case "linear":
            // SPEC-443 (#547) — sub-elements drawn in the authored order. Default reproduces
            // today's arrangement exactly (message above, or bar+items then message).
            let order = loadingOrder ?? (loadingMsgPosValue == "above"
                ? ["message", "bar", "items"]
                : ["bar", "items", "message"])
            return AnyView(
                VStack(spacing: 8) {
                    ForEach(Array(order.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case "bar":
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: loadingBarHeight / 2)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(height: loadingBarHeight)
                                    RoundedRectangle(cornerRadius: loadingBarHeight / 2)
                                        .fill(progressCol)
                                        .frame(width: geometry.size.width * overallProgress, height: loadingBarHeight)
                                        .animation(.linear(duration: 0.3), value: overallProgress)
                                }
                            }
                            .frame(height: loadingBarHeight)
                        case "message":
                            if let msg = block.loading_text, !msg.isEmpty, loadingOrder != nil {
                                Text(msg)
                                    .font(.system(size: loadingMsgSizeValue))
                                    .foregroundColor(loadingMsgColorValue)
                                    .frame(maxWidth: .infinity)
                            }
                        case "items":
                            if let current = itemList.indices.contains(min(1, itemList.count - 1))
                                ? itemList[min(1, itemList.count - 1)].label : nil {
                                Text(current)
                                    .font(.system(size: loadingItemSize))
                                    .foregroundColor(block.text_color.map { Color(hex: $0) } ?? .secondary)
                            }
                        default:
                            EmptyView()
                        }
                    }
                    // Parity with Android linear branch (ContentBlockRenderer.kt:5084-5090) + preview
                    // (OnboardingStepPreview.tsx:1710): render the % below the bar when show_percentage.
                    if block.show_percentage == true {
                        Text("\(Int(overallProgress * 100))%")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(block.text_color.map { Color(hex: $0) } ?? .primary)
                    }
                }
            )

        default: // checklist
            return AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(itemList.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 12) {
                            ZStack {
                                if index < completedCount {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(checkCol)
                                        .transition(.scale.combined(with: .opacity))
                                } else if index == completedCount {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .transition(.opacity)
                                } else {
                                    Circle()
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                                        .frame(width: 22, height: 22)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .animation(.easeInOut(duration: 0.3), value: completedCount)

                            Text(item.label ?? "")
                                // SPEC-440 (#547) — authored item text size; .subheadline (~15)
                                // was hardcoded, so items could not be sized independently.
                                .font(.system(size: loadingItemSize))
                                // SPEC-419 pass-14 #6/#7 — mirror the preview +
                                // Android label-color logic: the ACTIVE (current)
                                // item uses accent_color ("Active Text Color"),
                                // and authored text_color is honored for the
                                // completed/pending items instead of hardcoded
                                // .primary/.secondary.
                                .foregroundColor(
                                    index == completedCount
                                        ? (block.accent_color.map { Color(hex: $0) }
                                            ?? block.text_color.map { Color(hex: $0) } ?? .primary)
                                        : (block.text_color.map { Color(hex: $0) }
                                            ?? (index < completedCount ? .primary : .secondary))
                                )
                        }
                    }
                }
            )
        }
    }

    private func startSequentialTimer(items: [LoadingItemConfig], totalMs: Int) {
        guard !items.isEmpty else {
            // No items: just run a single progress over totalMs
            let duration = Double(totalMs) / 1000.0
            let tickInterval = 0.05
            var elapsed = 0.0
            timerCancellable = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { timer in
                elapsed += tickInterval
                let progress = min(elapsed / duration, 1.0)
                DispatchQueue.main.async {
                    overallProgress = CGFloat(progress)
                }
                if elapsed >= duration {
                    timer.invalidate()
                    if block.auto_advance == true {
                        DispatchQueue.main.async {
                            onAction("next", nil)
                        }
                    }
                }
            }
            return
        }

        // Sequential item completion
        var cumulativeDelay = 0.0
        let totalDuration = Double(items.reduce(0) { $0 + ($1.duration_ms ?? 1000) })

        for (index, item) in items.enumerated() {
            let itemDuration = Double(item.duration_ms ?? 1000) / 1000.0
            cumulativeDelay += itemDuration

            let capturedDelay = cumulativeDelay
            let capturedIndex = index

            DispatchQueue.main.asyncAfter(deadline: .now() + capturedDelay) {
                withAnimation {
                    completedCount = capturedIndex + 1
                    overallProgress = totalDuration > 0 ? CGFloat(capturedDelay / (totalDuration / 1000.0)) : 1.0
                }

                // If last item, handle auto_advance
                if capturedIndex == items.count - 1 {
                    overallProgress = 1.0
                    if block.auto_advance == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            onAction("next", nil)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Orbiting Icons Loader View

/// Radial loader: a central dot/image with N icons orbiting around it on a ring.
/// Each icon has its own background color and image/emoji. Used for "Aligning the
/// stars" style screens (Astro Future, SynergyChart).
///
/// Configuration (all via `block.field_config`):
///   - `orbit_radius` (Double)     — radius of the orbit circle, default 80
///   - `orbit_duration_ms` (Int)   — ms for a full rotation, default 6000
///   - `central_image_url` (String)
///   - `central_bg_color` (String)
///   - `central_size` (Double)     — diameter of central circle, default 10
///   - `ring_color` (String)       — optional visible ring stroke color
///   - `ring_width` (Double)       — ring stroke width, default 1
///   - `animated_bg` (String)      — "none" (default), "constellation", "pulse"
///   - `animated_bg_color` (String)
///   - `size` (Double)             — total frame size (square), default 240
///
/// Each item in `block.loading_items` becomes one orbiting icon. The item can
/// specify:
///   - `icon_url` or `icon`         — image/emoji to display
///   - `icon_bg_color`              — hex background color for the icon bubble
///   - `icon_size`                  — diameter of the icon, default 48
///   - `icon_orbit_angle`           — optional fixed angle 0-360; nil = auto-distribute
///   - `label` (String)             — text to show during this icon's active phase
struct OrbitingIconsLoaderView: View {
    let block: ContentBlock
    let items: [LoadingItemConfig]
    let progress: CGFloat
    let completedCount: Int
    let progressCol: Color

    @State private var rotation: Double = 0
    @State private var bgPulse: CGFloat = 0

    var body: some View {
        // Pull orbiting config from field_config (dictionary-based, no schema changes)
        let cfg = block.field_config
        let size: CGFloat = CGFloat((cfgDouble(cfg?["size"])) ?? 240)
        let orbitRadius: CGFloat = CGFloat((cfgDouble(cfg?["orbit_radius"])) ?? 80)
        let orbitDurationMs: Double = Double((cfg?["orbit_duration_ms"]?.value as? Int) ?? (cfgDouble(cfg?["orbit_duration_ms"])).map { Int($0) } ?? 6000)
        let centralSize: CGFloat = CGFloat((cfgDouble(cfg?["central_size"])) ?? 10)
        let centralImageUrl = cfg?["central_image_url"]?.value as? String
        let centralBgColorHex = cfg?["central_bg_color"]?.value as? String ?? "#FEE2E2"
        let ringColorHex = cfg?["ring_color"]?.value as? String
        let ringWidth: CGFloat = CGFloat((cfgDouble(cfg?["ring_width"])) ?? 1)
        let animatedBg = (cfg?["animated_bg"]?.value as? String) ?? "none"
        let animatedBgHex = cfg?["animated_bg_color"]?.value as? String ?? "#EEEEEE"
        let labelSize = CGFloat((cfgDouble(cfg?["label_font_size"])) ?? 17)
        let subtitleSize = CGFloat((cfgDouble(cfg?["subtitle_font_size"])) ?? 14)
        let subtitleColorHex = cfg?["subtitle_color"]?.value as? String ?? "#E11D48"
        let labelColorHex = cfg?["label_color"]?.value as? String ?? "#0F172A"
        let showPercentage = block.show_percentage ?? false
        let pctLocation = (cfg?["percentage_location"]?.value as? String) ?? "below"

        VStack(spacing: 20) {
            ZStack {
                // Animated background (optional)
                if animatedBg == "constellation" {
                    ConstellationBackground(color: Color(hex: animatedBgHex).opacity(0.4))
                        .frame(width: size * 1.2, height: size * 1.2)
                        .blendMode(.multiply)
                } else if animatedBg == "pulse" {
                    Circle()
                        .fill(Color(hex: animatedBgHex).opacity(0.15 + 0.15 * bgPulse))
                        .frame(width: size * (1.0 + 0.1 * bgPulse), height: size * (1.0 + 0.1 * bgPulse))
                }

                // Orbit rings — visible path lines for orbiting icons
                let effectiveRingColor = ringColorHex ?? "#D1D5DB"
                // Use configured opacity or a visible default (0.5) so rings
                // are clearly visible on both light and dark backgrounds.
                let ringOpacity = CGFloat((cfgDouble(cfg?["ring_opacity"])) ?? 0.5)
                Circle()
                    .stroke(Color(hex: effectiveRingColor).opacity(ringOpacity), lineWidth: ringWidth)
                    .frame(width: orbitRadius * 2, height: orbitRadius * 2)

                // Inner ring (at 60% radius) for depth
                Circle()
                    .stroke(Color(hex: effectiveRingColor).opacity(ringOpacity * 0.4), lineWidth: max(1, ringWidth * 0.5))
                    .frame(width: orbitRadius * 1.2, height: orbitRadius * 1.2)

                // Central dot/image
                if let urlStr = centralImageUrl, let url = URL(string: urlStr) {
                    BundledAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(Color(hex: centralBgColorHex))
                    }
                    .frame(width: centralSize, height: centralSize)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color(hex: centralBgColorHex))
                        .frame(width: centralSize, height: centralSize)
                }

                // Orbiting icons — two layers rotating in opposite directions
                // for a richer "solar system" effect. Odd-indexed icons orbit
                // on an inner ring counter-clockwise; even on outer clockwise.
                // Each icon gets a subtle scale pulse for a breathing effect.

                // Outer orbit (clockwise)
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        if idx % 2 == 0 || items.count <= 2 {
                            let baseAngle = item.icon_orbit_angle ?? (360.0 * Double(idx) / Double(max(items.count, 1)))
                            let angleRad = baseAngle * .pi / 180
                            let xOff = CGFloat(cos(angleRad)) * orbitRadius
                            let yOff = CGFloat(sin(angleRad)) * orbitRadius
                            let iconSize: CGFloat = CGFloat(item.icon_size ?? 48)
                            let iconBgHex = item.icon_bg_color ?? "#BE123C"
                            OrbitingIconView(item: item, size: iconSize, bgColor: Color(hex: iconBgHex))
                                .scaleEffect(1.0 + 0.08 * bgPulse)
                                .offset(x: xOff, y: yOff)
                        }
                    }
                }
                .rotationEffect(Angle(degrees: rotation))

                // Inner orbit (counter-clockwise, smaller radius) — only when 3+ items
                if items.count > 2 {
                    ZStack {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            if idx % 2 == 1 {
                                let innerRadius = orbitRadius * 0.6
                                let baseAngle = item.icon_orbit_angle ?? (360.0 * Double(idx) / Double(max(items.count, 1)))
                                let angleRad = baseAngle * .pi / 180
                                let xOff = CGFloat(cos(angleRad)) * innerRadius
                                let yOff = CGFloat(sin(angleRad)) * innerRadius
                                let iconSize: CGFloat = CGFloat(item.icon_size ?? 40) * 0.85
                                let iconBgHex = item.icon_bg_color ?? "#BE123C"
                                OrbitingIconView(item: item, size: iconSize, bgColor: Color(hex: iconBgHex))
                                    .scaleEffect(1.0 + 0.05 * bgPulse)
                                    .opacity(0.9)
                                    .offset(x: xOff, y: yOff)
                            }
                        }
                    }
                    .rotationEffect(Angle(degrees: -rotation * 0.7))
                }
            }
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.linear(duration: orbitDurationMs / 1000.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                // Breathing pulse — always on for premium feel
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    bgPulse = 1.0
                }
            }

            // Above percentage
            if showPercentage && pctLocation == "above" {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: labelSize, weight: .bold))
                    .foregroundColor(Color(hex: labelColorHex))
            }

            // Title label (from block.text OR first item label)
            if let title = block.text, !title.isEmpty {
                Text(title)
                    .font(.system(size: labelSize, weight: .semibold))
                    .foregroundColor(Color(hex: labelColorHex))
                    .multilineTextAlignment(.center)
            }

            // Active item subtitle label
            if completedCount < items.count, let subtitle = items[completedCount].label, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: subtitleSize))
                    .foregroundColor(Color(hex: subtitleColorHex))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                    .animation(.easeInOut, value: completedCount)
            }

            // Below percentage
            if showPercentage && pctLocation == "below" {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: labelSize, weight: .bold))
                    .foregroundColor(Color(hex: labelColorHex))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A single orbiting icon — circular bubble with image, emoji icon, or
/// SF Symbol inside.
private struct OrbitingIconView: View {
    let item: LoadingItemConfig
    let size: CGFloat
    let bgColor: Color

    var body: some View {
        ZStack {
            Circle().fill(bgColor)
            if let urlStr = item.icon_url, let url = URL(string: urlStr) {
                BundledAsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: size * 0.55, height: size * 0.55)
            } else if let icon = item.icon, !icon.isEmpty {
                // Emoji vs SF Symbol: SF Symbol names are always ASCII
                // ("heart.fill", "mars", "venus"). Emoji are non-ASCII.
                if icon.allSatisfy({ $0.isASCII }) {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Text(icon).font(.system(size: size * 0.45))
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: bgColor.opacity(0.3), radius: 8, y: 2)
    }
}

/// Faint constellation dots + lines drifting background for orbiting loader.
private struct ConstellationBackground: View {
    let color: Color
    @State private var phase: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let dots: [(CGPoint, CGFloat)] = [
                (CGPoint(x: size.width * 0.15, y: size.height * 0.2), 2),
                (CGPoint(x: size.width * 0.85, y: size.height * 0.15), 3),
                (CGPoint(x: size.width * 0.25, y: size.height * 0.75), 2),
                (CGPoint(x: size.width * 0.75, y: size.height * 0.8), 2),
                (CGPoint(x: size.width * 0.5, y: size.height * 0.4), 3),
                (CGPoint(x: size.width * 0.1, y: size.height * 0.55), 2),
                (CGPoint(x: size.width * 0.9, y: size.height * 0.5), 2),
                (CGPoint(x: size.width * 0.45, y: size.height * 0.85), 2),
            ]
            for (p, r) in dots {
                let opacity = 0.3 + 0.5 * abs(sin(phase + Double(p.x)))
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .color(color.opacity(opacity))
                )
            }
            // Connecting lines between nearest dots
            for i in 0..<dots.count {
                for j in (i + 1)..<dots.count {
                    let a = dots[i].0
                    let b = dots[j].0
                    let dx = a.x - b.x
                    let dy = a.y - b.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < size.width * 0.3 {
                        var path = Path()
                        path.move(to: a)
                        path.addLine(to: b)
                        ctx.stroke(path, with: .color(color.opacity(0.15)), lineWidth: 0.5)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}

// MARK: - Circular Gauge Block View (SPEC-089d AC-022)

// MARK: - Speedometer Arc Shape (precise geometry via Path.addArc)

/// Draws a partial arc using explicit Path.addArc. Used for the speedometer gauge
/// to avoid the Circle().trim inscription bug where the stroke clips at frame edges.
private struct SpeedometerArcShape: Shape {
    /// Progress 0.0...1.0 — determines how far along the arc the stroke extends.
    var progress: CGFloat
    /// Full sweep angle in degrees (e.g. 220 for speedometer).
    let sweepDegrees: Double
    /// Radius of the arc.
    let radius: CGFloat
    /// Absolute Y position of the arc's center within the parent frame.
    let centerY: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: centerY)
        // Symmetric around 12 o'clock (top). In SwiftUI (y-down), 270° points north.
        // Start angle = 270 - halfSweep, sweeping visually CW (clockwise=false in math sense).
        let halfSweep = sweepDegrees / 2.0
        let startAngle = Angle.degrees(270 - halfSweep)
        let endAngle = Angle.degrees(270 - halfSweep + sweepDegrees * Double(progress))
        if progress > 0 {
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
        }
        return path
    }
}

/// Renders a circular arc gauge with center label. Supports animated fill.
struct CircularGaugeBlockView: View {
    let block: ContentBlock

    @State private var animatedProgress: CGFloat = 0

    var body: some View {
        let value = CGFloat(block.gauge_value ?? block.progress_value ?? 0)
        let minVal = CGFloat(block.min_value ?? 0)
        let maxVal = CGFloat(block.max_value ?? 100)
        let targetProgress = (maxVal - minVal) > 0 ? min((value - minVal) / (maxVal - minVal), 1.0) : 0
        // Speedometer defaults to 280 (min 240 enforced); arc/radial default 200
        let variant = block.gauge_variant ?? "arc"
        let defaultSize: Double = variant == "speedometer" ? 280 : 200
        let rawSize = CGFloat(block.height ?? defaultSize)
        // Enforce minimum size for speedometer to prevent tiny gauges
        let size = variant == "speedometer" ? max(rawSize, 240) : rawSize
        let strokeW = CGFloat(block.stroke_width ?? 14)
        let fillCol = Color(hex: block.bar_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let trackCol = Color(hex: block.track_color ?? "#E5E7EB")
        let labelCol = Color(hex: block.label_color ?? block.text_color ?? "#000000")
        let labelFontSz = CGFloat(block.label_font_size ?? block.font_size ?? 24)
        let shouldAnimate = block.animate ?? true
        let animDuration = Double(block.animation_duration_ms ?? 800) / 1000.0
        let showPct = block.show_percentage ?? false
        // Percentage placement: "below" (default), "center", "above", "none"
        let pctLocation = block.percentage_location ?? "below"

        // Gradient fill — if gradient_start_color + gradient_end_color are set,
        // use an AngularGradient for the fill stroke instead of solid color.
        // This enables the pink→red arc fill from screenshot 3.
        let cfg = block.field_config
        let gradStartHex = cfg?["gradient_start_color"]?.value as? String
        let gradEndHex = cfg?["gradient_end_color"]?.value as? String
        let useGradient = gradStartHex != nil && gradEndHex != nil

        // Needle/arrow styling — prefer dedicated arrow_color over fallbacks
        let needleCol = Color(hex: block.arrow_color ?? block.label_color ?? "#1F2937")
        let needleW = CGFloat(block.arrow_stroke_width ?? 3)
        let minLabel = block.min_label ?? "\(Int(minVal))"
        let maxLabel = block.max_label ?? "\(Int(maxVal))"
        let minMaxFontSz = CGFloat(block.min_max_font_size ?? 13)
        let minMaxCol = Color(hex: block.min_max_color ?? block.label_color ?? "#000000")

        // Speedometer sweep — 220° symmetric around top (12 o'clock)
        let speedoSweep: Double = 220
        let radius: CGFloat = size / 2 - strokeW / 2

        VStack(spacing: 4) {
            if showPct && pctLocation == "above" {
                Text("\(Int(animatedProgress * 100))%")
                    .font(.system(size: labelFontSz, weight: .bold))
                    .foregroundColor(labelCol)
            }

            if variant == "speedometer" {
                // Speedometer — explicit frame + Path-based rendering + .position() for pixel-perfect layout.
                // Arc visual center: x = size/2, y = radius + strokeW/2 (so top stroke stops at y=0, not clipped)
                let centerX = size / 2
                let centerY = radius + strokeW / 2
                // Arc endpoint coordinates (lower-left and lower-right), relative to arc center
                let endpointAngleRad: Double = (speedoSweep / 2.0) * .pi / 180.0
                let endpointOffsetX = CGFloat(sin(endpointAngleRad)) * radius      // ≈ 0.94 * radius
                let endpointOffsetY = CGFloat(abs(cos(endpointAngleRad))) * radius // ≈ 0.34 * radius (below center)
                // Frame height: from y=0 (top of stroke) to below endpoint labels
                let frameHeight = centerY + endpointOffsetY + strokeW / 2 + minMaxFontSz * 1.8 + 24

                ZStack(alignment: .topLeading) {
                    // Track (full arc)
                    SpeedometerArcShape(progress: 1.0, sweepDegrees: speedoSweep, radius: radius, centerY: centerY)
                        .stroke(trackCol, style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                    // Fill (animated) — supports gradient or solid
                    if useGradient, let startHex = gradStartHex, let endHex = gradEndHex {
                        SpeedometerArcShape(progress: animatedProgress, sweepDegrees: speedoSweep, radius: radius, centerY: centerY)
                            .stroke(
                                AngularGradient(
                                    colors: [Color(hex: startHex), Color(hex: endHex)],
                                    center: UnitPoint(x: 0.5, y: centerY / (centerY + radius)),
                                    startAngle: .degrees(270 - speedoSweep / 2),
                                    endAngle: .degrees(270 - speedoSweep / 2 + speedoSweep * Double(animatedProgress))
                                ),
                                style: StrokeStyle(lineWidth: strokeW, lineCap: .round)
                            )
                    } else {
                        SpeedometerArcShape(progress: animatedProgress, sweepDegrees: speedoSweep, radius: radius, centerY: centerY)
                            .stroke(fillCol, style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                    }

                    // Needle — rotated around its own hub center, then positioned at arc center
                    let needleLen = radius - strokeW / 2 - 12
                    let needleAngleFromUp = -speedoSweep / 2.0 + speedoSweep * Double(animatedProgress)
                    ZStack {
                        Capsule()
                            .fill(needleCol)
                            .frame(width: needleW, height: needleLen)
                            .offset(y: -needleLen / 2)
                            .rotationEffect(.degrees(needleAngleFromUp))
                        Circle()
                            .fill(needleCol)
                            .frame(width: max(12, needleW * 3.5), height: max(12, needleW * 3.5))
                    }
                    .position(x: centerX, y: centerY)

                    // Min/Max labels — positioned just below the arc endpoints
                    Text(minLabel)
                        .font(.system(size: minMaxFontSz, weight: .medium))
                        .foregroundColor(minMaxCol)
                        .fixedSize()
                        .position(
                            x: centerX - endpointOffsetX,
                            y: centerY + endpointOffsetY + strokeW / 2 + minMaxFontSz
                        )
                    Text(maxLabel)
                        .font(.system(size: minMaxFontSz, weight: .medium))
                        .foregroundColor(minMaxCol)
                        .fixedSize()
                        .position(
                            x: centerX + endpointOffsetX,
                            y: centerY + endpointOffsetY + strokeW / 2 + minMaxFontSz
                        )

                    // Center value label — positioned inside the "bowl" (below arc center line).
                    // Renders when ANY of:
                    //   - pctLocation == "center" (explicit)
                    //   - showPct == true (user wants a % somewhere) and no above/below slot chosen
                    //   - block.text is non-empty (user set a "Center Label" value, which is
                    //     implicitly centered — previously that text was silently dropped
                    //     unless they also set pctLocation to "center")
                    let hasCenterText = (block.text?.isEmpty == false)
                    let pctExplicitElsewhere = pctLocation == "above" || pctLocation == "below"
                    let shouldShowCenter = pctLocation == "center"
                        || hasCenterText
                        || (showPct && !pctExplicitElsewhere)
                    if shouldShowCenter {
                        VStack(spacing: 2) {
                            Text(
                                showPct
                                    ? "\(Int(animatedProgress * 100))%"
                                    : (hasCenterText ? block.text! : "\(Int(value))")
                            )
                                .font(.system(size: labelFontSz, weight: .bold))
                                .foregroundColor(labelCol)
                            if let sub = block.sublabel, !sub.isEmpty {
                                Text(sub)
                                    .font(.system(size: min(labelFontSz * 0.5, 13)))
                                    .foregroundColor(labelCol.opacity(0.6))
                            }
                        }
                        .fixedSize()
                        .position(x: centerX, y: centerY + radius * 0.5)
                    }
                }
                .frame(width: size, height: frameHeight)
            } else if variant == "linear" {
                // SPEC-419 pass-15 #2 — horizontal bar gauge (mirrors preview linear variant):
                // value-indicator triangle + label above, gradient bar, ticks 0/25/50/75/100 below.
                let barHeight = max(8, size * 0.08)
                let totalWidth = size * 1.2
                let pct = CGFloat(animatedProgress)
                let labelText = (block.text?.isEmpty == false) ? block.text! : "\(Int(animatedProgress * 100))%"
                let ticks: [Int] = [0, 25, 50, 75, 100]
                VStack(spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Text(labelText)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(fillCol)
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: 0))
                                p.addLine(to: CGPoint(x: 10, y: 0))
                                p.addLine(to: CGPoint(x: 5, y: 6))
                                p.closeSubpath()
                            }
                            .fill(fillCol)
                            .frame(width: 10, height: 6)
                        }
                        .fixedSize()
                        .offset(x: pct * totalWidth - 5, y: 0)
                    }
                    .frame(width: totalWidth, height: 22, alignment: .topLeading)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: barHeight / 2)
                            .fill(trackCol)
                            .frame(width: totalWidth, height: barHeight)
                        RoundedRectangle(cornerRadius: barHeight / 2)
                            .fill(LinearGradient(colors: [fillCol.opacity(0.53), fillCol], startPoint: .leading, endPoint: .trailing))
                            .frame(width: pct * totalWidth, height: barHeight)
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.self) { tick in
                            VStack(spacing: 1) {
                                Rectangle()
                                    .fill(Color(hex: "#D1D5DB"))
                                    .frame(width: 1, height: 4)
                                Text("\(tick)")
                                    .font(.system(size: 8))
                                    .foregroundColor(Color(hex: "#9CA3AF"))
                            }
                            .fixedSize()
                            .offset(x: CGFloat(Double(tick) / 100.0) * totalWidth - 4, y: 0)
                        }
                    }
                    .frame(width: totalWidth, height: 16, alignment: .topLeading)
                }
                .frame(width: totalWidth)
            } else {
                // Arc / radial variants use a regular square ZStack with Circle+trim
                ZStack {
                    switch variant {
                    case "radial":
                        Circle()
                            .stroke(trackCol, lineWidth: strokeW * 2)
                        if useGradient, let startHex = gradStartHex, let endHex = gradEndHex {
                            Circle()
                                .trim(from: 0, to: animatedProgress)
                                .stroke(
                                    AngularGradient(colors: [Color(hex: startHex), Color(hex: endHex)], center: .center, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * Double(animatedProgress))),
                                    style: StrokeStyle(lineWidth: strokeW * 2, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                        } else {
                            Circle()
                                .trim(from: 0, to: animatedProgress)
                                .stroke(fillCol, style: StrokeStyle(lineWidth: strokeW * 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        if pctLocation == "center" || (block.text?.isEmpty == false) || (showPct && pctLocation != "above" && pctLocation != "below") {
                            VStack(spacing: 2) {
                                Text(showPct ? "\(Int(animatedProgress * 100))%" : (block.text?.isEmpty == false ? block.text! : "\(Int(value))"))
                                    .font(.system(size: labelFontSz, weight: .bold))
                                    .foregroundColor(labelCol)
                                if let sub = block.sublabel, !sub.isEmpty {
                                    Text(sub).font(.caption).foregroundColor(labelCol.opacity(0.7))
                                }
                            }
                        }

                    default: // "arc"
                        Circle()
                            .stroke(trackCol, lineWidth: strokeW)
                        if useGradient, let startHex = gradStartHex, let endHex = gradEndHex {
                            Circle()
                                .trim(from: 0, to: animatedProgress)
                                .stroke(
                                    AngularGradient(colors: [Color(hex: startHex), Color(hex: endHex)], center: .center, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * Double(animatedProgress))),
                                    style: StrokeStyle(lineWidth: strokeW, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                        } else {
                            Circle()
                                .trim(from: 0, to: animatedProgress)
                                .stroke(fillCol, style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        if pctLocation == "center" || (block.text?.isEmpty == false) || (showPct && pctLocation != "above" && pctLocation != "below") {
                            VStack(spacing: 2) {
                                Text(showPct ? "\(Int(animatedProgress * 100))%" : (block.text?.isEmpty == false ? block.text! : "\(Int(value))"))
                                    .font(.system(size: labelFontSz, weight: .bold))
                                    .foregroundColor(labelCol)
                                if let sub = block.sublabel, !sub.isEmpty {
                                    Text(sub).font(.caption).foregroundColor(labelCol.opacity(0.7))
                                }
                            }
                        }
                    }
                }
                .frame(width: size, height: size)
                .padding(strokeW / 2) // Prevent stroke clipping at frame edges
            }

            if showPct && pctLocation == "below" {
                Text("\(Int(animatedProgress * 100))%")
                    .font(.system(size: labelFontSz, weight: .bold))
                    .foregroundColor(labelCol)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if shouldAnimate {
                withAnimation(.easeInOut(duration: animDuration)) {
                    animatedProgress = targetProgress
                }
            } else {
                animatedProgress = targetProgress
            }
        }
    }

}

// MARK: - Date Wheel Picker Block View (SPEC-089d AC-023)

/// Multi-column date picker using native iOS wheel picker style.
struct DateWheelPickerBlockView: View {
    let block: ContentBlock
    @Binding var inputValues: [String: Any]

    @State private var selectedDate: Date = {
        let cal = Calendar.current
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }()
    @State private var showPicker = false
    @State private var showDateToast = false
    // Pre-warm state: a zero-sized hidden DatePicker forces UIKit to init
    // its UIPickerView subsystem eagerly so the first user drag isn't laggy.
    @State private var prewarmDate = Date()

    /// Parse relative date strings like "today", "-18y", "-100y", "+1y", "-30d", or ISO date "2000-01-01"
    // Internal (was private) so FormInputDateBlock can reuse the identical min_date/max_date
    // parsing (relative "-18y"/"+30d", "today"/"now", absolute ISO) for its own bounds gate.
    static func parseDate(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "today" || trimmed == "now" { return Date() }
        let cal = Calendar.current
        // Relative: -18y, +1y, -30d, -6m
        let lastChar = trimmed.last
        if let lastChar, "dmy".contains(lastChar) {
            let numStr = String(trimmed.dropLast())
            if let amount = Int(numStr) {
                switch lastChar {
                case "d": return cal.date(byAdding: .day, value: amount, to: Date())
                case "m": return cal.date(byAdding: .month, value: amount, to: Date())
                case "y": return cal.date(byAdding: .year, value: amount, to: Date())
                default: break
                }
            }
        }
        // Absolute ISO date
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: str)
    }

    private var dateRange: ClosedRange<Date> {
        let cal = Calendar.current
        var minDate: Date
        var maxDate: Date

        // Start with wide defaults
        minDate = cal.date(byAdding: .year, value: -150, to: Date()) ?? Date.distantPast
        maxDate = cal.date(byAdding: .year, value: 50, to: Date()) ?? Date.distantFuture

        // Apply explicit min/max
        if let parsed = Self.parseDate(block.min_date) { minDate = parsed }
        if let parsed = Self.parseDate(block.max_date) { maxDate = parsed }

        // Apply allow_future / allow_past toggles
        if block.allow_future == false {
            let today = cal.startOfDay(for: Date())
            maxDate = min(maxDate, today)
        }
        if block.allow_past == false {
            let today = cal.startOfDay(for: Date())
            minDate = max(minDate, today)
        }

        // SPEC-419 pass-24 — guard the ClosedRange: a descending min_date/max_date config, or
        // allow_past/allow_future pushing minDate past maxDate, would trap minDate...maxDate.
        return minDate...max(minDate, maxDate)
    }

    var body: some View {
        let highlightCol = Color(hex: block.highlight_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let isFieldMode = block.picker_presentation == "field"
        // Read picker_mode from config (console saves "date" or "datetime")
        // Fall back to block type for legacy compatibility
        let components: DatePickerComponents = {
            let mode = block.picker_mode
            if mode == "datetime" || mode == "date_time" { return [.date, .hourAndMinute] }
            if mode == "time" { return [.hourAndMinute] }
            switch block.type {
            case .input_time: return [.hourAndMinute]
            case .input_datetime: return [.date, .hourAndMinute]
            default: return [.date]
            }
        }()

        // Read picker_variant from field_config (console option): "graphical" | "wheel" | "compact".
        // When in datetime mode we default to "wheel" because graphical+wheel
        // stacked vertically exceeds most screen heights and gets clipped by the
        // pinned CTA button. Date-only can still default to "graphical" (calendar).
        let explicitVariant = (block.field_config?["picker_variant"]?.value as? String)
            ?? (block.field_config?["date_picker_variant"]?.value as? String)
        let isDatetimeMode = components.contains(.date) && components.contains(.hourAndMinute)
        let variant = explicitVariant ?? (isDatetimeMode ? "wheel" : "graphical")
        // The console writes bg/border to the shared `block_style` struct on
        // `date_wheel_picker` (not `field_style` like text inputs). Also the
        // wheel/calendar bg are top-level props, not nested in field_config.
        // Fall through both sources → legacy field_style → "transparent".
        let sharedBg = block.block_style?.background_color
            ?? block.field_style?.background_color
        let calendarBg = (block.field_config?["calendar_bg_color"]?.value as? String)
            ?? block.calendar_bg_color
            ?? sharedBg
            ?? "transparent"
        let wheelBg = block.wheel_bg_color
            ?? (block.field_config?["wheel_bg_color"]?.value as? String)
            ?? sharedBg
            ?? calendarBg
        // Picker chrome — `field_config.picker_corner_radius` is the picker-
        // specific control; the old `block_style.border_radius` fallback is
        // intentionally dropped because console sections often set tiny
        // (1-2pt) block-level radii that look wrong on a large picker card.
        let pickerCornerRadius = CGFloat(
            (cfgDouble(block.field_config?["picker_corner_radius"])) ?? 12
        )
        // Wheel text — picker-specific key wins; then fall through to the
        // block's top-level text_color (console writes it here) and finally
        // to field_style.text_color for form variants.
        let wheelTextColorHex = (block.field_config?["wheel_text_color"]?.value as? String)
            ?? block.text_color
            ?? block.field_style?.text_color
        // Picker border is OPT-IN via picker-specific keys only — the
        // block_style.border_color is meant for the trigger pill (field mode)
        // and bleeds visually into the wheel when inherited. Kept strictly
        // picker-specific so an authored block_style.border doesn't surround
        // the wheel unless the author asks for it explicitly.
        // SPEC-419 — the console writes the picker line color/stroke at top level
        // (wheel_line_color / wheel_line_stroke_width); honor those first, then the legacy
        // field_config picker_border_* keys.
        let pickerBorderColor = block.wheel_line_color
            ?? (block.field_config?["picker_border_color"]?.value as? String)
        let pickerBorderWidth = CGFloat(
            block.wheel_line_stroke_width
            ?? (cfgDouble(block.field_config?["picker_border_width"]))
            ?? (pickerBorderColor != nil ? 1 : 0)
        )
        let pickerPadding = CGFloat((cfgDouble(block.field_config?["picker_padding"])) ?? 0)

        // Field-mode trigger visuals — honor whichever style struct the
        // console wrote to (`block_style` for standalone blocks,
        // `field_style` for form-input variants). Either path needs to
        // resolve bg / corner / border so authored "transparent" actually
        // renders transparent.
        let triggerBg = Color(hex: sharedBg ?? "transparent")
        // Corner radius: prefer picker-specific overrides over a generic
        // block_style.border_radius (section-level values are often 1-2pt
        // and look wrong on the picker pill).
        let fsCorner = block.field_style?.corner_radius.map { CGFloat($0) }
        let triggerCorner: CGFloat = fsCorner ?? pickerCornerRadius
        let triggerBorderHex = block.block_style?.border_color ?? block.field_style?.border_color
        let triggerBorderColor: Color = triggerBorderHex.map { Color(hex: $0) } ?? Color.gray.opacity(0.3)
        let bsBorderW = block.block_style?.border_width.map { CGFloat($0) }
        let fsBorderW = block.field_style?.border_width.map { CGFloat($0) }
        // If the author provided a border color but forgot the width, default
        // to 1pt so the border is actually visible. Console UX lets people
        // pick a border color without setting width; without this fallback
        // the border silently disappears (observed on the Form 4 date picker).
        let hasAuthoredBorderColor = triggerBorderHex != nil
        let triggerBorderWidth: CGFloat = bsBorderW ?? fsBorderW ?? (hasAuthoredBorderColor ? 1 : 0)
        let triggerTextHex = block.text_color ?? block.field_style?.text_color
        let triggerTextColor: Color = triggerTextHex.map { Color(hex: $0) } ?? .primary

        VStack(spacing: 8) {
            // SPEC-419 — block-level label (parity with preview/Android, which now render it).
            if let label = block.text, !label.isEmpty {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Pre-warm: hidden wheel DatePicker mounted behind a zero-size
            // anchor so UIKit instantiates UIPickerView eagerly (cuts the
            // first-drag lag) without claiming any layout space inside the
            // VStack. Earlier .frame(200,150).offset(-10000,-10000) was a
            // bug — `.offset` moves visually but the 150pt frame still ate
            // VStack space, which combined with `vertical_offset: -40`
            // caused the whole picker block to visually overlay siblings
            // below it (customer-reported on Form 9a).
            Color.clear
                .frame(width: 0, height: 0)
                .background(
                    DatePicker("", selection: $prewarmDate, displayedComponents: components)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(width: 200, height: 150)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                )

            if isFieldMode {
                // Field mode: tap to open
                Button {
                    withAnimation { showPicker.toggle() }
                } label: {
                    HStack {
                        // SPEC — honor time_text_size on the displayed time (time / datetime modes).
                        Text(formatDate(selectedDate, components: components))
                            .font(components.contains(.hourAndMinute)
                                ? block.time_text_size.map { Font.system(size: CGFloat($0)) }
                                : nil)
                            .foregroundColor(triggerTextColor)
                        Spacer()
                        Image(systemName: components == [.hourAndMinute] ? "clock" : "calendar")
                            .foregroundColor(highlightCol)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Single-path background — fill + stroke on the same rounded
                // rectangle so the corner thickness matches the straight edges.
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: triggerCorner).fill(triggerBg)
                        RoundedRectangle(cornerRadius: triggerCorner)
                            .strokeBorder(triggerBorderColor, lineWidth: triggerBorderWidth)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: triggerCorner))

                if showPicker {
                    datePickerContent(
                        components: components,
                        variant: variant,
                        highlightCol: highlightCol,
                        calendarBg: calendarBg,
                        wheelBg: wheelBg,
                        pickerCornerRadius: pickerCornerRadius,
                        wheelTextColorHex: wheelTextColorHex,
                        pickerBorderColor: pickerBorderColor,
                        pickerBorderWidth: pickerBorderWidth,
                        pickerPadding: pickerPadding,
                        defaultSpacing: 16
                    )
                }
            } else {
                // Inline mode (default)
                datePickerContent(
                    components: components,
                    variant: variant,
                    highlightCol: highlightCol,
                    calendarBg: calendarBg,
                    wheelBg: wheelBg,
                    pickerCornerRadius: pickerCornerRadius,
                    wheelTextColorHex: wheelTextColorHex,
                    pickerBorderColor: pickerBorderColor,
                    pickerBorderWidth: pickerBorderWidth,
                    pickerPadding: pickerPadding,
                    defaultSpacing: 8
                )
            }
        }
        .onChange(of: selectedDate) { newDate in
            // Clamp to valid range and show toast if out of bounds
            let range = dateRange
            if newDate < range.lowerBound {
                selectedDate = range.lowerBound
                showDateValidationToast()
            } else if newDate > range.upperBound {
                selectedDate = range.upperBound
                showDateValidationToast()
            }
            persistDate()
        }
        .onAppear { restoreDate() }
        .overlay(alignment: .bottom) {
            if showDateToast {
                Text(block.date_validation_message ?? defaultValidationMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(12)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var defaultValidationMessage: String {
        if block.allow_future == false { return "Please select a date in the past" }
        if block.allow_past == false { return "Please select a future date" }
        return "Please select a valid date"
    }

    private func showDateValidationToast() {
        withAnimation { showDateToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { showDateToast = false }
        }
    }

    private func persistDate() {
        let fieldId = block.field_id ?? block.id
        let formatter = ISO8601DateFormatter()
        inputValues[fieldId] = formatter.string(from: selectedDate)
        // Also expose a computed age (whole years) under `<field_id>_age`
        // when the picker is in date-only mode (the common birth_date use
        // case). Saves customers from re-parsing the ISO string client-side.
        let isDateOnly = block.picker_mode == "date"
            || block.picker_mode == nil  // legacy default for input_date / date_wheel_picker
            || block.type == .input_date
        if isDateOnly && block.picker_mode != "datetime" && block.picker_mode != "time" && block.picker_mode != "date_time" {
            let years = Calendar.current.dateComponents([.year], from: selectedDate, to: Date()).year ?? 0
            inputValues["\(fieldId)_age"] = max(0, years)
        }
    }

    private func restoreDate() {
        let fieldId = block.field_id ?? block.id
        if let saved = inputValues[fieldId] as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: saved) {
                selectedDate = date
                return
            }
        }
        // No prior answer — seed the wheel from the authored `default_date_value`
        // (relative like "-18y" or ISO "2000-01-01") instead of always landing
        // on today. Clamp into the valid range so a default outside min/max
        // can't open on an invalid day. Parity with Android's default handling.
        if let seeded = Self.parseDate(block.default_date_value) {
            let range = dateRange
            selectedDate = min(max(seeded, range.lowerBound), range.upperBound)
        }
    }

    private func formatDate(_ date: Date, components: DatePickerComponents) -> String {
        let f = DateFormatter()
        if components.contains(.date) && components.contains(.hourAndMinute) {
            f.dateStyle = .medium; f.timeStyle = .short
        } else if components.contains(.hourAndMinute) {
            f.dateStyle = .none; f.timeStyle = .short
        } else {
            f.dateStyle = .medium; f.timeStyle = .none
        }
        // SPEC — honor time_format ("12h"/"24h") on the displayed time. Locale
        // en_GB forces 24h (HH:mm, no AM/PM); en_US forces 12h (h:mm a). Unset
        // falls through to the device locale.
        if components.contains(.hourAndMinute), let tf = block.time_format?.lowercased() {
            f.locale = Locale(identifier: tf == "24h" ? "en_GB" : "en_US")
        }
        return f.string(from: date)
    }

    // MARK: - Date Picker Rendering Helper
    @ViewBuilder
    private func datePickerContent(
        components: DatePickerComponents,
        variant: String,
        highlightCol: Color,
        calendarBg: String,
        wheelBg: String,
        pickerCornerRadius: CGFloat,
        wheelTextColorHex: String?,
        pickerBorderColor: String?,
        pickerBorderWidth: CGFloat,
        pickerPadding: CGFloat,
        defaultSpacing: CGFloat
    ) -> some View {
        let spacing = CGFloat(block.picker_spacing ?? Double(defaultSpacing))
        let useWheel = variant == "wheel"
        let useCompact = variant == "compact"

        if components.contains(.date) && components.contains(.hourAndMinute) {
            // DateTime: date above, time wheel below (user requested this order)
            VStack(spacing: spacing) {
                datePart(
                    components: [.date],
                    useWheel: useWheel,
                    useCompact: useCompact,
                    highlightCol: highlightCol,
                    bgHex: calendarBg,
                    wheelBgHex: wheelBg,
                    cornerRadius: pickerCornerRadius,
                    wheelTextColorHex: wheelTextColorHex,
                    pickerBorderColor: pickerBorderColor,
                    pickerBorderWidth: pickerBorderWidth,
                    pickerPadding: pickerPadding
                )
                datePart(
                    components: [.hourAndMinute],
                    useWheel: true, // Time is always wheel
                    useCompact: useCompact,
                    highlightCol: highlightCol,
                    bgHex: wheelBg,
                    wheelBgHex: wheelBg,
                    cornerRadius: pickerCornerRadius,
                    wheelTextColorHex: wheelTextColorHex,
                    pickerBorderColor: pickerBorderColor,
                    pickerBorderWidth: pickerBorderWidth,
                    pickerPadding: pickerPadding
                )
            }
        } else if components.contains(.date) {
            datePart(
                components: [.date],
                useWheel: useWheel,
                useCompact: useCompact,
                highlightCol: highlightCol,
                bgHex: calendarBg,
                wheelBgHex: wheelBg,
                cornerRadius: pickerCornerRadius,
                wheelTextColorHex: wheelTextColorHex,
                pickerBorderColor: pickerBorderColor,
                pickerBorderWidth: pickerBorderWidth,
                pickerPadding: pickerPadding
            )
        } else {
            // Time-only
            datePart(
                components: [.hourAndMinute],
                useWheel: true,
                useCompact: useCompact,
                highlightCol: highlightCol,
                bgHex: wheelBg,
                wheelBgHex: wheelBg,
                cornerRadius: pickerCornerRadius,
                wheelTextColorHex: wheelTextColorHex,
                pickerBorderColor: pickerBorderColor,
                pickerBorderWidth: pickerBorderWidth,
                pickerPadding: pickerPadding
            )
        }
    }

    @ViewBuilder
    private func datePart(
        components: DatePickerComponents,
        useWheel: Bool,
        useCompact: Bool,
        highlightCol: Color,
        bgHex: String,
        wheelBgHex: String,
        cornerRadius: CGFloat,
        wheelTextColorHex: String?,
        pickerBorderColor: String?,
        pickerBorderWidth: CGFloat,
        pickerPadding: CGFloat
    ) -> some View {
        let bg = Color(hex: bgHex)
        let isTime = components == [.hourAndMinute]
        // Force the native picker into dark mode whenever the configured wheel
        // or text color is clearly a light value (white labels on a dark card
        // means the spinning wheel popover must match, otherwise it renders
        // white-on-white and is unreadable).
        let resolvedScheme: ColorScheme = {
            if let hex = wheelTextColorHex, Color.isLightHex(hex) { return .dark }
            if Color.isLightHex(bgHex) == false, bgHex.lowercased() != "transparent", bgHex != "" { return .dark }
            return .light
        }()
        // SPEC — force the spinning time wheel into 12h/24h per time_format.
        // en_GB → 24-hour columns (no AM/PM); en_US → 12-hour + AM/PM. Only the
        // time wheel is affected; date-only wheels keep the device locale.
        let timeLocale: Locale? = {
            guard isTime, let tf = block.time_format?.lowercased() else { return nil }
            return Locale(identifier: tf == "24h" ? "en_GB" : "en_US")
        }()
        let picker: AnyView = {
            if useWheel || isTime {
                let base = DatePicker("", selection: $selectedDate, in: dateRange, displayedComponents: components)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .tint(highlightCol)
                    .environment(\.colorScheme, resolvedScheme)
                    .environment(\.locale, timeLocale ?? Locale.current)
                    .frame(maxWidth: .infinity)
                if let hex = wheelTextColorHex {
                    return AnyView(base.colorMultiply(Color(hex: hex)))
                }
                return AnyView(base)
            } else if useCompact {
                return AnyView(
                    DatePicker("", selection: $selectedDate, in: dateRange, displayedComponents: components)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(highlightCol)
                        .environment(\.colorScheme, resolvedScheme)
                        .frame(maxWidth: .infinity)
                )
            } else {
                // Default: graphical calendar
                return AnyView(
                    DatePicker("", selection: $selectedDate, in: dateRange, displayedComponents: components)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .tint(highlightCol)
                        .environment(\.colorScheme, resolvedScheme)
                )
            }
        }()

        picker
            .padding(pickerPadding)
            // Single-path fill + strokeBorder on the same RoundedRectangle so
            // the corner and edge antialiasing match — same pattern as the
            // input_date and paywall PlanCard fixes. Previous layered
            // .background + .cornerRadius + .overlay(...stroke) produced
            // bolder-looking corners because the stroke centerline sat on
            // the path edge and drew partially outside the fill.
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(bg)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            Color(hex: pickerBorderColor ?? "#00000000"),
                            lineWidth: pickerBorderWidth
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Wheel Picker Block View (SPEC-089d AC-013)

/// Numeric wheel picker for single-value selection.
/// Preference key that reports scroll offset of the horizontal wheel
/// picker so selectedIndex can track the centered item live (iOS 16 path).
private struct WheelScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct WheelPickerBlockView: View {
    let block: ContentBlock
    /// SPEC-082 follow-up: previously this view had no binding to the
    /// onboarding response dict, so the user's spin was silently dropped.
    /// Now the selected number is persisted under `block.field_id`.
    @Binding var inputValues: [String: Any]
    /// SPEC-419 STEP-2 — fires `("value_changed", baseValue)` on drag-END/commit (never per tick).
    var onInteract: (String, String, String?) -> Void = { _, _, _ in }

    @State private var selectedIndex: Int = 0
    /// True once the user has either tapped an item or scrolled the wheel.
    /// Required-field validation keys off this so a pristine default value
    /// can't be silently submitted without the user confirming a choice.
    @State private var hasUserInteracted: Bool = false
    /// iOS 17+ scroll-position binding. `.scrollPosition(id:)` drives
    /// center-snap + selection tracking in one step, so we don't need
    /// PreferenceKey/ScrollViewReader plumbing on modern OS.
    @State private var scrollPosIndex: Int? = nil
    /// Haptic generator for horizontal-mode selection ticks — matches the
    /// native UIPickerView feel. Vertical mode uses SwiftUI's Picker(.wheel)
    /// which already emits selection haptics automatically, so we skip it
    /// there to avoid double-firing.
    @State private var selectionHaptic = UISelectionFeedbackGenerator()

    /// Fixed width of each horizontal item — drives the scroll-offset-to-
    /// index math so the centered item stays highlighted during drag.
    private let horizontalItemWidth: CGFloat = 60

    var body: some View {
        // SPEC-420 — opt-in measurement mode. When `field_config.measurement_type`
        // is present AND the units resolve to a usable set, render the measurement
        // wrapper (unit toggle + ruler/gauge/dial/wheel visual, base-owned persist).
        // Otherwise the legacy drum below renders UNCHANGED.
        if let mcfg = parseMeasurementConfig(block) {
            // The measurement wrapper fires the same ("value_changed", base) interaction the legacy
            // drum does — routing `onInteract` through was the missing half of the EPIC-11 seam.
            MeasurementWheelBlockView(block: block, config: mcfg, inputValues: $inputValues, onInteract: onInteract)
        } else {
            legacyBody
        }
    }

    @ViewBuilder
    private var legacyBody: some View {
        let minVal = block.min_value ?? 0
        // SPEC-419 — the editor writes `max_value`/`default_value`; natives canonical keys are
        // `max_value_picker`/`default_picker_value`. Read the picker key first, fall back to the
        // editor key so authored ranges/defaults aren't silently lost on-device.
        let maxVal = block.max_value_picker ?? block.max_value ?? 100
        let step = { let s = block.step_value ?? 1; return s > 0 ? s : 1 }()  // clamp >0 — a 0/negative step makes the value-gen loop non-terminating
        let defaultVal = block.default_picker_value ?? block.default_value ?? minVal
        let unitStr = block.unit ?? ""
        // SPEC-419 — accept the editor's prefix/suffix alongside before/after (prefix == before).
        let unitPos = block.unit_position ?? "after"
        let highlightCol = Color(hex: block.highlight_color ?? block.active_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))

        // Generate values
        let values: [Double] = {
            var vals: [Double] = []
            var current = minVal
            while current <= maxVal {
                vals.append(current)
                current += step
            }
            return vals.isEmpty ? [0] : vals
        }()

        let initialIndex = values.firstIndex(where: { $0 >= defaultVal }) ?? 0

        let isHorizontal = block.wheel_orientation == "horizontal" || block.orientation == "horizontal"

        // SPEC — honor wheel_height / visible_items as the drum height (was the
        // system default). ~34pt per visible row; nil → natural sizing (unchanged).
        // Parity with Android's drumHeightDp.
        let wheelHeightPt: CGFloat? = block.wheel_height.map { CGFloat($0) }
            ?? block.visible_items.map { CGFloat(max(1, min(9, $0))) * 34 }

        VStack(spacing: 8) {
            if let label = block.rating_label ?? block.text {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if isHorizontal {
                if #available(iOS 17.0, *) {
                    modernHorizontalWheel(values: values, initialIndex: initialIndex, unitStr: unitStr, unitPos: unitPos, highlightCol: highlightCol)
                } else {
                    legacyHorizontalWheel(values: values, initialIndex: initialIndex, unitStr: unitStr, unitPos: unitPos, highlightCol: highlightCol)
                }
            } else {
                // Vertical wheel picker (default)
                Picker("", selection: $selectedIndex) {
                    ForEach(0..<values.count, id: \.self) { idx in
                        let val = values[idx]
                        let formatted = val == val.rounded() ? String(Int(val)) : String(format: "%.1f", val)
                        let display = (unitPos == "before" || unitPos == "prefix") ? "\(unitStr)\(formatted)" : "\(formatted)\(unitStr)"
                        Text(display).tag(idx)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .frame(height: wheelHeightPt)  // nil → natural (unchanged); set → authored drum height
                .tint(highlightCol)
            }
        }
        .onAppear {
            // Pre-warm the haptic engine so the first tick isn't delayed.
            // UISelectionFeedbackGenerator caches its internal state between
            // fires; .prepare() keeps it warm for low-latency ticks.
            selectionHaptic.prepare()
            // Restore prior selection on re-entry; fall back to the default
            // visually but **only auto-persist for non-required fields** so
            // required-field validation can force the user to actually spin
            // or tap before Continue unlocks.
            let fieldId = block.field_id ?? block.id
            if let saved = inputValues[fieldId] as? Double,
               let savedIdx = values.firstIndex(of: saved) {
                selectedIndex = savedIdx
                hasUserInteracted = true
            } else if let savedInt = inputValues[fieldId] as? Int,
                      let savedIdx = values.firstIndex(of: Double(savedInt)) {
                selectedIndex = savedIdx
                hasUserInteracted = true
            } else {
                selectedIndex = initialIndex
                if block.field_required != true {
                    persistValue(values: values)
                }
            }
        }
        .onChange(of: selectedIndex) { _ in
            if hasUserInteracted {
                persistValue(values: values)
                // Horizontal-only haptic tick. Vertical Picker(.wheel) emits
                // its own haptic natively; doubling would feel off.
                // `haptic_on_scroll == false` suppresses the tick entirely
                // (author opt-out); nil/true keep the default native feel.
                let isHorizontal = block.wheel_orientation == "horizontal" || block.orientation == "horizontal"
                if isHorizontal && block.haptic_on_scroll != false {
                    selectionHaptic.selectionChanged()
                    selectionHaptic.prepare()
                }
            }
        }
    }

    /// iOS 17+ horizontal wheel — uses `.scrollPosition(id:)` +
    /// `.scrollTargetBehavior(.viewAligned)` + `.contentMargins(.scrollContent)`
    /// for native carousel-style behavior: center snap on release,
    /// continuous live highlight as the wheel rolls, no PreferenceKey
    /// plumbing. Uses `LazyHStack` so only the visible window renders
    /// (94 items for age 6-99 would otherwise all re-layout on every
    /// selection change, which caused visible jitter on older code).
    @available(iOS 17.0, *)
    @ViewBuilder
    private func modernHorizontalWheel(values: [Double], initialIndex: Int, unitStr: String, unitPos: String, highlightCol: Color) -> some View {
        let itemWidth = horizontalItemWidth
        let sidePad = UIScreen.main.bounds.width / 2 - itemWidth / 2

        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(0..<values.count, id: \.self) { idx in
                    let val = values[idx]
                    let formatted = val == val.rounded() ? String(Int(val)) : String(format: "%.1f", val)
                    let display = (unitPos == "before" || unitPos == "prefix") ? "\(unitStr)\(formatted)" : "\(formatted)\(unitStr)"
                    Text(display)
                        .font(.system(size: selectedIndex == idx ? 28 : 18, weight: selectedIndex == idx ? .bold : .regular))
                        .foregroundColor(selectedIndex == idx ? highlightCol : .gray)
                        .frame(width: itemWidth, height: 50)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            hasUserInteracted = true
                            withAnimation(.easeOut(duration: 0.18)) { scrollPosIndex = idx }
                        }
                        .id(idx)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, sidePad, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollPosIndex, anchor: .center)
        .frame(height: 60)
        .onAppear {
            if scrollPosIndex == nil {
                scrollPosIndex = initialIndex
            }
        }
        .onChange(of: scrollPosIndex) { _, new in
            guard let new = new, new != selectedIndex else { return }
            hasUserInteracted = true
            selectedIndex = new
        }
    }

    /// iOS 16 fallback horizontal wheel — PreferenceKey-based offset
    /// tracking. Less smooth than iOS 17 (no native snap), but still
    /// tracks the centered item live during drag so the highlight
    /// doesn't go blank mid-scroll.
    @ViewBuilder
    private func legacyHorizontalWheel(values: [Double], initialIndex: Int, unitStr: String, unitPos: String, highlightCol: Color) -> some View {
        let itemWidth = horizontalItemWidth
        let sidePad = UIScreen.main.bounds.width / 2 - itemWidth / 2

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<values.count, id: \.self) { idx in
                        let val = values[idx]
                        let formatted = val == val.rounded() ? String(Int(val)) : String(format: "%.1f", val)
                        let display = (unitPos == "before" || unitPos == "prefix") ? "\(unitStr)\(formatted)" : "\(formatted)\(unitStr)"
                        Text(display)
                            .font(.system(size: selectedIndex == idx ? 28 : 18, weight: selectedIndex == idx ? .bold : .regular))
                            .foregroundColor(selectedIndex == idx ? highlightCol : .gray)
                            .frame(width: itemWidth, height: 50)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                hasUserInteracted = true
                                withAnimation { selectedIndex = idx }
                                withAnimation { proxy.scrollTo(idx, anchor: .center) }
                            }
                            .id(idx)
                    }
                }
                .padding(.horizontal, sidePad)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: WheelScrollOffsetKey.self,
                            value: -geo.frame(in: .named("appdnaWheelScroll")).minX
                        )
                    }
                )
            }
            .coordinateSpace(name: "appdnaWheelScroll")
            .onPreferenceChange(WheelScrollOffsetKey.self) { offset in
                let raw = Int((offset / itemWidth).rounded())
                let centered = max(0, min(values.count - 1, raw))
                if centered != selectedIndex {
                    hasUserInteracted = true
                    selectedIndex = centered
                }
            }
            .onAppear { proxy.scrollTo(initialIndex, anchor: .center) }
        }
        .frame(height: 60)
    }

    /// Persist the currently-selected wheel value to inputValues. Stores
    /// as Int when the value is whole (age, count, quantity), Double
    /// otherwise. Gated by `hasUserInteracted` for required fields so a
    /// pristine default can't silently satisfy validation.
    private func persistValue(values: [Double]) {
        guard !values.isEmpty else { return }
        let fieldId = block.field_id ?? block.id
        let safeIdx = max(0, min(selectedIndex, values.count - 1))
        let v = values[safeIdx]
        let baseValue: String
        if v == v.rounded() {
            inputValues[fieldId] = Int(v)
            baseValue = String(Int(v))
        } else {
            inputValues[fieldId] = v
            baseValue = String(v)
        }
        // SPEC-419 STEP-2 — fire ONLY on a real user commit (not the pristine onAppear auto-persist),
        // so the delegate sees drag-END/commit and never a per-tick storm.
        if hasUserInteracted {
            onInteract(block.id, "value_changed", baseValue)
        }
    }
}

// MARK: - Pulsing Avatar Block View (SPEC-089d AC-014)

/// Avatar image with animated pulsing ring effects.
struct PulsingAvatarBlockView: View {
    let block: ContentBlock

    @State private var isPulsing = false

    var body: some View {
        let avatarSize = CGFloat(block.icon_size ?? block.height ?? 80)
        let pulseCol = Color(hex: block.pulse_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))
        let ringCount = max(1, block.pulse_ring_count ?? 3)  // SPEC-419 pass-23 — guard ForEach(0..<ringCount) trap on negative + pulseDuration/ringCount div-by-zero
        let pulseDuration = block.pulse_speed ?? 1.5
        let borderW = CGFloat(block.border_width ?? 0)
        let borderCol = Color(hex: block.border_color ?? "#FFFFFF")

        let align: Alignment = {
            switch block.alignment {
            case "left": return .leading
            case "right": return .trailing
            default: return .center
            }
        }()

        ZStack {
            // Pulse rings
            ForEach(0..<ringCount, id: \.self) { ringIndex in
                Circle()
                    .stroke(pulseCol.opacity(0.3), lineWidth: 2)
                    .frame(width: avatarSize + CGFloat(ringIndex + 1) * 20,
                           height: avatarSize + CGFloat(ringIndex + 1) * 20)
                    .scaleEffect(isPulsing ? 1.2 : 1.0)
                    .opacity(isPulsing ? 0 : 0.6)
                    .animation(
                        Animation.easeInOut(duration: pulseDuration)
                            .repeatForever(autoreverses: false)
                            .delay(pulseDuration / Double(ringCount) * Double(ringIndex)),
                        value: isPulsing
                    )
            }

            // Avatar image — shape honors block.image_shape ("circle" default |
            // "square" | "rounded"). When "rounded", block.image_corner_radius
            // (default 16) controls the corner radius. Missing field preserves
            // previous circle-crop behavior so existing flows look identical.
            let imageShape = block.image_shape ?? "circle"
            let imageCornerRadius = CGFloat(block.image_corner_radius ?? 16)
            Group {
                if let urlString = block.image_url, let url = URL(string: urlString) {
                    BundledAsyncPhaseImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color.gray.opacity(0.2)
                        }
                    }
                } else {
                    Color.gray.opacity(0.2)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: avatarSize * 0.4))
                                .foregroundColor(.gray)
                        )
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .modifier(AvatarShapeClip(shape: imageShape, cornerRadius: imageCornerRadius))
            .modifier(AvatarShapeBorder(shape: imageShape, cornerRadius: imageCornerRadius, borderWidth: borderW, borderColor: borderCol))

            // Badge — position, size, and corner radius are all config-
            // driven. Previously hardcoded to top-right, caption2 font,
            // and capsule shape. Any unset field falls back to those
            // defaults so existing flows render identically.
            if let badgeText = block.badge_text, !badgeText.isEmpty {
                let badgeScale = CGFloat(block.badge_size ?? 1.0)
                let badgeFontSize: CGFloat = 11 * badgeScale           // caption2 ≈ 11pt
                let badgeHPadding: CGFloat = 6 * badgeScale
                let badgeVPadding: CGFloat = 2 * badgeScale
                // `badge_corner_radius` was already in the Codable struct but
                // the renderer ignored it — we now honor it. 999 mimics
                // the previous Capsule default.
                let badgeRadius = CGFloat(block.badge_corner_radius ?? 999)
                let badgeOffset: CGSize = {
                    let x = avatarSize * 0.35
                    let y = avatarSize * 0.35
                    switch block.badge_position ?? "top_trailing" {
                    case "top_leading": return CGSize(width: -x, height: -y)
                    case "bottom_trailing": return CGSize(width: x, height: y)
                    case "bottom_leading": return CGSize(width: -x, height: y)
                    default: return CGSize(width: x, height: -y)  // top_trailing
                    }
                }()
                Text(badgeText)
                    .font(.system(size: badgeFontSize, weight: .semibold))
                    .foregroundColor(Color(hex: block.badge_text_color ?? "#FFFFFF"))
                    .padding(.horizontal, badgeHPadding)
                    .padding(.vertical, badgeVPadding)
                    .background(Color(hex: block.badge_bg_color ?? "#EF4444"))
                    .clipShape(RoundedRectangle(cornerRadius: badgeRadius))
                    .offset(x: badgeOffset.width, y: badgeOffset.height)
            }
        }
        // Ensure enough space for the outermost pulsing ring at max scale
        .frame(
            width: avatarSize + CGFloat(ringCount + 1) * 20 * 1.3,
            height: avatarSize + CGFloat(ringCount + 1) * 20 * 1.3
        )
        .frame(maxWidth: .infinity, alignment: align)
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Star Background Block View (SPEC-089d AC-027)

/// Animated star/particle background using Canvas + TimelineView.
struct StarBackgroundBlockView: View {
    let block: ContentBlock

    @State private var particles: [StarParticle] = []
    @State private var isActive = true

    var body: some View {
        // SPEC-419 pass-15 #8/#9/#25 — editor authors particle_color/particle_opacity/particle_speed; fall back to legacy native keys.
        let color = Color(hex: block.particle_color ?? block.active_color ?? block.text_color ?? "#FFFFFF")
        // SPEC-419 pass-15 #27 — secondary_color tints 1/3 of particles (matches editor + preview)
        let secondaryColor = block.secondary_color.map { Color(hex: $0) } ?? color
        // Mrozu QA (2026-08-03): particle_type was decoded but the Canvas always drew a
        // circle, so stars/sparkles/snow all looked identical. Render the actual shape.
        let particleType = block.particle_type ?? "stars"  // match console/preview default (element is star_background)
        // Mrozu QA (2026-08-04): confetti = falling multicolor rounded rects. `particle_multicolor`
        // cycles a fixed palette per-particle (defaults ON for confetti). Parity with Android.
        let useMulticolor = block.particle_multicolor ?? (particleType == "confetti")
        let opacity = block.particle_opacity ?? block.block_style?.opacity ?? 0.8
        let particleCount: Int = {
            switch block.density {
            case "sparse": return 20
            case "dense": return 100
            default: return 50
            }
        }()
        let speedFactor: CGFloat = {
            switch block.particle_speed ?? block.speed {
            case "slow": return 0.3
            case "fast": return 1.5
            default: return 0.8
            }
        }()
        let rawMinSize = CGFloat(block.size_range?.first ?? 1)
        let rawMaxSize = CGFloat(block.size_range?.last ?? 3)
        // SPEC-419 pass-23 — guard CGFloat.random(in: minSize...maxSize) against a descending size_range (e.g. [5,2])
        let minSize = min(rawMinSize, rawMaxSize)
        let maxSize = max(rawMinSize, rawMaxSize)
        let isFullscreen = block.fullscreen ?? false
        let height = CGFloat(block.height ?? 200)

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Canvas { context, size in
                for (i, particle) in particles.enumerated() {
                    let rect = CGRect(
                        x: particle.x,
                        y: particle.y,
                        width: particle.size,
                        height: particle.size
                    )
                    context.opacity = particle.opacity * opacity
                    // Mrozu QA (2026-08-04): multicolor confetti cycles the palette; otherwise every
                    // 3rd particle uses secondary_color (SPEC-419 pass-15 #27).
                    let fillColor = useMulticolor
                        ? Self.confettiPalette[i % Self.confettiPalette.count]
                        : (i % 3 == 0 ? secondaryColor : color)
                    context.fill(
                        Self.particlePath(for: particleType, in: rect),
                        with: .color(fillColor)
                    )
                }
            }
            .onChange(of: timeline.date) { _ in
                updateParticles(speedFactor: speedFactor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isFullscreen ? .infinity : height)
        .clipped()
        .onAppear {
            initializeParticles(count: particleCount, minSize: minSize, maxSize: maxSize)
        }
        .onDisappear {
            isActive = false
        }
    }

    private func initializeParticles(count: Int, minSize: CGFloat, maxSize: CGFloat) {
        particles = (0..<count).map { _ in
            StarParticle(
                x: CGFloat.random(in: 0...UIScreen.main.bounds.width),
                y: CGFloat.random(in: 0...(UIScreen.main.bounds.height)),
                size: CGFloat.random(in: minSize...maxSize),
                opacity: Double.random(in: 0.2...1.0),
                speed: CGFloat.random(in: 0.2...1.0)
            )
        }
    }

    private func updateParticles(speedFactor: CGFloat) {
        for i in particles.indices {
            particles[i].y += particles[i].speed * speedFactor
            particles[i].opacity += Double.random(in: -0.02...0.02)
            particles[i].opacity = max(0.1, min(1.0, particles[i].opacity))

            // Wrap around when particle falls off screen
            if particles[i].y > UIScreen.main.bounds.height {
                particles[i].y = -particles[i].size
                particles[i].x = CGFloat.random(in: 0...UIScreen.main.bounds.width)
            }
        }
    }

    // Mrozu QA (2026-08-03): render the configured particle_type. `dots`/`bokeh`
    // stay round; `stars`/`sparkles`/`snow` draw an N-point star polygon so the
    // shape selector is no longer a no-op. Parity with Android drawParticle().
    static func particlePath(for type: String, in rect: CGRect) -> Path {
        switch type {
        case "stars":    return starPath(points: 5, innerRatio: 0.42, in: rect)
        case "sparkles": return starPath(points: 4, innerRatio: 0.30, in: rect)
        case "snow":     return starPath(points: 6, innerRatio: 0.50, in: rect)
        // Mrozu QA (2026-08-04): confetti = small rounded rect (parity w/ Android drawRoundRect).
        case "confetti": return Path(roundedRect: rect, cornerSize: CGSize(width: rect.width * 0.3, height: rect.height * 0.3))
        default:         return Path(ellipseIn: rect) // dots, bokeh
        }
    }

    // Mrozu QA (2026-08-04): fixed confetti palette — MUST stay byte-identical to Android confettiPalette.
    static let confettiPalette: [Color] = [
        Color(hex: "#EF4444"), Color(hex: "#F59E0B"), Color(hex: "#FCD34D"), Color(hex: "#10B981"),
        Color(hex: "#3B82F6"), Color(hex: "#8B5CF6"), Color(hex: "#EC4899"),
    ]

    private static func starPath(points: Int, innerRatio: CGFloat, in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let step = CGFloat.pi / CGFloat(points)
        var angle = -CGFloat.pi / 2 // start pointing up
        for i in 0..<(points * 2) {
            let r = (i % 2 == 0) ? outer : inner
            let pt = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
            angle += step
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Pricing Card Block View (SPEC-089d Nurrai)

/// Renders pricing plan cards in stack or side-by-side layout.
struct PricingCardBlockView: View {
    let block: ContentBlock
    let onAction: (_ action: String, _ actionValue: String?) -> Void
    // Parity with Android (ContentBlockRenderer.kt:7175-7176): persist the tapped plan into
    // inputValues so answer capture + next_step_rules answer_equals on the selection work.
    @Binding var inputValues: [String: Any]

    @State private var selectedPlanId: String? = nil

    var body: some View {
        let plans = block.pricing_plans ?? []
        let isSideBySide = block.pricing_layout == "side_by_side"
        let accentCol = Color(hex: block.active_color ?? block.bg_color ?? (AppDNA.brandAccentHex ?? "#6366F1"))

        Group {
            if isSideBySide {
                HStack(spacing: 12) {
                    ForEach(plans) { plan in
                        planCard(plan, accent: accentCol)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(plans) { plan in
                        planCard(plan, accent: accentCol)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func planCard(_ plan: PricingPlanConfig, accent: Color) -> some View {
        let isHighlighted = plan.is_highlighted ?? false
        let isSelected = selectedPlanId == plan.id

        return Button {
            selectedPlanId = plan.id
            inputValues["selected_plan_id"] = plan.id ?? ""
            inputValues["selected_plan_label"] = plan.label ?? ""
            onAction("select_plan", plan.id)
        } label: {
            VStack(spacing: 6) {
                // Badge
                if let badge = plan.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(accent)
                        .clipShape(Capsule())
                }

                Text(plan.label ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)

                Text(plan.price ?? "")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.primary)

                Text(plan.period ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(isSelected ? accent.opacity(0.05) : Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? accent : (isHighlighted ? accent : Color.gray.opacity(0.3)),
                        lineWidth: isSelected || isHighlighted ? 2 : 1
                    )
            )
            .shadow(color: isHighlighted ? accent.opacity(0.15) : .clear, radius: 4, y: 2)
        }
    }
}

// MARK: - Pulsing Avatar shape helpers (SPEC-085 image_shape)

/// Clip the avatar image per the configured shape. Circle is the legacy
/// default; "square" skips clipping; "rounded" uses cornerRadius.
private struct AvatarShapeClip: ViewModifier {
    let shape: String
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch shape {
        case "square":
            content  // no clipping — full rectangle
        case "rounded":
            content.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        default:
            content.clipShape(Circle())
        }
    }
}

/// Draw the border in the matching shape so stroke lines don't diverge from
/// the clip mask.
private struct AvatarShapeBorder: ViewModifier {
    let shape: String
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let borderColor: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if borderWidth > 0 {
            switch shape {
            case "square":
                content.overlay(Rectangle().stroke(borderColor, lineWidth: borderWidth))
            case "rounded":
                content.overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(borderColor, lineWidth: borderWidth))
            default:
                content.overlay(Circle().stroke(borderColor, lineWidth: borderWidth))
            }
        } else {
            content
        }
    }
}

/// EPIC-8 — swipeable carousel: each child block is a page. Uses a GeometryReader + offset
/// pager (snapshot-reliable, unlike TabView's UIPageViewController) with a custom dot indicator
/// (colors via field_config) tracking the page. Parity with Android's HorizontalPager + dots.
struct CarouselBlockView: View {
    let block: ContentBlock
    let onAction: (_ action: String, _ actionValue: String?) -> Void
    @Binding var toggleValues: [String: Bool]
    @Binding var inputValues: [String: Any]
    @State private var selection = 0

    var body: some View {
        let pages = block.children ?? block.stack_children ?? []
        // Empty carousel collapses to 0 (matches Android, which renders nothing) — was a 240pt blank box.
        let height = pages.isEmpty ? 0 : CGFloat(block.height ?? 240)
        let activeColor = (block.field_config?["indicator_active_color"]?.value as? String).map { Color(hex: $0) } ?? Color(hex: AppDNA.brandAccentHex ?? "#6366F1")
        let inactiveColor = (block.field_config?["indicator_color"]?.value as? String).map { Color(hex: $0) } ?? Color(hex: "#4B5563")
        return VStack(spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                        ContentBlockRendererView(blocks: [page], onAction: onAction, toggleValues: $toggleValues, inputValues: $inputValues)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
                .offset(x: -CGFloat(selection) * geo.size.width)
                .animation(.easeInOut, value: selection)
                .gesture(
                    DragGesture().onEnded { v in
                        if v.translation.width < -50 { selection = min(selection + 1, max(pages.count - 1, 0)) }
                        else if v.translation.width > 50 { selection = max(selection - 1, 0) }
                    }
                )
            }
            .frame(height: height)
            .clipped()
            HStack(spacing: 8) {
                ForEach(0 ..< pages.count, id: \.self) { i in
                    Circle().fill(i == selection ? activeColor : inactiveColor).frame(width: 8, height: 8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
