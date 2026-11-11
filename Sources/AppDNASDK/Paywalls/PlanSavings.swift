import Foundation

/// A plan's savings claim, computed from the prices the paywall DRAWS.
///
/// A badge reading "save 52%" used to be literal text worked out from the AUTHORED prices. Once the
/// paywall began drawing the STORE's prices, the figure no longer matched the prices beside it —
/// it understated or overstated the saving depending on which way the store price moved, which is
/// the kind of pricing claim App Review and consumer-protection rules flag.
///
/// So a plan's `badge` or `savings_text` may carry the token `{{savings_percent}}`, filled here:
///
/// 1. Each plan's price PER MONTH — a store price over the store's ISO period, an authored price
///    over the period its own words name (`period`, label, price text, product id); each falls
///    back to the other.
/// 2. The anchor is the most expensive per-month plan in the same list; a plan's saving is
///    `1 − perMonth / anchor`, FLOORED to a whole percent, so the claim never rounds up.
/// 3. HIDDEN RATHER THAN WRONG: a text carrying the token is dropped whole when its saving cannot
///    be known — fewer than two comparable plans, an unreadable amount or period, a saving under
///    1%, or a list that mixes store and authored prices (two currencies cannot be compared).
/// 4. Text without the token is the author's own words and is drawn exactly as written.
///
/// Mirrors Android `PlanSavings.kt` and the console's `plan-savings.ts`. Pinned on all three by the
/// shared fixture `billing/plan_savings_percent`.
enum PlanSavings {

    static let token = "{{savings_percent}}"
    private static let tokenRegex = try? NSRegularExpression(pattern: #"\{\{\s*savings_percent\s*\}\}"#)

    static func hasToken(_ text: String?) -> Bool {
        guard let text, let re = tokenRegex else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The text to draw, or nil to draw nothing. Without the token, untouched; with it, a percent
    /// is required and its absence hides the WHOLE text.
    static func fill(_ text: String?, percent: Int?) -> String? {
        guard let text else { return nil }
        guard hasToken(text), let re = tokenRegex else { return text }
        guard let percent else { return nil }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: "\(percent)%")
        )
    }

    /// The number in an authored price string: "$39.99", "39,99 €", "1.299,00 kr", "¥1,200".
    static func parseAmount(_ text: String?) -> Double? {
        guard let text,
              let re = try? NSRegularExpression(pattern: "\\d(?:[\\d.,'\u{00A0}\u{202F} ]*\\d)?"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        var t = String(text[r]).filter { !["'", "\u{00A0}", "\u{202F}", " "].contains($0) }
        let lastDot = t.lastIndex(of: ".")
        let lastComma = t.lastIndex(of: ",")
        if let d = lastDot, let c = lastComma {
            let dec: Character = d > c ? "." : ","
            let group: Character = dec == "." ? "," : "."
            t.removeAll { $0 == group }
            t = t.replacingOccurrences(of: String(dec), with: ".")
        } else if let sepIdx = lastDot ?? lastComma {
            let sep = t[sepIdx]
            let count = t.filter { $0 == sep }.count
            let after = t.distance(from: sepIdx, to: t.endIndex) - 1
            if count == 1 && after != 3 {
                t = t.replacingOccurrences(of: String(sep), with: ".")
            } else {
                t.removeAll { $0 == sep }
            }
        }
        return Double(t)
    }

    /// Months in an ISO-8601 billing period (`P1M`, `P1Y`, `P1W`, `P7D`).
    static func months(iso: String?) -> Double? {
        guard let iso = iso?.trimmingCharacters(in: .whitespaces).uppercased(),
              iso.hasPrefix("P"), let unit = iso.last, iso.count >= 3,
              let n = Int(iso.dropFirst().dropLast()), n > 0 else { return nil }
        let v = Double(n)
        switch unit {
        case "Y": return 12 * v
        case "M": return v
        case "W": return (12.0 / 52.0) * v
        case "D": return n % 7 == 0 ? (12.0 / 52.0) * (v / 7) : (12.0 / 365.0) * v
        default: return nil
        }
    }

    /// Months a plan's own WORDS name.
    static func months(words parts: [String?]) -> Double? {
        var words = " " + parts.compactMap { $0 }.joined(separator: " ").lowercased() + " "
        for ch in ["_", ".", "-", "/"] { words = words.replacingOccurrences(of: ch, with: " ") }
        func has(_ pattern: String) -> Bool { words.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\b12 ?months?\b"#) { return 12 }
        if has(#"\b(year|years|yearly|annual|annually|yr|yrs)\b"#) { return 12 }
        if has(#"\b(6 ?months?|semi ?annual|semiannual|biannual|half ?year)\b"#) { return 6 }
        if has(#"\b(quarter|quarterly|3 ?months?)\b"#) { return 3 }
        if has(#"\b(week|weeks|weekly|wk)\b"#) { return 12.0 / 52.0 }
        if has(#"\b(month|monthly|mo)\b"#) { return 1 }
        return nil
    }

    /// Each plan's saving as a whole percent, or nil where it cannot be known.
    static func percents(_ plans: [PaywallPlan]) -> [Int?] {
        let rows: [(perMonth: Double?, store: Bool)] = plans.map { p in
            let store = p.priceSource == StorePriceSubstitution.Source.store.rawValue
            let authored = p.price_display ?? p.price
            let words = months(words: [p.period, p.label ?? p.name, authored, p.productId])
            let amount = store ? p.resolvedStoreAmount : parseAmount(authored)
            let m = store ? (months(iso: p.resolvedStorePeriod) ?? words) : (words ?? months(iso: p.resolvedStorePeriod))
            guard let amount, amount > 0, let m, m > 0 else { return (nil, store) }
            return (amount / m, store)
        }
        let known = rows.filter { $0.perMonth != nil }
        guard known.count >= 2, Set(known.map { $0.store }).count == 1,
              let anchor = known.compactMap({ $0.perMonth }).max() else { return plans.map { _ in nil } }
        return rows.map { row in
            guard let v = row.perMonth else { return nil }
            let pct = Int(((1 - v / anchor) * 100 + 1e-6).rounded(.down))
            return pct >= 1 ? pct : nil
        }
    }

    /// The plan list with every token filled, and every text whose figure cannot be known removed.
    static func apply(_ plans: [PaywallPlan]) -> [PaywallPlan] {
        guard plans.contains(where: { hasToken($0.badge) || hasToken($0.savings_text) }) else { return plans }
        let pct = percents(plans)
        return plans.enumerated().map { i, plan in
            var copy = plan
            copy.resolvedSavingsPercent = pct[i]
            copy.badge = fill(plan.badge, percent: pct[i])
            copy.savings_text = fill(plan.savings_text, percent: pct[i])
            return copy
        }
    }
}
