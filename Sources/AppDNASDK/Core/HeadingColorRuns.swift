import Foundation

/// Whether a heading's text carries a `[word](color:HEX)` run, and so is drawn through the markdown
/// parser rather than as plain text. Pinned by the shared `heading_color_runs_and_justify` fixture.
///
/// Only a VALID run counts (6 or 8 hex digits), so a heading that merely contains brackets and the
/// word "color" draws exactly as it did before colour runs existed.
public enum HeadingColorRuns {
    public static func has(_ text: String) -> Bool {
        text.range(of: #"\[[^\]\n]+\]\(color:(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
