import Foundation

/**
 audience rules on the install's attribution, on every surface that evaluates audience rules.

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
    private static var loaded = false
    private static var waiters: [UUID: (Bool) -> Void] = [:]

    /// Where the payload survives a relaunch. A seam so tests use their own suite.
    static var defaults: UserDefaults = .standard
    static let storageKey = "ai.appdna.attribution.payload"
    /// Set once a first-launch wait ran out with nothing delivered, so later launches do not wait again.
    static let waitSpentKey = "ai.appdna.attribution.wait_spent"

    /// The stored payload: standard fields at the top level, raw parameters under `raw`. Nil until one is set.
    /// The first read loads what an earlier launch stored. Setting it is memory-only (the fixtures use it);
    /// `store(_:)` is the host path.
    static var payload: [String: Any]? {
        get {
            lock.lock(); defer { lock.unlock() }
            if !loaded {
                loaded = true
                if _payload == nil, let data = defaults.data(forKey: storageKey),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    _payload = obj
                }
            }
            return _payload
        }
        set { lock.lock(); _payload = newValue; loaded = true; lock.unlock() }
    }

    /// The standard fields, in their stored (snake_case) spelling. A host may also pass the camelCase spelling.
    static let standardFields = [
        "network", "channel", "campaign", "campaign_id", "adset", "adset_id", "ad", "ad_id", "creative", "keyword",
        "placement", "site_id", "is_organic", "attribution_type", "install_country", "mmp",
    ]
    private static let maxRawKeys = 200
    private static let maxValueLength = 1000

    private static func camel(_ snake: String) -> String {
        let parts = snake.split(separator: "_")
        return parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }

    /// A JSON scalar as stored: text (trimmed, capped, blank → nil), a finite number, or a bool. Anything else is nil.
    private static func scalar(_ v: Any?) -> Any? {
        guard let v, !(v is NSNull) else { return nil }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(maxValueLength))
        }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.doubleValue.isFinite ? n : nil
        }
        return nil
    }

    /// `is_organic` from a bool, a 0 / 1 number, or "true" / "false" text (any case); anything else is nil.
    private static func organic(_ v: Any?) -> Bool? {
        switch scalar(v) {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue == 1 ? true : (n.intValue == 0 ? false : nil)
        case let s as String:
            switch s.lowercased() { case "true", "1", "yes": return true; case "false", "0", "no": return false; default: return nil }
        default: return nil
        }
    }

    /**
     What `setAttribution` stores, from what the host passed (shared fixture `audience_eval/set_attribution_*`):
     - each standard field under its snake_case name, read from that name, its camelCase spelling or an alias
       (`source` / `media_source` → `network`, `provider` → `mmp`); text and numbers are kept as text, blank is absent;
     - `is_organic` as a bool (from a bool, 0 / 1 or "true" / "false");
     - `raw`: the host's `raw` map plus every top-level key that is not a standard field or an alias, JSON scalars
       only (nested values dropped), at most 200 keys.
     */
    static func normalize(_ input: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        var consumed = Set<String>(["raw"])
        for field in standardFields {
            var keys = [field, camel(field)]
            keys += aliases[field] ?? []
            for k in keys { consumed.insert(k) }
            for k in keys {
                guard let v = input[k] else { continue }
                if field == "is_organic" {
                    if let b = organic(v) { out[field] = b; break }
                } else if let s = scalar(v), !(s is Bool) {
                    out[field] = (s as? String) ?? "\(s)"
                    break
                }
            }
        }
        var raw: [String: Any] = [:]
        let explicit = input["raw"] as? [String: Any] ?? [:]
        for (k, v) in explicit.sorted(by: { $0.key < $1.key }) where raw.count < maxRawKeys {
            if let s = scalar(v) { raw[k] = s }
        }
        for (k, v) in input.sorted(by: { $0.key < $1.key }) where !consumed.contains(k) && raw[k] == nil && raw.count < maxRawKeys {
            if let s = scalar(v) { raw[k] = s }
        }
        out["raw"] = raw
        return out
    }

    /// The host path: normalise, keep in memory, persist for the next launch, and release every `waitForAttribution`
    /// waiter with `true`. Returns the stored payload (the `attribution_set` event's properties).
    @discardableResult
    static func store(_ input: [String: Any]) -> [String: Any] {
        let normalized = normalize(input)
        lock.lock()
        _payload = normalized
        loaded = true
        let released = waiters
        waiters = [:]
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: normalized) { defaults.set(data, forKey: storageKey) }
        for w in released.values { w(true) }
        return normalized
    }

    /**
     Calls back `true` as soon as attribution is stored (at once when an earlier call or launch stored it), or `false`
     after `timeoutMs` when none arrived. A wait that runs out is remembered, so a later launch with still nothing
     stored answers `false` at once: an organic install whose MMP never calls back waits on its first launch only.
     `timeoutMs <= 0` answers at once.
     */
    static func whenReady(timeoutMs: Int, schedule: (Int, @escaping () -> Void) -> Void, _ completion: @escaping (Bool) -> Void) {
        if payload != nil { completion(true); return }
        if timeoutMs <= 0 || defaults.bool(forKey: waitSpentKey) { completion(false); return }
        let id = UUID()
        lock.lock()
        if _payload != nil { lock.unlock(); completion(true); return }
        waiters[id] = completion
        lock.unlock()
        schedule(timeoutMs) {
            lock.lock()
            let w = waiters.removeValue(forKey: id)
            lock.unlock()
            guard let w else { return }
            defaults.set(true, forKey: waitSpentKey)
            w(false)
        }
    }

    /// Test seam: a relaunch — memory is gone, storage is kept, the next read loads it.
    static func relaunchForTesting() {
        lock.lock(); _payload = nil; loaded = false; waiters = [:]; lock.unlock()
    }

    /// Test seam: forget memory and the persisted copy.
    static func resetForTesting() {
        lock.lock(); _payload = nil; loaded = false; waiters = [:]; lock.unlock()
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: waitSpentKey)
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
