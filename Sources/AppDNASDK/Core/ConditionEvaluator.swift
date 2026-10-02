import Foundation

// MARK: - Shared condition evaluation utilities for SPEC-089c (SDUI engine prerequisite)
// Used by AudienceRuleEvaluator, UnifiedTriggerRules, and visibility conditions.

internal enum ConditionEvaluator {

    static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        guard let l = lhs, let r = rhs else { return false }

        if let ls = l as? String, let rs = r as? String { return ls == rs }
        if let ln = toDouble(l), let rn = toDouble(r) { return ln == rn }
        if let lb = l as? Bool, let rb = r as? Bool { return lb == rb }

        return "\(l)" == "\(r)"
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

    static func toDouble(_ value: Any?) -> Double? {
        guard let v = value else { return nil }
        if let n = v as? Double { return n }
        if let n = v as? Int { return Double(n) }
        if let n = v as? Float { return Double(n) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
