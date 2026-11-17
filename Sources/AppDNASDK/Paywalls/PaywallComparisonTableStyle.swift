import Foundation

/**
 What a `comparison_table` section draws with, resolved from its config and the page it sits on.

 The console offered header background and header / cell typography, but the renderer read none of the
 styling: it drew the header row on a fixed `#F9FAFB` while the header text followed the PAGE, so on a
 dark paywall the column headers were white on near-white. It also read `check_color` while the console
 had no control for it.

 This is the one place those keys are read. The renderer draws only what this returns, and the shared
 fixture `paywall_comparison_table_style` pins it here, in Android's `PaywallComparisonTableStyle` and in
 the console preview's `resolveComparisonTableStyle`.

 Defaults, when nothing is authored:
 - the header row is the page's readable ink at 6% (`headerBgHex == nil`), which tints a dark page and
   a light one alike;
 - header and cell text are the page's readable ink, and the feature names that ink at 70%;
 - a column's own `color` sets its header text and its check marks, then `header_text_color` and
   `check_color`;
 - the top-left header cell is EMPTY unless `feature_header` names it;
 - rows alternate only when `row_alt_bg_color` is set.
 */
enum PaywallComparisonTableStyle {

    struct Column: Equatable {
        let label: String
        let highlighted: Bool
        let headerTextHex: String
        let checkHex: String
    }

    struct Resolved: Equatable {
        let featureHeader: String
        /// nil = the page's readable ink at `defaultHeaderAlpha`.
        let headerBgHex: String?
        let headerTextHex: String
        let headerFontSize: Double
        let headerFontWeight: Int
        let cellTextHex: String
        /// The feature-name column's opacity: 0.7 unless `cell_text_color` is authored.
        let featureTextAlpha: Double
        let cellFontSize: Double
        let cellFontWeight: Int
        let rowAltBgHex: String?
        let crossHex: String
        let partialHex: String
        let borderHex: String
        /// nil = the brand accent.
        let highlightHex: String?
        let cornerRadius: Double
        let columns: [Column]
    }

    static let defaultHeaderAlpha: Double = 0.06
    static let defaultCheck = "#22C55E"
    static let defaultCross = "#D1D5DB"
    static let defaultBorder = "#E5E7EB"
    static let defaultPartial = "#FBBF24"

    /// What a cell value draws as: `check`, `cross`, `partial`, or `text` (the value itself).
    static func cellKind(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "check", "true", "yes", "y", "✓": return "check"
        case "cross", "false", "no", "n", "-", "✗", "✕": return "cross"
        case "partial", "~": return "partial"
        default: return "text"
        }
    }

    static func resolve(_ data: PaywallSectionData?, pageBackground: String?) -> Resolved {
        let ink = PaywallTextDefaults.readableHex(on: pageBackground)
        let headerText = nonEmpty(data?.headerTextColor) ?? ink
        let check = nonEmpty(data?.checkColor) ?? defaultCheck
        let cellText = nonEmpty(data?.cellTextColor)
        let resolvedColumns = PaywallTableColumns.resolve(structured: data?.tableColumns, fallback: data?.columns?.value)
        let colours: [String?] = (data?.tableColumns ?? []).map { nonEmpty($0.color) }
        let columns = resolvedColumns.labels.enumerated().map { i, label -> Column in
            let own = i < colours.count ? colours[i] : nil
            return Column(
                label: label,
                highlighted: i < resolvedColumns.highlights.count && resolvedColumns.highlights[i],
                headerTextHex: own ?? headerText,
                checkHex: own ?? check
            )
        }
        return Resolved(
            featureHeader: data?.featureHeader ?? "",
            headerBgHex: nonEmpty(data?.headerBgColor),
            headerTextHex: headerText,
            headerFontSize: Double(data?.headerFontSize ?? 12),
            headerFontWeight: paywallFontWeightValue(data?.headerFontWeight, default: 700),
            cellTextHex: cellText ?? ink,
            featureTextAlpha: cellText == nil ? 0.7 : 1,
            cellFontSize: Double(data?.cellFontSize ?? 12),
            cellFontWeight: paywallFontWeightValue(data?.cellFontWeight, default: 400),
            rowAltBgHex: nonEmpty(data?.rowAltBgColor),
            crossHex: nonEmpty(data?.crossColor) ?? defaultCross,
            partialHex: nonEmpty(data?.partialColor) ?? defaultPartial,
            borderHex: nonEmpty(data?.borderColor) ?? defaultBorder,
            highlightHex: nonEmpty(data?.highlightColor),
            cornerRadius: Double(data?.cornerRadius ?? data?.borderRadius ?? 12),
            columns: columns
        )
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }
}
