import Foundation

/**
 The ONE format rule both platforms apply, written down once per platform and kept
 character-for-character identical.

 🔴 `URL(string:)` is NOT the rule, and that is the whole reason this type exists. Foundation
 accepts `"not a url"` as a relative URL and returns a non-nil value, so a check written the
 obvious way would have passed everything while looking strict. Android's `android.net.Uri.parse`
 is equally permissive. A deliberate pattern is the only way the two can agree on what a user
 typed being "a URL" means.

 The rule, in words, so the Kotlin twin can be read against it:

 - leading and trailing whitespace is ignored;
 - an `http://` or `https://` scheme is OPTIONAL and case-insensitive — an author collecting
   "your website" should not have to make everyone type the scheme;
 - then a host of at least two dot-separated labels, each of letters, digits or hyphens, with a
   final label of at least two letters, so `example` fails and `example.com` passes;
 - an optional `:port` of one to five digits;
 - an optional path, query or fragment, which may contain anything except whitespace.
 */
enum FormFieldFormats {
    /// The shared URL shape. Mirrored in Kotlin by `FormFieldFormats.looksLikeUrl`.
    static let urlPattern = "^(?i)(https?://)?([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}(:[0-9]{1,5})?([/?#][^\\s]*)?$"

    static func looksLikeURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return regex.firstMatch(in: trimmed, range: range) != nil
    }
}
