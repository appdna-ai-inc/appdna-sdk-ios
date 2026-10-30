import SwiftUI
import AVKit

// MARK: - Countdown timer (social proof sub-type)

struct CountdownTimerView: View {
    /// The page, so a colour nobody authored follows the DOCUMENT rather than the phone.
    /// `.primary` and `.secondary` are black in light appearance and white in dark, and a paywall
    /// forces no colour scheme — so this view drew differently for two users looking at the same
    /// published document. Measured as pixels that change between the two appearances.
    @SwiftUI.Environment(\.paywallBackgroundHex) private var pageBackgroundHex: String?

    let seconds: Int
    var valueTextStyle: TextStyleConfig? = nil

    /*
     * The six fields that were decoded by both SDKs and read by NOTHING.
     *
     * A timer reached zero and sat at `00:00:00`, which is the one outcome none of
     * `on_expire_action`'s three values describes. They were in the type definitions, so every
     * reader believed they worked, and the paywall generator could author them into real documents
     * where nothing honoured them.
     *
     * `showDays` and its siblings are a FORMAT choice: with days shown, a 3-day countdown reads
     * "02d 23h 59m" instead of "71h 59m". Unset means the historical layout — hours, minutes and
     * seconds — so no published paywall changes.
     */
    var showDays: Bool? = nil
    var showHours: Bool? = nil
    var showMinutes: Bool? = nil
    var showSeconds: Bool? = nil
    /// `hide` | `show_expired_text` | `auto_advance`. Unset leaves the zeroed timer on screen,
    /// which is what shipped before, so an unauthored paywall is unchanged.
    var onExpireAction: String? = nil
    var expiredText: String? = nil
    /// What `auto_advance` calls. The paywall owns its own dismissal, so the renderer passes its
    /// dismiss closure in rather than this view reaching for one.
    var onExpire: (() -> Void)? = nil
    /*
     * The digits' own three console controls. Unset, they keep exactly the values this view
     * hard-coded (`.title2` ≈ 22pt, bold, the page-readable ink), so a countdown nobody has styled
     * draws the pixels it drew before. `valueTextStyle` still wins outright where it is set: it is
     * the design-system channel and the more specific of the two.
     */
    var digitFontSize: CGFloat? = nil
    var digitFontWeight: String? = nil
    var digitColorHex: String? = nil
    /*
     * `digital` | `circular` | `flip` | `bar`. The console's Variant select offered all four,
     * `CountdownConfigSchema` persisted all four, the generator wrote one on every countdown it
     * produced, and NO renderer on any platform read it: every paywall countdown drew `digital`.
     *
     * The four designs are ported from the ONBOARDING countdown block, which has implemented them
     * on both platforms all along — so the same authored value now looks the same on a paywall as
     * it does in a flow, rather than two surfaces inventing two looks.
     *
     * Unset is `digital`, which is what every published paywall drew, so nothing restyles.
     */
    var variant: String? = nil

    @State private var remaining: Int
    @State private var countdownTimer: Timer?
    @State private var didFireExpiry = false

    init(
        seconds: Int,
        valueTextStyle: TextStyleConfig? = nil,
        showDays: Bool? = nil,
        showHours: Bool? = nil,
        showMinutes: Bool? = nil,
        showSeconds: Bool? = nil,
        onExpireAction: String? = nil,
        expiredText: String? = nil,
        onExpire: (() -> Void)? = nil,
        digitFontSize: CGFloat? = nil,
        digitFontWeight: String? = nil,
        digitColorHex: String? = nil,
        variant: String? = nil
    ) {
        self.seconds = seconds
        self.valueTextStyle = valueTextStyle
        self.showDays = showDays
        self.showHours = showHours
        self.showMinutes = showMinutes
        self.showSeconds = showSeconds
        self.onExpireAction = onExpireAction
        self.expiredText = expiredText
        self.onExpire = onExpire
        self.digitFontSize = digitFontSize
        self.digitFontWeight = digitFontWeight
        self.digitColorHex = digitColorHex
        self.variant = variant
        self._remaining = State(initialValue: seconds)
    }

