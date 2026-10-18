import Foundation

/**
 The comparison table's column headers, resolved from the two keys that can carry them.

 ## Why this is a function and not four lines in the view body

 It was four lines in the view body, and that is how it went wrong: a `some View` body cannot be
 called from a test, so the only available proof was a rendered pixel — and the header labels draw
 in `PaywallTextDefaults.readable(on:)`, a colour the author does not choose and the page is full
 of. The behaviour was unassertable, so it was never asserted, and the two platforms drifted.

 ## What it resolves, and in which order

 `table_columns` is the canonical key: an array of objects carrying `label` and `highlighted`. Only
 it can express a highlight, so it always wins when present and non-empty.

 `columns` is the fallback, and 🔴 **it arrives in two shapes**. An author or a template writes a
 plain array of labels — `["Free", "Premium"]` — while the structured object array is what the
 generator produces. iOS used to accept only the strings and Android only the objects
 (`PaywallConfig.kt`), so each platform drew nothing for the shape the other took. Measured on dev:
 2 of 2 comparison tables carry `columns` as a string array, one of them on an ACTIVE paywall, which
 Android was rendering with no headers at all. A table that does not say what it compares has lost
 the point of the section.

 A MIXED array is honoured element by element rather than refused. One element's spelling says
 nothing about the next, and a partial header row beats none — the alternative is a single
 hand-edited entry silently erasing every other column.

 An element that is neither a string nor an object is skipped, not defaulted to `""`: an empty
 header is indistinguishable from a column that exists and is unnamed, and the column count is what
 the data rows are laid out against.
 */
enum PaywallTableColumns {

    struct Resolved: Equatable {
        let labels: [String]
        let highlights: [Bool]
    }

    static func resolve(structured: [PaywallTableColumn]?, fallback: Any?) -> Resolved {
        if let structured, !structured.isEmpty {
            return Resolved(
                labels: structured.map { $0.label ?? "" },
                highlights: structured.map { $0.highlighted ?? false },
            )
        }
        guard let raw = fallback as? [Any] else { return Resolved(labels: [], highlights: []) }

        var labels: [String] = []
        var highlights: [Bool] = []
        for element in raw {
            if let text = element as? String {
                labels.append(text)
                highlights.append(false)
            } else if let object = element as? [String: Any] {
                labels.append(object["label"] as? String ?? "")
                highlights.append(object["highlighted"] as? Bool ?? false)
            }
            // else: skipped — see the note above on why this is not an empty label.
        }
        return Resolved(labels: labels, highlights: highlights)
    }
}
