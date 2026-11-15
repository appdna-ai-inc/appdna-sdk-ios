import UIKit
import ImageIO

/// Meta's two Facebook marks, decoded once each from the SDK bundle.
///
/// The files are Meta's logo pack PNGs, byte-identical and 2084 × 2084. Decoding one at full size
/// costs ~17 MB for an image drawn at 20pt, so it is decoded through ImageIO's thumbnailer at 96px
/// (enough for 20pt at 3× with headroom). That is a scale, not an edit: the shipped file is untouched.
enum FacebookMarkImage {
    private static let lock = NSLock()
    private static var cache: [FacebookMark.Variant: UIImage] = [:]

    static func image(_ variant: FacebookMark.Variant) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[variant] { return hit }
        guard let url = AppDNAResources.bundle?.url(forResource: variant.resourceName, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg, scale: 3, orientation: .up)
        cache[variant] = image
        return image
    }
}
