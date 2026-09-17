import Foundation

/// SPEC-485 (#649) — inline `[label](url)` links in paywall **legal** text.
///
/// This lived as a `private func` on `PaywallRenderer`, so the OTHER legal renderer —
/// `LegalSectionView` in `Screens/Sections/PaywallSectionWrapperImpl.swift`, used when a paywall
/// section is embedded in a Screen module — could not reach it and rendered a plain `Text` instead.
/// A legal line reading "see our [Terms](https://…)" therefore showed the literal brackets on that
/// path while working on the other, and the console could neither author nor preview it.
///
/// Both iOS renderers now call this one function. Android has the mirror of exactly the same split
/// (`PaywallActivity` parsed links, `ModuleSectionWrappers` did not), fixed the same way.
func legalMarkdownLinks(_ text: String) -> AttributedString {
    let fallback = AttributedString(text)
    // Simple markdown link parser: [label](url)
    let pattern = "\\[([^\\]]+)\\]\\(([^)]+)\\)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return fallback }
    var attrStr = AttributedString()
    var remaining = text
    while let match = regex.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) {
        guard let labelRange = Range(match.range(at: 1), in: remaining),
              let urlRange = Range(match.range(at: 2), in: remaining),
              let fullRange = Range(match.range, in: remaining) else { break }
        // Text before the match
        attrStr.append(AttributedString(String(remaining[remaining.startIndex..<fullRange.lowerBound])))
        // The link itself
        var linkAttr = AttributedString(String(remaining[labelRange]))
        if let url = URL(string: String(remaining[urlRange])) {
            linkAttr.link = url
        }
        attrStr.append(linkAttr)
        remaining = String(remaining[fullRange.upperBound...])
    }
    if !remaining.isEmpty {
        attrStr.append(AttributedString(remaining))
    }
    return attrStr.characters.isEmpty ? fallback : attrStr
}
