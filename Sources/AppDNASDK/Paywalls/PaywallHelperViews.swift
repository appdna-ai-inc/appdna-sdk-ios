import SwiftUI
import AVKit

// MARK: - Countdown timer (social proof sub-type)

struct CountdownTimerView: View {
    /// #947 — the page, so a colour nobody authored follows the DOCUMENT rather than the phone.
    /// `.primary` and `.secondary` are black in light appearance and white in dark, and a paywall
    /// forces no colour scheme — so this view drew differently for two users looking at the same
    /// published document. Measured as pixels that change between the two appearances.
    @SwiftUI.Environment(\.paywallBackgroundHex) private var pageBackgroundHex: String?

    let seconds: Int
    var valueTextStyle: TextStyleConfig? = nil
    @State private var remaining: Int
    @State private var countdownTimer: Timer?

    init(seconds: Int, valueTextStyle: TextStyleConfig? = nil) {
        self.seconds = seconds
        self.valueTextStyle = valueTextStyle
        self._remaining = State(initialValue: seconds)
    }

    var body: some View {
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let secs = remaining % 60

        HStack(spacing: 4) {
            timeUnit(hours, label: "h")
            Text(":").foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
            timeUnit(minutes, label: "m")
            Text(":").foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
            timeUnit(secs, label: "s")
        }
        .onAppear {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                if remaining > 0 {
                    remaining -= 1
                } else {
                    timer.invalidate()
                }
            }
        }
        .onDisappear {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func timeUnit(_ value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            if let ts = valueTextStyle {
                Text(String(format: "%02d", value))
                    .applyTextStyle(ts)
                    .monospacedDigit()
            } else {
                Text(String(format: "%02d", value))
                    .font(.title2.monospacedDigit().bold())
                    .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex))
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(PaywallTextDefaults.readable(on: pageBackgroundHex).opacity(0.7))
        }
        .frame(minWidth: 40)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.1))
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
         * #885 — a string that is not pure hex is not a colour.
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
        // #885 — same guard as `Color(hex:)`: a non-hex string is not a light colour, it is not a
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
    /// #947 — the page, so a colour nobody authored follows the DOCUMENT rather than the phone.
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
    /// #947 — whether `indicatorColor` came from the document. An authored colour is drawn as
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
                         #947 — the inactive dot at `subtleAlpha`, which is what Android draws
                         (#938). Both defaults now resolve from the PAGE, so the same published
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
    /// #910 — the container halves of the same two elements. `card` already had one; the console
    /// offers an ElementStylePanel for `text` and `author` too, and neither was read.
    var textElementStyle: ElementStyleConfig? = nil
    var authorElementStyle: ElementStyleConfig? = nil
    let loc: (String, String) -> String

    /// #938 — the page this carousel is drawn on, so a dot nobody authored can be read off it.
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
                     * #938 — a dot nobody authored, READ OFF THE PAGE.
                     *
                     * This was `Color.white` and `Color.white.opacity(0.3)`. Over a WHITE page that
                     * is no dots at all, so a reader had no way to tell how many reviews there
                     * were or which one they were on. Android carried the identical constant and
                     * now resolves it the same way (#938).
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
