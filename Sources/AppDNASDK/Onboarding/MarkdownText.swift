import SwiftUI

/// Rich text as `rich_text` and an agreement's copy draw it: Foundation's markdown parser, inline syntax
/// only, one line at a time (`MarkdownLinks.parseLine`), links in `linkColor` and underlined.
///
/// This is the reference the other renderers follow: Android's `MarkdownInline` and the console preview
/// draw the same emphasis, code spans, escapes, links and images, so both views call this one function
/// and the shared fixture reads what it returns.
enum MarkdownText {

    /// - `textColor`: forced onto every run that is not a link (the markdown runs carry their own label
    ///   colour, which `Text` would otherwise keep over the view's `.foregroundColor`); nil keeps it.
    /// - `underlineMarkers`: `++text++` underlined, its markers removed (`rich_text`; an agreement's copy
    ///   does not draw them).
    @available(iOS 15.0, *)
    static func attributed(_ markdown: String, linkColor: Color, textColor: Color?, underlineMarkers: Bool) -> AttributedString {
        // `.inlineOnlyPreservingWhitespace` STOPS at the first paragraph break (\n\n), so multi-paragraph
        // content would draw only its first line: parse each line on its own and rejoin with newlines.
        let lines = markdown.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            if var parsed = MarkdownLinks.parseLine(line) {
                for run in parsed.runs {
                    if let link = run.link, let hex = colorRunHex(link.absoluteString) {
                        // `[word](color:EE6885)` colours a run; it is not a link.
                        parsed[run.range].link = nil
                        parsed[run.range].foregroundColor = UIColor(Color(hex: "#" + hex))
                    } else if run.link != nil {
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
        if underlineMarkers { applyUnderlineMarkers(&result) }
        return result
    }

    /// The hex of a `color:` run target, or nil when the target is an ordinary link.
    static func colorRunHex(_ target: String) -> String? {
        guard target.lowercased().hasPrefix("color:") else { return nil }
        let hex = String(target.dropFirst(6))
        let valid = (hex.count == 6 || hex.count == 8) && hex.allSatisfy(\.isHexDigit)
        return valid ? hex : nil
    }

    /// `++text++` in the drawn text: `.underlineStyle = .single` on the inner range and the `++` markers
    /// removed. Ranges are collected forward (each `++` paired with the next), then mutated back to front
    /// so earlier deletions do not invalidate later indices. `++` is not markdown, so the parser leaves the
    /// markers as characters and they can span anything it drew.
    @available(iOS 15.0, *)
    private static func applyUnderlineMarkers(_ attr: inout AttributedString) {
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
}
