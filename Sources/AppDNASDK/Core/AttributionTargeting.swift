import Foundation

/**
 SPEC-542 P6b — audience rules on the install's attribution, on every surface that evaluates audience rules.

 An attribution rule is a trait-shaped condition whose key names the attribution instead of a trait:
 - `attribution.<field>`: a standard field — `network`, `channel`, `campaign`, `campaign_id`, `adset`, `adset_id`,
   `ad`, `ad_id`, `creative`, `keyword`, `placement`, `site_id`, `is_organic`, `attribution_type`,
   `install_country`, `mmp`;
 - `attribution.param.<key>`: any raw parameter the MMP delivered (`af_sub1`, `deep_link_value`, …).

 The value comes from the attribution the app handed the SDK, never from the trait map, so a trait called
 `attribution.network` cannot spoof it. With no attribution stored every attribution rule reads "no value", so `eq`,
 `in`, `contains` and `starts_with` fail closed and only `not_exists` matches. Text compares case-insensitively: MMPs
 disagree on case, and a rule must not depend on which one sent it. Mirrors Android `AttributionTargeting.kt`.
 */
internal enum AttributionTargeting {
    static let prefix = "attribution."
    private static let param = "param."

    /// Standard field → the payload keys that may carry it; the first non-blank wins. `source` is the host's spelling.
    private static let aliases: [String: [String]] = [
        "network": ["network", "source", "media_source"],
        "is_organic": ["is_organic", "isOrganic"],
        "mmp": ["mmp", "provider"],
    ]

    private static let lock = NSLock()
    private static var _payload: [String: Any]?

    /// The stored payload: standard fields at the top level, raw parameters under `raw`. Nil until one is set.
    static var payload: [String: Any]? {
        get { lock.lock(); defer { lock.unlock() }; return _payload }
        set { lock.lock(); _payload = newValue; lock.unlock() }
    }

    static func isAttributionKey(_ key: String?) -> Bool { key?.hasPrefix(prefix) ?? false }

    private static func present(_ v: Any?) -> Any? {
        guard let v, !(v is NSNull) else { return nil }
        if let s = v as? String, s.isEmpty { return nil }
        return v
    }

    /// The value an attribution rule reads, or nil when nothing was delivered for it.
    static func resolve(_ key: String) -> Any? {
        guard let p = payload else { return nil }
        let field = String(key.dropFirst(prefix.count))
        if field.hasPrefix(param) {
            guard let raw = p["raw"] as? [String: Any] else { return nil }
            return present(raw[String(field.dropFirst(param.count))])
        }
        for k in aliases[field] ?? [field] {
            if let v = present(p[k]) { return v }
        }
        return nil
    }

    /// Text folded for a case-insensitive comparison; a list folds element-wise; anything else is unchanged.
    static func fold(_ value: Any?) -> Any? {
        switch value {
        case let s as String: return s.lowercased()
        case let list as [Any]: return list.map { ($0 as? String)?.lowercased() ?? $0 }
        default: return value
        }
    }
}
