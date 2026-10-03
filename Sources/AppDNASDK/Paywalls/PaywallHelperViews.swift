import SwiftUI
import AVKit

// MARK: - Countdown timer (social proof sub-type)

struct CountdownTimerView: View {
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
            Text(":").foregroundColor(.secondary)
            timeUnit(minutes, label: "m")
            Text(":").foregroundColor(.secondary)
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
                    .foregroundColor(.primary)
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
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
    let pages: [PaywallCarouselPage]
    let config: PaywallConfig
    let autoScroll: Bool
    let autoScrollIntervalMs: Int
    let showIndicators: Bool
    let indicatorColor: String
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
                                        .foregroundColor(.primary)
                                }
                                if let subtitle = child.data?.subtitle {
                                    Text(subtitle)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
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
                        Circle()
                            .fill(idx == currentPage
                                  ? Color(hex: indicatorActiveColor)
                                  : Color(hex: indicatorColor))
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
    let loc: (String, String) -> String

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
                        if let ts = textStyle {
                            Text("\u{201C}\(review.text ?? "")\u{201D}")
                                .applyTextStyle(ts)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("\u{201C}\(review.text ?? "")\u{201D}")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .italic()
                        }

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

                            if let as_ = authorStyle {
                                Text(review.author ?? "").applyTextStyle(as_)
                            } else {
                                Text(review.author ?? "")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.secondary)
                            }

                            if let date = review.date {
                                Text(date)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
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
                    Circle()
                        .fill(idx == currentReview ? Color.white : Color.white.opacity(0.3))
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
