import SwiftUI
import CoreText

/// Downloads and registers custom fonts (.ttf/.otf) referenced by a hosted URL in config.
/// Any element whose `font_family` value is a font URL (instead of a built-in family
/// identifier) renders that font — the loader downloads it once, caches it on disk, and
/// registers it with the process font manager so `FontResolver` can hand back a real
/// PostScript name.
///
/// The file-UPLOAD backend (storing an author-uploaded .ttf → serving a stable URL) is
/// separate infrastructure; this loader works with ANY hosted font URL today.
enum FontLoader {

    private static let queue = DispatchQueue(label: "ai.appdna.fontloader")
    /// url string -> registered PostScript name
    private static var registeredNames: [String: String] = [:]
    private static var inFlight: Set<String> = []

    /// True when a `font_family` value is a hosted custom-font URL rather than a
    /// built-in family identifier.
    static func isCustomFontURL(_ value: String?) -> Bool {
        guard let v = value?.lowercased() else { return false }
        guard v.hasPrefix("http://") || v.hasPrefix("https://") else { return false }
        return v.hasSuffix(".ttf") || v.hasSuffix(".otf")
            || v.contains(".ttf?") || v.contains(".otf?")
    }

    /// Returns the registered PostScript name for a font URL once it has been downloaded
    /// and registered; otherwise returns `nil` and kicks off a one-time background
    /// download. Callers fall back to the system font until the name becomes available
    /// (config re-render picks it up on the next pass).
    static func registeredName(forURL urlString: String) -> String? {
        var result: String?
        var shouldStart = false
        queue.sync {
            result = registeredNames[urlString]
            if result == nil && !inFlight.contains(urlString) {
                inFlight.insert(urlString)
                shouldStart = true
            }
        }
        if shouldStart {
            DispatchQueue.global(qos: .userInitiated).async { download(urlString) }
        }
        return result
    }

    // MARK: - Private

    /// Deterministic FNV-1a hash over the URL's UTF-8 bytes. `String.hashValue` is
    /// seeded randomly PER PROCESS (Swift ≥4.2), so it yielded a different cache
    /// filename on every cold launch — the on-disk cache was effectively dead and
    /// the font was re-downloaded every app start. This stable hash survives
    /// launches, matching Android's `urlString.hashCode()` reuse-forever behavior.
    private static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func cacheURL(for urlString: String) -> URL {
        let ext = urlString.lowercased().contains(".otf") ? "otf" : "ttf"
        let name = "\(stableHash(urlString)).\(ext)"
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("appdna-fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private static func download(_ urlString: String) {
        guard let url = URL(string: urlString) else { finish(urlString, nil); return }
        let dest = cacheURL(for: urlString)
        if FileManager.default.fileExists(atPath: dest.path) {
            register(dest, urlString)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data else { finish(urlString, nil); return }
            do {
                try data.write(to: dest, options: .atomic)
                register(dest, urlString)
            } catch {
                finish(urlString, nil)
            }
        }.resume()
    }

    private static func register(_ fileURL: URL, _ urlString: String) {
        var errorRef: Unmanaged<CFError>?
        // Ignore "already registered" failures — the PostScript name lookup below is
        // what matters and works whether or not this specific call registered it.
        _ = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &errorRef)
        // Self-heal a corrupt/incomplete download: if the PostScript name can't be read the cached
        // file is unusable, so delete it — the next request re-downloads a fresh copy instead of
        // failing forever against the poisoned cache. Mirrors Android FontLoader.build().
        let name = postScriptName(of: fileURL)
        if name == nil { try? FileManager.default.removeItem(at: fileURL) }
        finish(urlString, name)
    }

    private static func postScriptName(of fileURL: URL) -> String? {
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor],
            let first = descriptors.first,
            let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
        else { return nil }
        return name
    }

    private static func finish(_ urlString: String, _ name: String?) {
        queue.async {
            inFlight.remove(urlString)
            if let name = name { registeredNames[urlString] = name }
        }
    }
}
