import Foundation

// MARK: - Shared condition evaluation utilities (SDUI engine prerequisite)
// Used by AudienceRuleEvaluator, UnifiedTriggerRules, and visibility conditions.

internal enum ConditionEvaluator {

    static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        guard let l = lhs, let r = rhs else { return false }

        if let ls = l as? String, let rs = r as? String { return ls == rs }
        if let lb = strictBool(l), let rb = strictBool(r) { return lb == rb }
        if let ln = toDouble(l), let rn = toDouble(r) { return ln == rn }

        return stringForm(l) == stringForm(r)
    }

    static func compareNumeric(_ lhs: Any?, _ rhs: Any?) -> ComparisonResult {
        guard let ln = toDouble(lhs), let rn = toDouble(rhs) else {
            return .orderedSame
        }
        if ln < rn { return .orderedAscending }
        if ln > rn { return .orderedDescending }
        return .orderedSame
    }

    static func evaluateCondition(
        type: String,
        variable: String?,
        value: Any?,
        context: [String: Any]
    ) -> Bool {
        let resolvedValue = resolveVariable(variable, context: context)

        switch type {
        case "always":
            return true
        case "when_equals":
            return valuesEqual(resolvedValue, value)
        case "when_not_equals":
            return !valuesEqual(resolvedValue, value)
        case "when_gt":
            return compareNumeric(resolvedValue, value) == .orderedDescending
        case "when_lt":
            return compareNumeric(resolvedValue, value) == .orderedAscending
        case "when_not_empty":
            if resolvedValue == nil { return false }
            if let s = resolvedValue as? String { return !s.isEmpty }
            return true
        case "when_empty":
            if resolvedValue == nil { return true }
            if let s = resolvedValue as? String { return s.isEmpty }
            return false
        default:
            return true
        }
    }

    static func resolveVariable(_ path: String?, context: [String: Any]) -> Any? {
        guard let path = path, !path.isEmpty else { return nil }
        let parts = path.split(separator: ".").map(String.init)

        var current: Any? = context
        for part in parts {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else {
                return nil
            }
        }
        return current
    }

    /// A number, or a string that spells one — never a Bool. Android `ConditionEvaluator.toDouble`, same rule: every
    /// integer width counts (an `Int64` / `UInt` trait used to read as "not a number" here while Android compared
    /// it), and a Bool is not a number (an `NSNumber` Bool — a trait restored from storage or passed by a wrapper —
    /// used to compare as 1 / 0 here and as no number on Android).
    static func toDouble(_ value: Any?) -> Double? {
        guard let v = value else { return nil }
        if let s = v as? String { return isDecimal(s) ? Double(s) : nil }
        if strictBool(v) != nil { return nil }
        switch v {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as Int64: return Double(n)
        case let n as Int32: return Double(n)
        case let n as Int16: return Double(n)
        case let n as Int8: return Double(n)
        case let n as UInt: return Double(n)
        case let n as UInt64: return Double(n)
        case let n as UInt32: return Double(n)
        case let n as UInt16: return Double(n)
        case let n as UInt8: return Double(n)
        case let n as Float: return Double("\(n)") ?? Double(n)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    /// Whether `s` spells a plain decimal number, in the one grammar both platforms share. `Double(_:)` alone also
    /// reads hex and "nan" / "inf", and Kotlin's parser reads "4d" and " 4 ", so a typed answer could equal a number on one
    /// platform only.
    private static func isDecimal(_ s: String) -> Bool {
        s.range(of: #"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// An answer or a rule value as text, for a substring comparison: a string as it is, a number in its shortest form
    /// (4.0 reads "4"), and nil for anything else (a Bool, a list). Android `ConditionEvaluator.text`.
    static func text(_ value: Any?) -> String? {
        guard let v = value else { return nil }
        if let s = v as? String { return s }
        guard strictBool(v) == nil, let d = toDouble(v) else { return nil }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    /// The value as a Bool only when it IS one: a Swift `Bool` or a CoreFoundation boolean `NSNumber` — not a number
    /// that happens to be 0 or 1 (Swift bridging would read `NSNumber(1)` as `true`).
    static func strictBool(_ value: Any?) -> Bool? {
        guard let v = value else { return nil }
        if let n = v as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : nil
        }
        return v as? Bool
    }

    /// The text form the last-resort equality compares — a Bool reads `true` / `false` whatever its storage (an
    /// `NSNumber` Bool would print `1`), like Android's `toString()`.
    private static func stringForm(_ value: Any) -> String {
        if let b = strictBool(value) { return b ? "true" : "false" }
        return "\(value)"
    }
}
