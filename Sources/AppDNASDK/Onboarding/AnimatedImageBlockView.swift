import SwiftUI
import UIKit

/**
 `animated_image` — one long image (a photo collage, say 1600×400) scrolling in a seamless loop.

 The image fills the block across the scroll axis (its height for left/right, its width for
 up/down) and is repeated along it; the strip moves at `scroll_speed` points per second. Copies sit
 exactly one image-length apart, so shifting by that length looks identical: the offset is the
 distance travelled MODULO that length and the loop never jumps.

 Mirrors `src/lib/onboarding/animated-image.ts` and Android `AnimatedImageMarquee`. Pinned on both
 platforms by the shared fixture `dto_parsing/animated_image_marquee`.
 */
public enum AnimatedImageMarquee {
    public static let defaultSpeed: Double = 30
    public static let minSpeed: Double = 1
    public static let maxSpeed: Double = 400
    public static let defaultHeight: Double = 200

    /// `field_config.scroll_direction`: left | right | up | down; anything else is left.
    public static func direction(_ raw: Any?) -> String {
        if let s = raw as? String, ["left", "right", "up", "down"].contains(s) { return s }
        return "left"
    }

    /// `field_config.scroll_speed` in points per second, clamped; unreadable is the default.
    public static func speed(_ raw: Any?) -> Double {
        var n = Double.nan
        if raw is Bool {
            n = .nan
        } else if let d = raw as? Double {
            n = d
        } else if let i = raw as? Int {
            n = Double(i)
        } else if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            n = t.isEmpty ? .nan : (Double(t) ?? .nan)
        }
        guard n.isFinite else { return defaultSpeed }
        return min(maxSpeed, max(minSpeed, n))
    }

    public static func isVertical(_ direction: String) -> Bool { direction == "up" || direction == "down" }

    /// One copy's length along the scroll axis, from the image's natural size; 0 until it has loaded.
    public static func tileLength(direction: String, naturalSize: CGSize, blockSize: CGSize) -> Double {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return 0 }
        return isVertical(direction)
            ? Double(blockSize.width) * Double(naturalSize.height / naturalSize.width)
            : Double(blockSize.height) * Double(naturalSize.width / naturalSize.height)
    }

    /// The strip's translation along its axis after `elapsed` seconds. Left / up run 0 → −L,
    /// right / down −L → 0, so the window is always covered from its leading edge.
    public static func offset(direction: String, speed: Double, tileLength: Double, elapsed: Double) -> Double {
        guard tileLength > 0, elapsed.isFinite else { return 0 }
        let travelled = (speed * max(0, elapsed)).truncatingRemainder(dividingBy: tileLength)
        let toward = (direction == "left" || direction == "up") ? -travelled : travelled - tileLength
        let rounded = (toward * 1000).rounded() / 1000
        return rounded == 0 ? 0 : rounded
    }

    /// Copies that cover a window `viewport` long while the strip moves by up to one copy.
    public static func copies(viewport: Double, tileLength: Double) -> Int {
        guard tileLength > 0 else { return 0 }
        return max(2, Int((viewport / tileLength).rounded(.up)) + 1)
    }
}

/// Loads the block's image as a `UIImage` (its natural size is what the strip is laid out from):
/// a bundled asset first, then the shared URL cache, then the network.
@MainActor
final class AnimatedImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    private var loadedURL: String?

    func load(_ urlString: String?) {
        guard let urlString, !urlString.isEmpty, urlString != loadedURL else { return }
        loadedURL = urlString
        image = nil
        guard let url = URL(string: urlString) else { return }
        if urlString.hasPrefix("appdna-assets/") {
            let file = urlString.replacingOccurrences(of: "appdna-assets/", with: "")
            let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
            if let path = Bundle.main.path(forResource: name, ofType: ext, inDirectory: "appdna-assets") ?? Bundle.main.path(forResource: name, ofType: ext),
               let ui = UIImage(contentsOfFile: path) {
                image = ui
                return
            }
        }
        if url.isFileURL, let ui = UIImage(contentsOfFile: url.path) {
            image = ui
            return
        }
        let request = URLRequest(url: url)
        if let cached = URLCache.shared.cachedResponse(for: request), let ui = UIImage(data: cached.data) {
            image = ui
            return
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let ui = UIImage(data: data) else { return }
            Task { @MainActor in
                guard let self, self.loadedURL == urlString else { return }
                self.image = ui
            }
        }.resume()
    }
}

struct AnimatedImageBlockView: View {
    let block: ContentBlock
    @StateObject private var loader = AnimatedImageLoader()

    var body: some View {
        // Nothing to scroll draws nothing — as the image block does with no URL.
        if let url = block.image_url, !url.trimmingCharacters(in: .whitespaces).isEmpty {
            strip
        }
    }

    private var strip: some View {
        let fc = block.field_config?.mapValues { $0.value }
        let height = CGFloat(max(1, block.height ?? AnimatedImageMarquee.defaultHeight))
        return AnimatedImageStrip(
            image: loader.image,
            direction: AnimatedImageMarquee.direction(fc?["scroll_direction"]),
            speed: AnimatedImageMarquee.speed(fc?["scroll_speed"])
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(block.corner_radius ?? 0)))
        .onAppear { loader.load(block.image_url) }
        .onChange(of: block.image_url) { loader.load($0) }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(block.alt ?? "")
        .accessibilityHidden((block.alt ?? "").isEmpty)
    }
}

/// The moving strip itself, given the loaded image. Separate from the loader so a test can draw it
/// with an image in hand at a fixed moment (`startDate` + `now`).
struct AnimatedImageStrip: View {
    let image: UIImage?
    let direction: String
    let speed: Double
    /// When the loop started, and — for a test — the moment to draw. `nil` = the animation clock.
    var startDate: Date = Date()
    var now: Date? = nil

    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            if let image {
                if let now {
                    strip(image, size: geo.size, elapsed: now.timeIntervalSince(startDate))
                } else {
                    TimelineView(.animation) { ctx in
                        strip(image, size: geo.size, elapsed: ctx.date.timeIntervalSince(start))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func strip(_ image: UIImage, size: CGSize, elapsed: Double) -> some View {
        let vertical = AnimatedImageMarquee.isVertical(direction)
        let tile = AnimatedImageMarquee.tileLength(direction: direction, naturalSize: image.size, blockSize: size)
        let n = AnimatedImageMarquee.copies(viewport: Double(vertical ? size.height : size.width), tileLength: tile)
        let off = CGFloat(AnimatedImageMarquee.offset(direction: direction, speed: speed, tileLength: tile, elapsed: elapsed))
        if vertical {
            VStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { _ in
                    Image(uiImage: image).resizable().frame(width: size.width, height: CGFloat(tile))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .offset(y: off)
        } else {
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { _ in
                    Image(uiImage: image).resizable().frame(width: CGFloat(tile), height: size.height)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .leading)
            .offset(x: off)
        }
    }
}
