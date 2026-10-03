import Foundation

// MARK: - Audience targeting models for SPEC-089c (SDUI engine prerequisite)

public struct AudienceRule: Codable {
    /// The user-trait key. The console emits `field`; older payloads emit `trait`. Both decode here —
    /// a rule authored with `field` used to decode to `trait == nil`, which made `evaluateRule` return
    /// true unconditionally (every audience matched).
    public let trait: String?
    public let `operator`: String?  // "equals", "not_equals", "gt", "lt", "contains", "exists", "in", "not_in", "between"
    public let value: AnyCodable?
    /// List form used by `in` / `not_in`. The console emits `values` (plural); a rule authored that
    /// way used to leave `value` nil and the membership test always failed.
    public let values: [AnyCodable]?
    /// Bounds used by `between` (closed interval).
    public let min: AnyCodable?
    public let max: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case trait
        case `operator` = "operator"
        case value
        case values
        case min
        case max
    }

    /// Alias keys accepted on decode only — never emitted on encode.
    private enum AliasKeys: String, CodingKey {
        case field
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AliasKeys.self)
        let traitKey = try c.decodeIfPresent(String.self, forKey: .trait)
        let fieldKey = try aliases.decodeIfPresent(String.self, forKey: .field)
        // A blank `trait` defers to `field`, as on Android (`AudienceRule.fromMap`).
        self.trait = traitKey.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? fieldKey
        self.operator = try c.decodeIfPresent(String.self, forKey: .operator)
        self.value = try c.decodeIfPresent(AnyCodable.self, forKey: .value)
        self.values = try c.decodeIfPresent([AnyCodable].self, forKey: .values)
        self.min = try c.decodeIfPresent(AnyCodable.self, forKey: .min)
        self.max = try c.decodeIfPresent(AnyCodable.self, forKey: .max)
    }
}

public struct AudienceRuleSet: Codable {
    public let priority: Int?
    public let conditions: [AudienceRule]?
    public let match_mode: String?  // "all" or "any", default "all"
}

internal enum AudienceRuleEvaluator {

    static func evaluate(rules: AudienceRuleSet?, userTraits: [String: Any]) -> Bool {
        guard let rules = rules, let conditions = rules.conditions, !conditions.isEmpty else {
            return true  // No rules = pass
        }

        let matchAll = (rules.match_mode ?? "all") == "all"

        if matchAll {
            return conditions.allSatisfy { evaluateRule($0, userTraits: userTraits) }
        } else {
            return conditions.contains { evaluateRule($0, userTraits: userTraits) }
        }
    }

    /// Evaluate audience rules from AnyCodable (decoded from Firestore).
    ///
    /// The console persists `audience_rules` in TWO shapes: an object
    /// (`{ priority, match_mode, conditions: [...] }`) and a bare ARRAY of rules. Only the object
    /// shape used to be handled — an array fell through the `as? [String: Any]` cast and returned
    /// true, so every entity carrying array-shaped rules matched everyone.
    static func evaluate(rules anyCodable: AnyCodable?, traits: [String: Any]) -> Bool {
        guard let raw = anyCodable?.value else { return true }

        if let dict = raw as? [String: Any] {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let ruleSet = try? JSONDecoder().decode(AudienceRuleSet.self, from: jsonData) else {
                return true // Can't parse = pass
            }
            return evaluate(rules: ruleSet, userTraits: traits)
        }

        if let array = raw as? [Any] {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: array),
                  let ruleArray = try? JSONDecoder().decode([AudienceRule].self, from: jsonData) else {
                return true
            }
            return evaluate(ruleArray: ruleArray, userTraits: traits)
        }

        return true
    }

    /// Selection priority carried by a rule payload. Only the object shape carries one; the array
    /// shape has no place to put it, so it sorts as 0.
    static func priority(rules anyCodable: AnyCodable?) -> Int {
        ((anyCodable?.value as? [String: Any])?["priority"] as? Int) ?? 0
    }

    static func evaluate(ruleArray: [AudienceRule]?, userTraits: [String: Any]) -> Bool {
        guard let rules = ruleArray, !rules.isEmpty else { return true }
        return rules.allSatisfy { evaluateRule($0, userTraits: userTraits) }
    }

    private static func evaluateRule(_ rule: AudienceRule, userTraits: [String: Any]) -> Bool {
        guard let traitKey = rule.trait else { return true }
        let traitValue = userTraits[traitKey]

        switch rule.operator ?? "equals" {
        case "equals", "eq":
            return ConditionEvaluator.valuesEqual(traitValue, rule.value?.value)
        case "not_equals", "neq":
            return !ConditionEvaluator.valuesEqual(traitValue, rule.value?.value)
        case "gt":
            return ConditionEvaluator.compareNumeric(traitValue, rule.value?.value) == .orderedDescending
        case "gte":
            let cmp = ConditionEvaluator.compareNumeric(traitValue, rule.value?.value)
            return cmp == .orderedDescending || cmp == .orderedSame
        case "lt":
            return ConditionEvaluator.compareNumeric(traitValue, rule.value?.value) == .orderedAscending
        case "lte":
            let cmp = ConditionEvaluator.compareNumeric(traitValue, rule.value?.value)
            return cmp == .orderedAscending || cmp == .orderedSame
        case "contains":
            if let str = traitValue as? String, let search = rule.value?.value as? String {
                return str.lowercased().contains(search.lowercased())
            }
            if let arr = traitValue as? [String], let search = rule.value?.value as? String {
                return arr.contains(search)
            }
            return false
        case "exists":
            return traitValue != nil
        case "between":
            // Closed interval on a numeric trait. Previously unimplemented — it fell into
            // `default: return true`, so a between-rule passed VACUOUSLY for every user.
            guard let t = asDouble(traitValue) else { return false }
            var lower = asDouble(rule.min?.value)
            var upper = asDouble(rule.max?.value)
            // Round-31 — bounds may also arrive as a 2-element `value` list (matches Android
            // `betweenBounds`). Without this iOS ignored `{between, value:[18,65]}` entirely and
            // returned false where Android matched. min/max keys win when present.
            if lower == nil && upper == nil, let list = rule.value?.value as? [Any], list.count >= 2 {
                lower = asDouble(list[0])
                upper = asDouble(list[1])
            }
            guard lower != nil || upper != nil else { return false }
            if let lower, t < lower { return false }
            if let upper, t > upper { return false }
            return true
        case "in":
            // Membership is compared with the shared coercing equality: a console rule
            // `tier IN ["1","2"]` must match an Int trait `tier = 1`.
            let list = candidates(rule)
            guard !list.isEmpty else { return false }
            return list.contains { ConditionEvaluator.valuesEqual(traitValue, $0) }
        case "not_in":
            let list = candidates(rule)
            guard !list.isEmpty else { return true }
            return !list.contains { ConditionEvaluator.valuesEqual(traitValue, $0) }
        default:
            return true
        }
    }

    /// The membership list for `in` / `not_in`, from either `values` (plural, console) or a `value`
    /// that happens to hold an array (legacy payloads).
    private static func candidates(_ rule: AudienceRule) -> [Any] {
        if let values = rule.values, !values.isEmpty {
            return values.map(\.value)
        }
        if let arr = rule.value?.value as? [Any] {
            return arr
        }
        return []
    }

    private static func asDouble(_ value: Any?) -> Double? {
        ConditionEvaluator.toDouble(value)
    }
}