    /// Which units to draw. Unset = the historical h:m:s, so an unauthored paywall is byte-identical.
    private var units: (days: Bool, hours: Bool, minutes: Bool, seconds: Bool) {
        let anyAuthored = showDays != nil || showHours != nil || showMinutes != nil || showSeconds != nil
        guard anyAuthored else { return (false, true, true, true) }
        return (showDays ?? false, showHours ?? true, showMinutes ?? true, showSeconds ?? true)
    }

    private var hasExpired: Bool { remaining <= 0 }

    var body: some View {
        // `hide` removes the section outright once the timer is spent; everything else keeps
        // drawing, so the `expired_text` and default cases share the layout below.
        Group {
            if hasExpired && onExpireAction == "hide" {
                EmptyView()
            } else if hasExpired, onExpireAction == "show_expired_text", let text = expiredText, !text.isEmpty {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
            } else {
                // The authored variant, through the shared rule that owns the fallback.
                switch PaywallCountdownVariant.resolve(variant) {
                case "circular": circularTimer
                case "flip": flipTimer
                case "bar": barTimer
                default: digits
                }
            }
        }
        .onAppear {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                if remaining > 0 {
                    remaining -= 1
                    if remaining == 0 { fireExpiryIfNeeded() }
                } else {
                    timer.invalidate()
                    fireExpiryIfNeeded()
                }
            }
            // A timer authored at zero (or restored past its deadline) expires without ever ticking.
            if hasExpired { fireExpiryIfNeeded() }
        }
        .onDisappear {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    /// 🔴 Once only. The timer fires every second and the `remaining <= 0` branch is reached on each
    /// of them, so without this guard `auto_advance` would dismiss repeatedly.
    private func fireExpiryIfNeeded() {
        guard !didFireExpiry else { return }
        didFireExpiry = true
        if onExpireAction == "auto_advance" { onExpire?() }
    }

    private var digits: some View {
        let u = units
        let days = remaining / 86_400
        // With days hidden, the hours column carries the whole remainder — 71h rather than 2d 23h.
        let hours = u.days ? (remaining % 86_400) / 3600 : remaining / 3600
        let minutes = (remaining % 3600) / 60
        let secs = remaining % 60

        return HStack(spacing: 4) {
            if u.days { timeUnit(days, label: "d") }
            if u.days && u.hours { separator }
            if u.hours { timeUnit(hours, label: "h") }
            if u.hours && u.minutes { separator }
            if u.minutes { timeUnit(minutes, label: "m") }
            if u.minutes && u.seconds { separator }
            if u.seconds { timeUnit(secs, label: "s") }
        }
    }

    /// An authored digit colour tints the whole digit row — the chips behind the numbers, the unit
    /// letters and the `:` between them — because they are all one element to an author.
    private var digitInk: Color {
        if let hex = digitColorHex, !hex.isEmpty { return Color(hex: hex) }
        return PaywallTextDefaults.readable(on: pageBackgroundHex)
    }


    /*
     * The three variants beyond `digital`, ported from the onboarding countdown block so an
     * authored value looks the same on a paywall as it does in a flow.
     *
     * Each reuses this view's own ink, digit font and segment maths rather than re-deriving them:
     * `valueTextStyle`, `digitFontSize`/`digitFontWeight` and the units ladder are authored once and
     * must not mean one thing in `digital` and another in `flip`.
     */

    /// The segments as zero-padded strings, in the order the units ladder selects them.
    private var segmentStrings: [String] {
        let u = units
        let days = remaining / 86_400
        let hours = u.days ? (remaining % 86_400) / 3600 : remaining / 3600
        let minutes = (remaining % 3600) / 60
        let secs = remaining % 60
        var out: [String] = []
        if u.days { out.append(String(format: "%02d", days)) }
        if u.hours { out.append(String(format: "%02d", hours)) }
        if u.minutes { out.append(String(format: "%02d", minutes)) }
        if u.seconds { out.append(String(format: "%02d", secs)) }
        return out
    }

    /// The unit labels matching `segmentStrings`, one per segment.
    private var segmentLabels: [String] {
        let u = units
        var out: [String] = []
        if u.days { out.append("d") }
        if u.hours { out.append("h") }
        if u.minutes { out.append("m") }
        if u.seconds { out.append("s") }
        return out
    }

    /// How much of the countdown is left, 0…1 — the ring's sweep and the bar's width.
    ///
    /// 🔴 One shared rule with Android and with the onboarding block: this was a frozen
    /// `0.75` in the onboarding renderers, the preview's mock, and the ring never moved.
    private var progressFraction: CGFloat {
        CGFloat(CountdownProgress.remainingFraction(remainingSeconds: remaining, initialSeconds: seconds))
    }

    /// A ring that empties as the timer runs, with the joined time centred in it.
    private var circularTimer: some View {
        ZStack {
            // The TRACK, derived from the page-readable ink rather than a hardcoded light grey:
            // a fixed colour cannot follow the page, which `check:authorability` caught as an orphan literal here. A fixed
            // `#E5E7EB` is invisible on a light page and a bright band on a dark one.
            Circle().stroke(digitInk.opacity(0.2), lineWidth: 4)
            Circle().trim(from: 0, to: progressFraction)
                .stroke(digitInk, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(segmentStrings.joined(separator: ":"))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(digitInk)
        }
        .frame(width: 80, height: 80)
        .frame(maxWidth: .infinity)
    }

    /// Each segment on its own tinted card, with the unit label beneath.
    private var flipTimer: some View {
        let labels = segmentLabels
        return HStack(spacing: 8) {
            ForEach(Array(segmentStrings.enumerated()), id: \.offset) { i, seg in
                VStack(spacing: 4) {
                    Text(seg)
                        .font(.system(size: digitFontSize ?? 24, weight: resolvePaywallFontWeight(digitFontWeight, default: .bold), design: .monospaced))
                        .foregroundColor(digitInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(digitInk.opacity(0.1)))
                    Text(i < labels.count ? labels[i] : "")
                        .font(.caption2)
                        .foregroundColor(digitInk.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The time on one line with a bar beneath it that shrinks as the timer runs.
    private var barTimer: some View {
        VStack(spacing: 8) {
            HStack {
                Text(segmentStrings.joined(separator: ":"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(digitInk)
                Spacer()
                /*
                 * Plain text, matching the onboarding block and Android's `Text("remaining")`
                 * exactly. The renderer's `loc(_:_:)` is private to `PaywallRenderer` and there is
                 * no SDK-wide string table, so localising it HERE would make one of three places
                 * translatable and leave two in English — a worse state than three consistent ones.
                 * Tracked as its own gap rather than fixed unevenly.
                 */
                Text("remaining")
                    .font(.subheadline)
                    .foregroundColor(digitInk.opacity(0.7))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(digitInk.opacity(0.2)).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(digitInk).frame(width: geo.size.width * progressFraction, height: 8)
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Text(":").foregroundColor(digitInk.opacity(0.7))
    }

    private func timeUnit(_ value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            if let ts = valueTextStyle {
                Text(String(format: "%02d", value))
                    .applyTextStyle(ts)
                    .monospacedDigit()
            } else {
                Text(String(format: "%02d", value))
                    .font(.system(size: digitFontSize ?? 22, weight: resolvePaywallFontWeight(digitFontWeight, default: .bold)).monospacedDigit())
                    .foregroundColor(digitInk)
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(digitInk.opacity(0.7))
        }
        .frame(minWidth: 40)
        .padding(.vertical, 6)
        /*
         * The chip was a hard-coded `Color.white.opacity(0.1)`, which on a light page is
         * invisible: Android already drew it in the page-readable ink, so one platform
         * showed a grey chip behind each number and the other showed none. Byte-identical on a
         * dark page, where `readable` IS white.
         */
        .background(digitInk.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Color hex extension

extension Color {
    init(hex: String) {
        // Handle named colors
        let lowered = hex.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered == "transparent" || lowered == "clear" {
            self = Color.clear
            return
        }
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        /*
         * A string that is not pure hex is not a colour.
         *
         * The line above only trims the ENDS, so what reaches `case 6` is any six-character
         * alphanumeric run — and a CSS colour NAME of exactly six letters is one: `orange`,
         * `purple`, `yellow`, `silver`, `maroon`, `indigo`, `violet`, `salmon`, `tomato`. The
         * Scanner stops at the first non-hex character, leaves `int` at 0, and `case 6` renders it
         * **opaque black**. Android's `StyleEngine.parseColor` throws on the same input and returns
         * transparent, so one authored word gave a black screen on one platform and a see-through
         * one on the other.
         *
         * `rgba(…)` escaped this only by landing on a length the switch rejects. This makes the
         * answer a rule instead of an accident, for every spelling.
         */
        guard !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit }) else {
            self = Color.clear
            return
        }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hex.count {
        case 6:
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (0, 0, 0, 0) // Default to transparent, not black
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Returns true when the given hex string represents a light color
    /// (perceived luminance ≥ 0.6). Used to auto-detect dark-theme UI
    /// contexts (e.g. force `.colorScheme(.dark)` on native pickers).
    static func isLightHex(_ hex: String) -> Bool {
        let lowered = hex.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered == "transparent" || lowered == "clear" { return false }
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        // Same guard as `Color(hex:)`: a non-hex string is not a light colour, it is not a
        // colour at all. Without it `orange` scanned as 0 and reported "dark" with confidence.
        guard !clean.isEmpty, clean.allSatisfy({ $0.isHexDigit }) else { return false }
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let r, g, b: Double
        switch clean.count {
        case 6:
            r = Double(int >> 16) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        case 8:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            return false
        }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance >= 0.6
    }
}

// MARK: - Video background view

struct VideoBackgroundView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .disabled(true)  // No controls for background
                    .onAppear {
                        player.isMuted = true
                        player.play()
                        // Loop the video (register observer once)
                        if loopObserver == nil {
                            loopObserver = NotificationCenter.default.addObserver(
                                forName: .AVPlayerItemDidPlayToEndTime,
                                object: player.currentItem,
                                queue: .main
                            ) { _ in
                                player.seek(to: .zero)
                                player.play()
                            }
                        }
                    }
                    .onDisappear {
                        if let observer = loopObserver {
                            NotificationCenter.default.removeObserver(observer)
                            loopObserver = nil
                        }
                    }
            } else {
                Color.black
            }
        }
        .onAppear {
            player = AVPlayer(url: url)
        }
    }
}

// MARK: - Promo state enum

enum PromoState: Equatable {
    case idle
    case loading
    case success
    case error
}

// MARK: - Line shape for dashed/dotted dividers

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Carousel sub-view

struct CarouselView: View {
    /// The page, so a colour nobody authored follows the DOCUMENT rather than the phone.
    /// `.primary` and `.secondary` are black in light appearance and white in dark, and a paywall
    /// forces no colour scheme — so this view drew differently for two users looking at the same
    /// published document. Measured as pixels that change between the two appearances.
    @SwiftUI.Environment(\.paywallBackgroundHex) private var pageBackgroundHex: String?

    let pages: [PaywallCarouselPage]
    let config: PaywallConfig
    let autoScroll: Bool
    let autoScrollIntervalMs: Int
    let showIndicators: Bool
    let indicatorColor: String
    /// Whether `indicatorColor` came from the document. An authored colour is drawn as
    /// authored; a resolved default is drawn at `subtleAlpha`, matching Android.
    var hasAuthoredIndicatorColor: Bool = false
    let indicatorActiveColor: String
    let height: CGFloat?
    let loc: (String, String) -> String

    @State private var currentPage = 0
    @State private var autoScrollTimer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    VStack(spacing: 8) {
                        if let children = page.children {
                            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                                // Render child sections (simplified: render text/title if present)
                                if let title = child.data?.title {
                                    Text(title)
                                        .font(.headline)
                                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
                                }
                                if let subtitle = child.data?.subtitle {
                                    Text(subtitle)
                                        .font(.subheadline)
                                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                                }
                                if let imageUrl = child.data?.imageUrl, let url = URL(string: imageUrl) {
                                    BundledAsyncImage(url: url) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .frame(maxHeight: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                    .tag(index)
                    .padding(.horizontal, 4)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: showIndicators ? .always : .never))
            .frame(height: height ?? 200)

            // Custom indicators (when show_indicators is true but we want custom colors)
            if showIndicators {
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { idx in
                        /*
                         The inactive dot at `subtleAlpha`, which is what Android draws.
                         Both defaults now resolve from the PAGE, so the same published
                         document shows the same two greys on either platform; an authored
                         `indicator_color` is still taken at full strength.
                        */
                        Circle()
                            .fill(idx == currentPage
                                  ? Color(hex: indicatorActiveColor)
                                  : Color(hex: indicatorColor)
                                      .opacity(hasAuthoredIndicatorColor ? 1.0 : PaywallTextDefaults.subtleAlpha))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .onAppear {
            guard autoScroll else { return }
            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: Double(autoScrollIntervalMs) / 1000.0, repeats: true) { _ in
                withAnimation {
                    currentPage = (currentPage + 1) % max(pages.count, 1)
                }
            }
        }
        .onDisappear {
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
        }
    }
}

// MARK: - Reviews carousel sub-view

struct ReviewsCarouselView: View {
    let reviews: [PaywallReview]
    let autoScroll: Bool
    let autoScrollIntervalMs: Int
    let showRatingStars: Bool
    let starColor: String
    let textStyle: TextStyleConfig?
    let authorStyle: TextStyleConfig?
    let cardStyle: ElementStyleConfig?
    /// The container halves of the same two elements. `card` already had one; the console
    /// offers an ElementStylePanel for `text` and `author` too, and neither was read.
    var textElementStyle: ElementStyleConfig? = nil
    var authorElementStyle: ElementStyleConfig? = nil
    let loc: (String, String) -> String

    /// The page this carousel is drawn on, so a dot nobody authored can be read off it.
    ///
    /// Taken from the environment rather than added as a parameter: the renderer already publishes
    /// it (`PaywallRenderer.swift:182`) and every call site keeps working untouched. Spelled
    /// `@SwiftUI.Environment` with an explicit type, as `PlanCard`, `HeaderSection` and `CTAButton`
    /// all are — the SDK has an `Environment` of its own and the bare attribute resolves to that.
    @SwiftUI.Environment(\.paywallBackgroundHex) private var pageBackgroundHex: String?

    @State private var currentReview = 0
    @State private var autoScrollTimer: Timer?

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $currentReview) {
                ForEach(Array(reviews.enumerated()), id: \.offset) { index, review in
                    VStack(spacing: 12) {
                        // Star rating
                        if showRatingStars, let rating = review.rating {
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { star in
                                    Image(systemName: Double(star) < rating ? "star.fill" : "star")
                                        .font(.caption)
                                        .foregroundColor(Color(hex: starColor))
                                }
                            }
                        }

                        // Quote text
                        Group {
                            if let ts = textStyle {
                                Text("\u{201C}\(review.text ?? "")\u{201D}")
                                    .applyTextStyle(ts)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("\u{201C}\(review.text ?? "")\u{201D}")
                                    .font(.subheadline)
                                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .italic()
                            }
                        }
                        .applyElementStyle(textElementStyle)

                        // Author
                        HStack(spacing: 8) {
                            if let avatarUrl = review.avatarUrl, let url = URL(string: avatarUrl) {
                                BundledAsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Circle().fill(Color.gray.opacity(0.3))
                                }
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                            } else if let emoji = review.avatarEmoji, !emoji.isEmpty {
                                // Show emoji avatar (convert descriptive names to actual emoji, or use as-is)
                                let displayEmoji = Self.emojiFromName(emoji)
                                Text(displayEmoji)
                                    .font(.system(size: 18))
                                    .frame(width: 28, height: 28)
                                    .background(Color.gray.opacity(0.15))
                                    .clipShape(Circle())
                            } else if let author = review.author, !author.isEmpty {
                                // Colored circle with initial
                                let initial = String(author.prefix(1)).uppercased()
                                Circle()
                                    .fill(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")).opacity(0.2))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Text(initial)
                                            .font(.caption.bold())
                                            .foregroundColor(Color(hex: (AppDNA.brandAccentHex ?? "#6366F1")))
                                    )
                            }

                            Group {
                                if let as_ = authorStyle {
                                    Text(review.author ?? "").applyTextStyle(as_)
                                } else {
                                    Text(review.author ?? "")
                                        .font(.caption.weight(.medium))
                                        .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                                }
                            }
                            .applyElementStyle(authorElementStyle)

                            if let date = review.date {
                                Text(date)
                                    .font(.caption2)
                                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(hex: "#F9FAFB"))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 8)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 200)

            // Page dots
            HStack(spacing: 6) {
                ForEach(0..<reviews.count, id: \.self) { idx in
                    /*
                     * A dot nobody authored, READ OFF THE PAGE.
                     *
                     * This was `Color.white` and `Color.white.opacity(0.3)`. Over a WHITE page that
                     * is no dots at all, so a reader had no way to tell how many reviews there
                     * were or which one they were on. Android carried the identical constant and
                     * now resolves it the same way.
                     *
                     * Byte-identical on a dark page: `readable` returns `#FFFFFF` wherever white
                     * passes AA, so a dark paywall draws exactly what it drew before.
                     */
                    Circle()
                        .fill(idx == currentReview
                              ? PaywallTextDefaults.readable(on: pageBackgroundHex)
                              : PaywallTextDefaults.subtle(on: pageBackgroundHex))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .onAppear {
            guard autoScroll else { return }
            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: Double(autoScrollIntervalMs) / 1000.0, repeats: true) { _ in
                withAnimation {
                    currentReview = (currentReview + 1) % max(reviews.count, 1)
                }
            }
        }
        .onDisappear {
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
        }
    }

    /// Convert descriptive emoji names (e.g. "woman", "man") to actual emoji characters.
    /// If the name is already an emoji character, return as-is.
    static func emojiFromName(_ name: String) -> String {
        // If it's already an emoji (single character or emoji sequence), return as-is
        if name.count <= 2 && name.unicodeScalars.allSatisfy({ $0.value > 127 }) {
            return name
        }
        let map: [String: String] = [
            "woman": "\u{1F469}", "man": "\u{1F468}", "girl": "\u{1F467}", "boy": "\u{1F466}",
            "baby": "\u{1F476}", "older_woman": "\u{1F475}", "older_man": "\u{1F474}",
            "person": "\u{1F9D1}", "star": "\u{2B50}", "heart": "\u{2764}\u{FE0F}",
            "thumbsup": "\u{1F44D}", "fire": "\u{1F525}", "rocket": "\u{1F680}",
            "smile": "\u{1F604}", "clap": "\u{1F44F}", "sparkles": "\u{2728}",
        ]
        return map[name.lowercased()] ?? "\u{1F464}" // fallback: bust silhouette
    }
}
