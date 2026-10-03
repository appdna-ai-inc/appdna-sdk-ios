import Foundation

// The RAW host-data pass, iOS.
//
// A LINE-FOR-LINE PORT of the console's reference resolver `src/lib/onboarding/host-data-resolve.ts`:
// same rules, same order, same unresolved-token behaviour. The shared `resolve_block` fixtures run
// through this file on iOS, through `host-data-resolve.ts` on the console and through
// `HostDataResolver.kt` on Android, so the three cannot drift. When one changes, all three change.
//
// The pass, in order:
//
//   deep copy + id stamping → skip rule → bindings (every block depth; allowlist by generated key
//   class) → strip authored markers → repeat expansion (top-level `input_select` only) → ONE
//   structural pass (inline tokens + `data_templates`, every string at every depth, excluded keys
//   skipped, binding-written keys skipped, substituted values never re-scanned) → option drop / hide /
//   dedupe → summary-stat placeholder rules → markers (`resolve_state`, `empty_state`,
//   `sheet_step_paths`) → the block's `block.<id>.*` localizations.
//
// Unlike the console, a token whose root is NOT a block root (`device`, `computed`, `remote_config`,
// `input`, bare names) is resolved per token through TemplateEngine's existing variable resolver
// `loc()` is lookup-only for raw-resolved blocks, so nothing else would resolve it.
//
// Key classes come from the GENERATED `BlockKeyTypes` (scripts/check-template-reach.ts) — never a
// hand-kept list.

// MARK: - Context / result

/// Everything one resolve reads. Roots are JSON (`HostJSON`) so the pass never guesses a type.
struct HostDataContext {
    /// Step id + top-level index drive id stamping ("Stable ids").
    var stepId: String = "fixture_step"
    var blockIndex: Int = 0
    var hookData: HostJSON? = nil
    var responses: HostJSON? = nil
    /// The current step's live input values (`{{step.<field_id>}}`).
    var step: HostJSON? = nil
    var user: HostJSON? = nil
    var session: HostJSON? = nil
    /// `SelectedOptionStore` snapshot (`{{selected.<field_id>.label}}`).
    var selected: HostJSON? = nil
    /// "Host data pending".
    var pending: Bool = false
    var localizations: [String: [String: String]]? = nil
    /// TemplateEngine's per-token resolver for non-block roots: `(path, fallback) -> String`.
    /// Nil keeps the token as authored (what the console does).
    var legacyResolve: ((_ path: String, _ fallback: String?) -> String)? = nil
}

struct HostDataResolveResult {
    /// The resolved block JSON — what the typed decoder receives.
    var block: HostJSON
    /// This block's (and descendants') `block.<id>.*` entries after the pass. Nil without localizations.
    var localizations: [String: [String: String]]?
    /// True when the skip rule applied (the block is the stamped raw block, untouched).
    var skipped: Bool
    var log: [String]
    /// iOS-only extras for the per-key decode revert: the block after bindings + marker strip +
    /// expansion (BEFORE the structural pass), the stamped authored block, and the top-level keys a
    /// binding wrote (those revert to their AUTHORED value).
    var postExpansion: HostJSON
    var stampedAuthored: HostJSON
    var boundTopLevelKeys: Set<String>
}

// MARK: - Mutable reference tree (the TS pass mutates objects and keys its bookkeeping by identity)

final class HDObj {
    var d: [String: HDVal]
    init(_ d: [String: HDVal] = [:]) { self.d = d }
    /// Keys in a stable order (the TS pass iterates insertion order; nothing it does depends on it).
    var sortedKeys: [String] { d.keys.sorted() }
}

indirect enum HDVal {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case arr([HDVal])
    case obj(HDObj)

    init(_ h: HostJSON) {
        switch h {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .array(let a): self = .arr(a.map { HDVal($0) })
        case .object(let o): self = .obj(HDObj(o.mapValues { HDVal($0) }))
        }
    }

    var host: HostJSON {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .arr(let a): return .array(a.map { $0.host })
        case .obj(let o): return .object(o.d.mapValues { $0.host })
        }
    }

    var obj: HDObj? { if case .obj(let o) = self { return o }; return nil }
    var arr: [HDVal]? { if case .arr(let a) = self { return a }; return nil }
    var str: String? { if case .string(let s) = self { return s }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    /// Deep copy (fresh objects).
    var cloned: HDVal { HDVal(host) }
}

/// Identity-keyed side table (the TS WeakMaps). Holds the object strongly so an identifier is never
/// reused by a later allocation while the pass runs.
struct HDIdentityMap<V> {
    private var storage: [ObjectIdentifier: (HDObj, V)] = [:]
    subscript(_ o: HDObj) -> V? {
        get { storage[ObjectIdentifier(o)]?.1 }
        set {
            if let nv = newValue { storage[ObjectIdentifier(o)] = (o, nv) }
            else { storage[ObjectIdentifier(o)] = nil }
        }
    }
    func has(_ o: HDObj) -> Bool { storage[ObjectIdentifier(o)] != nil }
}

// MARK: - Resolver

enum HostDataResolver {

    // The roots the block resolver owns. `item` / `index` exist only inside a repeat template.
    static let blockRoots: Set<String> = ["responses", "hook_data", "step", "selected", "user", "session", "item", "index"]
    static let excluded: Set<String> = BlockKeyTypes.excludedKeys
    static let markers: Set<String> = BlockKeyTypes.internalMarkers
    /// The only key classes a `bindings` entry may target.
    static let bindableClasses: Set<String> = ["string", "number", "bool", "string_list"]
    /// Option-bearing inputs ("Select").
    static let optionBearingTypes: Set<String> = ["input_select", "input_chips", "input_segmented"]
    /// Keys whose array elements are content blocks.
    static let blockListKeys: [String] = ["children", "stack_children"]
    static let repeatDefaultMax = 20
    static let repeatHardMax = 50

    /// Identical to iOS `resolveTemplateString` / Android / TS (hyphenated ids, `| fallback`).
    static let tokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\{\{\s*([a-zA-Z0-9_.\-]+)\s*(?:\|\s*([^}]*?)\s*)?\}\}"#)
    }()

    // MARK: Small helpers

    static func isUrlKey(_ key: String) -> Bool { key.hasSuffix("_url") }

    struct Token {
        let raw: String
        let path: String
        let root: String
        let fallback: String?
        /// UTF-16 offset / length (JS string indices).
        let index: Int
        let length: Int
    }

    static func extractTokens(_ text: String) -> [Token] {
        let ns = text as NSString
        return tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let path = ns.substring(with: m.range(at: 1))
            let fbRange = m.range(at: 2)
            return Token(
                raw: ns.substring(with: m.range),
                path: path,
                root: path.components(separatedBy: ".").first ?? "",
                fallback: fbRange.location == NSNotFound ? nil : ns.substring(with: fbRange),
                index: m.range.location,
                length: m.range.length
            )
        }
    }

    /// "Stringification" — strings as-is; `true`/`false`; integral numbers below 2^53 without a
    /// decimal part; every other number in plain decimal notation (never exponent form) with at most
    /// 15 significant digits and trailing zeros trimmed. `null`, objects, arrays → nil (= unresolved).
    static func stringify(_ v: HDVal?) -> String? {
        guard let v else { return nil }
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i):
            if abs(Double(i)) < 9_007_199_254_740_992 { return String(i) }
            return formatNumber(Double(i))
        case .double(let d): return formatNumber(d)
        default: return nil
        }
    }

    static func stringify(_ h: HostJSON?) -> String? { h.flatMap { stringify(HDVal($0)) } }

    static func formatNumber(_ n: Double) -> String? {
        guard n.isFinite else { return nil }
        if n == 0 { return "0" }
        if n == n.rounded(.towardZero) && abs(n) < 9_007_199_254_740_992 { return String(Int64(n)) }
        let neg = n < 0
        // JS `toPrecision(15)` in exponent form: d.dddddddddddddde±X.
        let precise = String(format: "%.14e", abs(n))
        let parts = precise.components(separatedBy: "e")
        let mant = parts[0]
        let exp = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let mParts = mant.components(separatedBy: ".")
        let intPart = mParts[0]
        let frac = mParts.count > 1 ? mParts[1] : ""
        let digits = intPart + frac
        let point = intPart.count + exp
        var s: String
        if point <= 0 {
            s = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            s = digits + String(repeating: "0", count: point - digits.count)
        } else {
            let idx = digits.index(digits.startIndex, offsetBy: point)
            s = String(digits[..<idx]) + "." + String(digits[idx...])
        }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        // Strip leading zeros before a digit.
        while s.count > 1, s.hasPrefix("0"), let second = s.dropFirst().first, second.isNumber {
            s.removeFirst()
        }
        if s.isEmpty { s = "0" }
        return neg && s != "0" ? "-" + s : s
    }

    // `\z`, not `$`: ICU's `$` also matches before a FINAL line terminator, which let
    // "https://cdn.x.com/w.png\n" pass (TS and Kotlin's whole-input match reject it).
    // NO `.caseInsensitive`: ICU folds Unicode case, so `ſ` (U+017F) matched `s` and `K` (U+212A)
    // matched `k` — "https://ſtatic.com" passed here while TS (`/i` without `u`) rejected it. The
    // character classes already list both ASCII cases; the scheme spells them out.
    private static let urlRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^[Hh][Tt][Tt][Pp][Ss]://[A-Za-z0-9\-._~%!$&'()*+,;=:@\[\]]+(?:[/?#][A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*)?\z"#,
            options: []
        )
    }()

    /// A template-resolved URL must be an absolute `https` URL (pinned, all three implementations).
    static func isValidTemplatedUrl(_ s: String) -> Bool {
        let ns = s as NSString
        return urlRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static let pathSafe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@".unicodeScalars)
    private static let querySafe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$'()*,;:@/?".unicodeScalars)

    /// Percent-encode a value substituted INSIDE a longer URL (UTF-8, upper-case hex).
    static func percentEncode(_ value: String, query: Bool) -> String {
        let safe = query ? querySafe : pathSafe
        var out = ""
        for scalar in value.unicodeScalars {
            if safe.contains(scalar) { out.unicodeScalars.append(scalar); continue }
            for b in String(scalar).utf8 { out += String(format: "%%%02X", b) }
        }
        return out
    }

    // MARK: Scope

    struct Scope {
        var roots: [String: HDVal]
        var item: (value: HDVal, index: Int)?
    }

    static func rootScope(_ ctx: HostDataContext) -> Scope {
        var roots: [String: HDVal] = [:]
        if let v = ctx.responses { roots["responses"] = HDVal(v) }
        if let v = ctx.hookData { roots["hook_data"] = HDVal(v) }
        if let v = ctx.step { roots["step"] = HDVal(v) }
        if let v = ctx.selected { roots["selected"] = HDVal(v) }
        if let v = ctx.user { roots["user"] = HDVal(v) }
        if let v = ctx.session { roots["session"] = HDVal(v) }
        return Scope(roots: roots, item: nil)
    }

    /// Any depth, numeric array index, miss → nil. Two or more segments are required except
    /// for exactly `item` and `index`.
    static func resolveScopePath(_ path: String, _ scope: Scope) -> HDVal? {
        let parts = path.components(separatedBy: ".")
        let root = parts[0]
        var current: HDVal
        if root == "item" {
            guard let item = scope.item else { return nil }
            current = item.value
        } else if root == "index" {
            guard let item = scope.item, parts.count == 1 else { return nil }
            return .int(Int64(item.index))
        } else {
            guard parts.count >= 2, blockRoots.contains(root), let r = scope.roots[root] else { return nil }
            current = r
        }
        for part in parts.dropFirst() {
            if let o = current.obj, let next = o.d[part] {
                current = next
            } else if let a = current.arr, !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let i = Int(part), i < a.count {
                current = a[i]
            } else {
                return nil
            }
        }
        return current.isNull ? nil : current
    }

    // MARK: String resolution

    struct StringResult {
        var value: String
        var hadToken: Bool
        var unresolved = false
        var unresolvedHookData = false
        var deferredStep = false
    }

    static func resolveString(
        _ text: String, scope: Scope, url: Bool, deferStep: Bool,
        legacy: ((String, String?) -> String)?
    ) -> StringResult {
        let tokens = extractTokens(text)
        var res = StringResult(value: text, hadToken: !tokens.isEmpty)
        if tokens.isEmpty { return res }
        let ns = text as NSString
        let whole = tokens.count == 1 && tokens[0].raw == text
        let q = ns.range(of: "?").location
        let firstQuery = q == NSNotFound ? -1 : q
        var out = ""
        var last = 0
        for t in tokens {
            out += ns.substring(with: NSRange(location: last, length: t.index - last))
            last = t.index + t.length
            if deferStep && t.root == "step" { out += t.raw; res.deferredStep = true; continue }
            if !blockRoots.contains(t.root) {
                // TemplateEngine roots, per token, same semantics as today.
                out += legacy?(t.path, t.fallback) ?? t.raw
                continue
            }
            if let s = stringify(resolveScopePath(t.path, scope)) {
                let encode = url && !whole
                out += encode ? percentEncode(s, query: firstQuery >= 0 && firstQuery < t.index) : s
            } else if let fb = t.fallback {
                out += fb
            } else {
                res.unresolved = true
                if t.root == "hook_data" { res.unresolvedHookData = true }
            }
        }
        out += ns.substring(from: last)
        res.value = out
        return res
    }

    // MARK: Block tree walking / id stamping / skip rule

    /// Visit every block object (the block, children, stack_children, option sheet_blocks).
    static func forEachBlock(_ block: HDObj, _ path: String, inSheet: Bool = false, _ visit: (HDObj, String, Bool) -> Void) {
        visit(block, path, inSheet)
        for key in blockListKeys {
            guard let list = block.d[key]?.arr else { continue }
            for (j, child) in list.enumerated() {
                if let c = child.obj { forEachBlock(c, "\(path)/\(key)/\(j)", inSheet: inSheet, visit) }
            }
        }
        if let opts = block.d["field_options"]?.arr {
            for (k, opt) in opts.enumerated() {
                guard let o = opt.obj, let sheet = o.d["sheet_blocks"]?.arr else { continue }
                for (m, sb) in sheet.enumerated() {
                    if let s = sb.obj { forEachBlock(s, "\(path)/field_options/\(k)/sheet_blocks/\(m)", inSheet: true, visit) }
                }
            }
        }
    }

    /// "Stable ids" — stamp every id-less block at any depth with `<stepId>/<index path>`.
    static func stampBlockIds(_ raw: HostJSON, stepId: String, blockIndex: Int) -> HostJSON {
        let copy = HDVal(raw)
        guard let root = copy.obj else { return raw }
        stamp(root, stepId: stepId, blockIndex: blockIndex)
        return copy.host
    }

    fileprivate static func stamp(_ root: HDObj, stepId: String, blockIndex: Int) {
        forEachBlock(root, "\(stepId)/\(blockIndex)") { b, path, _ in
            if b.d["id"] == nil || b.d["id"]!.isNull { b.d["id"] = .string(path) }
        }
    }

    /// Every block id in the tree, in traversal order, with its object.
    static func blockIndexOf(_ block: HDObj) -> [(id: String, obj: HDObj)] {
        var out: [(id: String, obj: HDObj)] = []
        forEachBlock(block, "") { b, _, _ in
            guard let id = b.d["id"]?.str else { return }
            if let i = out.firstIndex(where: { $0.id == id }) { out[i].obj = b } else { out.append((id, b)) }
        }
        return out
    }

    static func locKeysOf(_ localizations: [String: [String: String]]?, _ ids: [String]) -> [(locale: String, key: String, id: String)] {
        var out: [(locale: String, key: String, id: String)] = []
        guard let localizations else { return out }
        for locale in localizations.keys.sorted() {
            guard let map = localizations[locale] else { continue }
            for key in map.keys.sorted() {
                if let id = ids.first(where: { key.hasPrefix("block.\($0).") }) { out.append((locale, key, id)) }
            }
        }
        return out
    }

    private static func containsSkipMarker(_ v: HDVal) -> Bool {
        switch v {
        case .string(let s): return s.contains("{{") || s.contains("data_templates") || s.contains("bindings") || s.contains("repeat")
        case .arr(let a): return a.contains { containsSkipMarker($0) }
        case .obj(let o):
            for (k, e) in o.d {
                if k.contains("{{") || k.contains("data_templates") || k.contains("bindings") || k.contains("repeat") { return true }
                if containsSkipMarker(e) { return true }
            }
            return false
        default: return false
        }
    }

    /// "Skip rule (the only one)".
    static func blockSkipsRawPass(_ stamped: HDObj, _ localizations: [String: [String: String]]?) -> Bool {
        if containsSkipMarker(.obj(stamped)) { return false }
        let ids = blockIndexOf(stamped).map(\.id)
        for (locale, key, _) in locKeysOf(localizations, ids) {
            if localizations?[locale]?[key]?.contains("{{") == true { return false }
        }
        return true
    }

    // MARK: Owners

    enum Owner {
        case type(String)
        case fieldConfig(blockType: String, prefix: String)
        case unknown
    }

    static func classOf(_ owner: Owner, _ key: String) -> String? {
        switch owner {
        case .type(let n): return BlockKeyTypes.ownerKeyClasses[n]?[key]
        case .fieldConfig(let bt, let prefix):
            return BlockKeyTypes.fieldConfigKeyClasses[bt]?[prefix + key] ?? BlockKeyTypes.fieldConfigKeyClasses["*"]?[prefix + key]
        case .unknown: return nil
        }
    }

    static func childOwnerOf(_ owner: Owner, _ key: String) -> Owner {
        switch owner {
        case .type(let n):
            if let t = BlockKeyTypes.ownerKeyChildTypes[n]?[key] { return .type(t) }
            return .unknown
        case .fieldConfig(let bt, let prefix): return .fieldConfig(blockType: bt, prefix: "\(prefix)\(key)[].")
        case .unknown: return .unknown
        }
    }

    // MARK: Pending / hook_data reference analysis

    static func hasRootToken(_ s: String?, _ root: String, requireNoFallback: Bool = false) -> Bool {
        guard let s else { return false }
        return extractTokens(s).contains { $0.root == root && (!requireNoFallback || $0.fallback == nil) }
    }

    static func firstSegment(_ s: String) -> String { s.components(separatedBy: ".").first ?? "" }

    /// "resolve_state: pending" — can a `hook_data` reference change WHICH options exist or their
    /// STORED ANSWER? Media-only references never count.
    static func optionsDependOnHookData(_ block: HDObj) -> Bool {
        guard let type = block.d["type"]?.str, optionBearingTypes.contains(type) else { return false }
        if let fc = block.d["field_config"]?.obj, let rep = fc.d["repeat"]?.obj,
           let src = rep.d["source"]?.str, firstSegment(src) == "hook_data" { return true }
        for o in block.d["field_options"]?.arr ?? [] {
            guard let opt = o.obj else { continue }
            if hasRootToken(opt.d["label"]?.str, "hook_data", requireNoFallback: true) { return true }
            if hasRootToken(opt.d["value"]?.str, "hook_data") { return true }
            if let dt = opt.d["data_templates"]?.obj, hasRootToken(dt.d["value"]?.str, "hook_data") { return true }
        }
        return false
    }

    /// "Applies" — does this step's raw content reference `hook_data` at all?
    static func stepReferencesHookData(_ blocks: [HostJSON], localizations: [String: [String: String]]?) -> Bool {
        func scan(_ v: HostJSON, _ key: String?) -> Bool {
            switch v {
            case .string(let s):
                return hasRootToken(s, "hook_data") || ((key == "source" || key == "bindingPath") && firstSegment(s) == "hook_data")
            case .array(let a): return a.contains { scan($0, nil) }
            case .object(let o):
                return o.contains { k, e in
                    if k == "bindings", case .object(let b) = e {
                        return b.values.contains { if case .string(let p) = $0 { return firstSegment(p) == "hook_data" }; return false }
                    }
                    if k == "repeat", case .object(let r) = e {
                        if case .string(let src)? = r["source"] { return firstSegment(src) == "hook_data" }
                        return false
                    }
                    return scan(e, k)
                }
            default: return false
            }
        }
        if blocks.contains(where: { scan($0, nil) }) { return true }
        for map in (localizations ?? [:]).values {
            for (k, v) in map where k.hasPrefix("block.") && hasRootToken(v, "hook_data") { return true }
        }
        return false
    }

    /// "cached" — the TOP-LEVEL `hook_data` keys the step references: the first path
    /// segment after `hook_data` of every reference `stepReferencesHookData` counts (tokens,
    /// `data_templates`, `repeat.source`, `hook_data` bindings, `block.<id>.*` localizations). A bare
    /// `hook_data` reference (no key) is recorded as `"*"`, which any key satisfies.
    static func stepHookDataKeys(_ blocks: [HostJSON], localizations: [String: [String: String]]?) -> Set<String> {
        var keys = Set<String>()
        func addPath(_ p: String) {
            let segs = p.components(separatedBy: ".")
            guard segs.first == "hook_data" else { return }
            keys.insert(segs.count > 1 && !segs[1].isEmpty ? segs[1] : "*")
        }
        func addTokens(_ s: String) {
            guard s.contains("{{") else { return }
            for t in extractTokens(s) where t.root == "hook_data" { addPath(t.path) }
        }
        func scan(_ v: HostJSON, _ key: String?) {
            switch v {
            case .string(let s):
                addTokens(s)
                if key == "source" || key == "bindingPath" { addPath(s) }
            case .array(let a): a.forEach { scan($0, nil) }
            case .object(let o):
                for (k, e) in o {
                    if k == "bindings", case .object(let b) = e {
                        for case .string(let p) in b.values { addPath(p) }
                        continue
                    }
                    if k == "repeat", case .object(let r) = e {
                        if case .string(let src)? = r["source"] { addPath(src) }
                        continue
                    }
                    scan(e, k)
                }
            default: break
            }
        }
        blocks.forEach { scan($0, nil) }
        for map in (localizations ?? [:]).values {
            for (k, v) in map where k.hasPrefix("block.") { addTokens(v) }
        }
        return keys
    }

    // MARK: Public entry points

    /// Resolve ONE raw top-level content block. The input is never mutated.
    static func resolveRawBlock(_ raw: HostJSON, _ ctx: HostDataContext) -> HostDataResolveResult {
        let stamped = stampBlockIds(raw, stepId: ctx.stepId, blockIndex: ctx.blockIndex)
        guard let block = HDVal(stamped).obj else {
            return HostDataResolveResult(block: stamped, localizations: nil, skipped: true, log: [],
                                         postExpansion: stamped, stampedAuthored: stamped, boundTopLevelKeys: [])
        }
        let ids = blockIndexOf(block)
        let locEntries = locKeysOf(ctx.localizations, ids.map(\.id))

        if blockSkipsRawPass(block, ctx.localizations) {
            var subset: [String: [String: String]]? = nil
            if let all = ctx.localizations {
                var out: [String: [String: String]] = [:]
                for (locale, key, _) in locEntries { out[locale, default: [:]][key] = all[locale]?[key] }
                subset = out
            }
            return HostDataResolveResult(block: stamped, localizations: subset, skipped: true, log: [],
                                         postExpansion: stamped, stampedAuthored: stamped, boundTopLevelKeys: [])
        }

        let pass = RawPass(ctx)
        let scope = rootScope(ctx)

        // 1. Bindings at every block depth (children, stack_children, carousel pages = children, sheet_blocks).
        forEachBlock(block, "") { b, _, inSheet in pass.applyBindings(b, scope, inSheet) }
        // 2. Strip authored markers — a hand-edited flow cannot bypass a required Select.
        forEachBlock(block, "") { b, _, _ in
            guard let fc = b.d["field_config"]?.obj else { return }
            for m in markers { fc.d.removeValue(forKey: m) }
        }
        // 3. Pending analysis on the authored (post-binding, pre-expansion) shape.
        var dependsOnHookData = HDIdentityMap<Bool>()
        forEachBlock(block, "") { b, _, inSheet in if !inSheet { dependsOnHookData[b] = optionsDependOnHookData(b) } }
        // 4. Repeat expansion — top-level input_select only.
        let repeatActive = pass.expandRepeat(block, scope)
        let postExpansion = HDVal.obj(block).host
        let boundTop = pass.boundKeys(of: block)
        // 5. The single structural pass.
        pass.walkBlock(block, scope, inSheet: false)
        // 6. Markers.
        let pending = ctx.pending
        forEachBlock(block, "") { b, _, inSheet in
            let paths = pass.sheetPathsOf(b)
            if inSheet, let paths {
                let fcObj: HDObj
                if let existing = b.d["field_config"]?.obj { fcObj = existing } else { fcObj = HDObj(); b.d["field_config"] = .obj(fcObj) }
                fcObj.d["sheet_step_paths"] = .arr(paths.map { p in
                    var d: [String: HDVal] = ["path": .string(p.path), "kind": .string(p.kind)]
                    if let s = p.source { d["source"] = .string(s) }
                    return .obj(HDObj(d))
                })
            }
            guard !inSheet, let type = b.d["type"]?.str, optionBearingTypes.contains(type) else { return }
            let fc = b.d["field_config"]?.obj
            if let os = fc?.d["option_set_id"]?.str, !os.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            let scoped = (b === block && repeatActive) || (pass.hiddenCount[b] ?? 0) > 0
            if pending {
                if dependsOnHookData[b] == true {
                    let next = HDObj(fc?.d ?? [:])
                    next.d["resolve_state"] = .string("pending")
                    b.d["field_config"] = .obj(next)
                }
                return
            }
            guard scoped else { return }
            let count = b.d["field_options"]?.arr?.count ?? 0
            let next = HDObj(fc?.d ?? [:])
            next.d["resolve_state"] = .string(count == 0 ? "empty_in_scope" : "scoped")
            if count == 0 {
                if case .bool(true)? = next.d["hide_when_empty"] {
                    next.d["empty_state"] = .obj(HDObj(["mode": .string("hidden")]))
                } else if let t = next.d["empty_text"]?.str, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    next.d["empty_state"] = .obj(HDObj(["mode": .string("text"), "text": .string(t)]))
                }
            }
            b.d["field_config"] = .obj(next)
        }

        // 7. Localizations — resolved in block scope; displaced keys deleted.
        var localizations: [String: [String: String]]? = nil
        if let all = ctx.localizations {
            var out: [String: [String: String]] = [:]
            for (locale, key, id) in locEntries {
                if out[locale] == nil { out[locale] = [:] }
                if pass.displacedLocKeys.contains(key) { continue }
                guard let value = all[locale]?[key] else { continue }
                if !value.contains("{{") { out[locale]![key] = value; continue }
                let owner = ids.first(where: { $0.id == id })?.obj
                let locScope = owner.map { seededScope($0, scope) } ?? scope
                out[locale]![key] = resolveString(value, scope: locScope, url: false, deferStep: false, legacy: ctx.legacyResolve).value
            }
            localizations = out
        }

        return HostDataResolveResult(
            block: HDVal.obj(block).host, localizations: localizations, skipped: false, log: pass.log,
            postExpansion: postExpansion, stampedAuthored: stamped, boundTopLevelKeys: boundTop
        )
    }

    static func seededScope(_ block: HDObj, _ scope: Scope) -> Scope {
        let stats = block.d["field_config"]?.obj?.d["summary_stats"]?.arr ?? []
        var seeds: [String: HDVal] = [:]
        for s in stats {
            guard let so = s.obj, let fid = so.d["field_id"]?.str, !fid.isEmpty, let def = so.d["default"] else { continue }
            seeds[fid] = def
        }
        if seeds.isEmpty { return scope }
        var merged = seeds
        if let live = scope.roots["step"]?.obj { for (k, v) in live.d { merged[k] = v } }
        var next = scope
        next.roots["step"] = .obj(HDObj(merged))
        return next
    }

    /// Resolve every top-level block of a step (index-aware id stamping) and merge the step's
    /// localizations: entries of blocks that took the pass are replaced by their resolved values,
    /// displaced keys removed; every other entry is kept as authored.
    static func resolveRawBlocks(_ blocks: [HostJSON], _ ctx: HostDataContext) -> (results: [HostDataResolveResult], localizations: [String: [String: String]]?) {
        var results: [HostDataResolveResult] = []
        var localizations = ctx.localizations
        for (i, b) in blocks.enumerated() {
            guard case .object = b else { continue }
            var c = ctx
            c.blockIndex = i
            let r = resolveRawBlock(b, c)
            results.append(r)
            guard localizations != nil, let rl = r.localizations, !r.skipped, let original = ctx.localizations,
                  let resolvedObj = HDVal(r.block).obj else { continue }
            for (locale, key, _) in locKeysOf(original, blockIndexOf(resolvedObj).map(\.id)) {
                if let v = rl[locale]?[key] { localizations![locale]![key] = v } else { localizations![locale]![key] = nil }
            }
        }
        return (results, localizations)
    }

    /// An `ElementInteractionResult.fieldConfigPatches` entry, resolved by the SAME structural
    /// walker as a block's own `field_config`: the patch is walked as the `field_config` of a block of
    /// `blockType`, so the URL rule (`*_url` keys and `gallery_images` elements that are unresolved
    /// or not absolute https are removed), the excluded keys, the generated `field_config` key classes
    /// (a `data_templates` entry on a non-string key is ignored) and the summary-stat placeholder
    /// rules all apply exactly as they do to authored content. A key the URL rule removed is ABSENT
    /// from the result — it is not applied. Marker / source keys must be dropped by the caller first.
    static func resolveFieldConfigPatch(
        _ patch: [String: Any], blockId: String, blockType: String, _ ctx: HostDataContext
    ) -> (patch: [String: Any], log: [String]) {
        guard let fc = HDVal(HostJSON(any: patch)).obj else { return (patch, []) }
        let block = HDObj(["id": .string(blockId), "type": .string(blockType), "field_config": .obj(fc)])
        let pass = RawPass(ctx)
        pass.walkBlock(block, rootScope(ctx), inSheet: false)
        guard let outFc = block.d["field_config"]?.obj,
              let out = HDVal.obj(outFc).host.foundation as? [String: Any] else { return ([:], pass.log) }
        return (out, pass.log)
    }
}

// MARK: - The pass

private struct SheetStepPath {
    var path: String
    var kind: String
    var source: String?
}

private final class OptionState {
    var generated: Bool
    var labelUnresolved = false
    var labelUnresolvedHookData = false
    var valueUnresolved = false
    init(generated: Bool) { self.generated = generated }
}

private struct WalkEnv {
    let block: HDObj
    let blockType: String
    let inSheet: Bool
    var path: [PathPart]
    var inField: Bool = false
}

private enum PathPart {
    case key(String)
    case index(Int)
    var text: String {
        switch self { case .key(let k): return k; case .index(let i): return String(i) }
    }
}

private final class RawPass {
    typealias H = HostDataResolver
    var log: [String] = []
    private let ctx: HostDataContext
    private var bound = HDIdentityMap<Set<String>>()
    private var sheetPaths = HDIdentityMap<[SheetStepPath]>()
    private var optionState = HDIdentityMap<OptionState>()
    private var itemScope = HDIdentityMap<(value: HDVal, index: Int)>()
    private var unresolvedKeys = HDIdentityMap<Set<String>>()
    var displacedLocKeys = Set<String>()
    var hiddenCount = HDIdentityMap<Int>()

    init(_ ctx: HostDataContext) { self.ctx = ctx }

    func boundKeys(of o: HDObj) -> Set<String> { bound[o] ?? [] }

    // MARK: Bindings

    func applyBindings(_ block: HDObj, _ scope: H.Scope, _ inSheet: Bool) {
        guard let bindings = block.d["bindings"]?.obj else { return }
        let blockId = block.d["id"]?.str ?? ""
        for prop in bindings.sortedKeys {
            guard let pathV = bindings.d[prop]?.str else { continue }
            if H.excluded.contains(prop) || H.markers.contains(prop) {
                log.append("binding \(blockId).\(prop): excluded/marker target — skipped"); continue
            }
            guard let cls = BlockKeyTypes.ownerKeyClasses["ContentBlock"]?[prop], H.bindableClasses.contains(cls) else {
                log.append("binding \(blockId).\(prop): target class not bindable — skipped"); continue
            }
            let root = H.firstSegment(pathV)
            if inSheet && root == "step" {
                addSheetPath(block, SheetStepPath(path: prop, kind: "binding", source: pathV))
                continue
            }
            guard let v = H.resolveScopePath(pathV, scope) else { continue }
            var converted: HDVal?
            switch cls {
            case "string": converted = H.stringify(v).map { .string($0) }
            case "number":
                switch v { case .int, .double: converted = v; default: converted = nil }
            case "bool":
                if case .bool = v { converted = v }
            case "string_list":
                if let a = v.arr {
                    let els = a.map { H.stringify($0) }
                    converted = els.allSatisfy { $0 != nil } ? .arr(els.map { .string($0!) }) : nil
                }
            default: converted = nil
            }
            guard let value = converted else {
                log.append("binding \(blockId).\(prop): value does not fit class \(cls) — skipped"); continue
            }
            block.d[prop] = value
            markBound(block, prop)
        }
    }

    private func markBound(_ o: HDObj, _ key: String) {
        var s = bound[o] ?? []
        s.insert(key)
        bound[o] = s
    }

    /// Deep-copy a repeat template WITH the per-object pass state bindings recorded on it.
    func cloneWithState(_ orig: HDVal) -> HDVal {
        let copy = orig.cloned
        func carry(_ a: HDVal, _ b: HDVal) {
            if let aa = a.arr, let ba = b.arr {
                for (i, x) in aa.enumerated() where i < ba.count { carry(x, ba[i]) }
                return
            }
            guard let ao = a.obj, let bo = b.obj else { return }
            if let s = bound[ao] { bound[bo] = s }
            if let p = sheetPaths[ao] { sheetPaths[bo] = p }
            for (k, v) in ao.d { if let bv = bo.d[k] { carry(v, bv) } }
        }
        carry(orig, copy)
        return copy
    }

    /// "Sheet ids" — deferred `step` paths inside a sheet block's options are recorded as
    /// `field_options.<i>.…` while walking, i.e. BEFORE the hide rule / dedupe settle the list.
    /// Re-point each to its option's settled index (options matched by identity); an option that was
    /// removed takes its paths with it. Mirrors the TS `remapOptionSheetPaths`.
    private func remapOptionSheetPaths(_ block: HDObj, _ before: [HDVal]) {
        guard let paths = sheetPaths[block], !paths.isEmpty else { return }
        let after = (block.d["field_options"]?.arr ?? []).compactMap { $0.obj }
        let prefix = "field_options."
        var next: [SheetStepPath] = []
        for p in paths {
            guard p.path.hasPrefix(prefix) else { next.append(p); continue }
            let rest = p.path.dropFirst(prefix.count)
            let digits = rest.prefix(while: { $0 >= "0" && $0 <= "9" })
            let tail = rest.dropFirst(digits.count)
            // Same shape as the TS regex /^field_options\.(\d+)(\..*)?$/ — anything else is kept as is.
            guard !digits.isEmpty, let oldIdx = Int(digits), tail.isEmpty || tail.hasPrefix(".") else {
                next.append(p); continue
            }
            guard oldIdx < before.count, let opt = before[oldIdx].obj,
                  let newIdx = after.firstIndex(where: { $0 === opt }) else { continue }
            var moved = p
            moved.path = prefix + String(newIdx) + String(tail)
            next.append(moved)
        }
        sheetPaths[block] = next
    }

    private func addSheetPath(_ block: HDObj, _ entry: SheetStepPath) {
        var list = sheetPaths[block] ?? []
        list.append(entry)
        sheetPaths[block] = list
    }

    // MARK: Repeat expansion

    func expandRepeat(_ block: HDObj, _ scope: H.Scope) -> Bool {
        guard block.d["type"]?.str == "input_select",
              let fc = block.d["field_config"]?.obj, let rep = fc.d["repeat"]?.obj else { return false }
        let blockId = block.d["id"]?.str ?? ""
        if let os = fc.d["option_set_id"]?.str, !os.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.append("repeat \(blockId): Option Set present — Option Set wins, repeat ignored")
            return false
        }
        let options = block.d["field_options"]?.arr ?? []
        let tid = rep.d["template_option_id"]?.str
        let templateIndex: Int? = tid.flatMap { t in options.firstIndex { $0.obj?.d["id"]?.str == t } }
        let template = templateIndex.map { options[$0] }
        var extras: [HDVal] = []
        for (i, o) in options.enumerated() where i != templateIndex { extras.append(o) }
        var max = H.repeatDefaultMax
        switch rep.d["max"] {
        case .int(let m)? where m > 0: max = Swift.min(Int(m), H.repeatHardMax)
        // Clamp BEFORE converting: `Int(1e30)` (or `Int(.infinity)`) traps.
        case .double(let m)? where m > 0 && m == m.rounded(.towardZero): max = Int(Swift.min(m, Double(H.repeatHardMax)))
        default: break
        }
        let source = rep.d["source"]?.str ?? ""
        let root = H.firstSegment(source)
        let arr: HDVal? = (root == "item" || root == "index") ? nil : H.resolveScopePath(source, scope)
        var generated: [HDVal] = []
        if let template, template.obj != nil {
            if let a = arr?.arr {
                if a.count > max {
                    // Items past `max` are silently not rendered; say so ONCE per
                    // changed source (keyed on the source's content fingerprint, not per raw pass).
                    let line = "repeat \(blockId): source \(source) has \(a.count) items, max is \(max) — items past max are not rendered"
                    log.append(line)
                    if RepeatOverflowLog.shouldLog(blockId: blockId, fingerprint: RepeatOverflowLog.fingerprint(arr!.host, max: max)) {
                        Log.debug("[Onboarding] \(line)")
                    }
                }
                for (i, el) in a.prefix(max).enumerated() {
                    let copy = cloneWithState(template)
                    let co = copy.obj!
                    co.d["id"] = .string("\(tid!)__\(i)")
                    itemScope[co] = (el, i)
                    optionState[co] = OptionState(generated: true)
                    generated.append(copy)
                }
            } else {
                log.append("repeat \(blockId): source \(source) is not an array — 0 generated options")
            }
        } else {
            log.append("repeat \(blockId): template_option_id \(tid ?? "nil") not found — 0 generated options")
        }
        block.d["field_options"] = .arr(generated + extras)
        return true
    }

    // MARK: Structural pass

    func walkBlock(_ block: HDObj, _ scope: H.Scope, inSheet: Bool) {
        let blockType = block.d["type"]?.str ?? ""
        let stats = block.d["field_config"]?.obj?.d["summary_stats"]?.arr ?? []
        var blockScope = scope
        var seeds: [String: HDVal] = [:]
        for s in stats {
            guard let so = s.obj, let fid = so.d["field_id"]?.str, !fid.isEmpty, let def = so.d["default"] else { continue }
            let live = scope.roots["step"]?.obj?.d[fid]
            if live == nil { seeds[fid] = def }
        }
        if !seeds.isEmpty {
            var merged = seeds
            if let live = scope.roots["step"]?.obj { for (k, v) in live.d { merged[k] = v } }
            blockScope.roots["step"] = .obj(HDObj(merged))
        }
        walkObject(block, .type("ContentBlock"), blockScope, WalkEnv(block: block, blockType: blockType, inSheet: inSheet, path: []))

        if let before = block.d["field_options"]?.arr {
            settleOptions(block)
            remapOptionSheetPaths(block, before)
        }
        if let fc = block.d["field_config"]?.obj, let list = fc.d["summary_stats"]?.arr {
            fc.d["summary_stats"] = .arr(list.compactMap { (s: HDVal) -> HDVal? in
                guard let so = s.obj else { return s }
                guard let kept = sanitizeStat(so) else { return nil }
                return .obj(kept)
            })
        }
    }

    private func walkObject(_ o: HDObj, _ owner: H.Owner, _ scopeIn: H.Scope, _ env: WalkEnv) {
        var scope = scopeIn
        if let own = itemScope[o] { scope.item = own }
        let boundSet = bound[o]
        let templates = o.d["data_templates"]
        o.d.removeValue(forKey: "data_templates")

        for key in o.sortedKeys {
            if H.excluded.contains(key) || boundSet?.contains(key) == true { continue }
            if env.inField && H.markers.contains(key) { continue }
            guard let v = o.d[key] else { continue }
            let path = env.path + [.key(key)]
            switch v {
            case .string(let s):
                resolveKey(o, key, s, scope, env, path)
            case .arr(let list):
                if o === env.block && H.blockListKeys.contains(key) {
                    for child in list { if let c = child.obj { walkBlock(c, scope, inSheet: env.inSheet) } }
                    continue
                }
                if o === env.block && key == "field_options" {
                    for (i, opt) in list.enumerated() {
                        guard let oo = opt.obj else { continue }
                        if !optionState.has(oo) { optionState[oo] = OptionState(generated: false) }
                        var e = env
                        e.path = path + [.index(i)]
                        e.inField = false
                        walkObject(oo, .type("InputOption"), scope, e)
                    }
                    continue
                }
                if key == "sheet_blocks", case .type("InputOption") = owner {
                    for sb in list { if let so = sb.obj { walkBlock(so, scope, inSheet: true) } }
                    continue
                }
                let elOwner = H.childOwnerOf(owner, key)
                var kept: [HDVal] = []
                var changed = false
                for (i, el) in list.enumerated() {
                    if case .string(let s) = el {
                        guard let r = resolveListString(s, key, scope, env, path + [.index(i)]) else { changed = true; continue }
                        if r != s { changed = true }
                        kept.append(.string(r))
                    } else {
                        if let eo = el.obj {
                            var e = env
                            e.path = path + [.index(i)]
                            walkObject(eo, elOwner, scope, e)
                        }
                        kept.append(el)
                    }
                }
                if changed {
                    if kept.isEmpty && !list.isEmpty && key == "gallery_images" { o.d.removeValue(forKey: key) }
                    else { o.d[key] = .arr(kept) }
                }
            case .obj(let child):
                let isFieldConfig = o === env.block && key == "field_config"
                let childOwner: H.Owner = isFieldConfig ? .fieldConfig(blockType: env.blockType, prefix: "") : H.childOwnerOf(owner, key)
                var e = env
                e.path = path
                e.inField = isFieldConfig ? true : env.inField
                walkObject(child, childOwner, scope, e)
            default:
                break
            }
        }

        // data_templates — after the plain keys, so a winning template replaces the resolved fallback.
        if let t = templates?.obj { applyDataTemplates(o, t, owner, scope, env, boundSet) }
    }

    private func resolveKey(_ o: HDObj, _ key: String, _ v: String, _ scope: H.Scope, _ env: WalkEnv, _ path: [PathPart]) {
        guard v.contains("{{") else { return }
        let url = H.isUrlKey(key)
        let r = H.resolveString(v, scope: scope, url: url, deferStep: env.inSheet, legacy: ctx.legacyResolve)
        if r.deferredStep { addSheetPath(env.block, SheetStepPath(path: path.map(\.text).joined(separator: "."), kind: "token", source: nil)) }
        let flags = optionState[o]
        if let flags, key == "label" {
            flags.labelUnresolved = r.unresolved
            flags.labelUnresolvedHookData = r.unresolvedHookData
        }
        if let flags, flags.generated, key == "value", r.hadToken,
           r.unresolved || r.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flags.valueUnresolved = true
        }
        if r.unresolved {
            var s = unresolvedKeys[o] ?? []
            s.insert(key)
            unresolvedKeys[o] = s
        }
        if url && r.hadToken && !r.deferredStep && (r.unresolved || !H.isValidTemplatedUrl(r.value)) {
            o.d.removeValue(forKey: key)
            log.append("url \(env.block.d["id"]?.str ?? "").\(path.map(\.text).joined(separator: ".")): unresolved or not an absolute https URL — key removed")
            return
        }
        o.d[key] = .string(r.value)
    }

    /// A string element of a list. Nil = drop the element.
    private func resolveListString(_ el: String, _ key: String, _ scope: H.Scope, _ env: WalkEnv, _ path: [PathPart]) -> String? {
        guard el.contains("{{") else { return el }
        let url = key == "gallery_images"
        let r = H.resolveString(el, scope: scope, url: url, deferStep: env.inSheet, legacy: ctx.legacyResolve)
        if r.deferredStep { addSheetPath(env.block, SheetStepPath(path: path.map(\.text).joined(separator: "."), kind: "token", source: nil)) }
        if url && r.hadToken && !r.deferredStep && (r.unresolved || !H.isValidTemplatedUrl(r.value)) {
            log.append("url \(env.block.d["id"]?.str ?? "").\(path.map(\.text).joined(separator: ".")): dropped")
            return nil
        }
        return r.value
    }

    private func applyDataTemplates(_ o: HDObj, _ templates: HDObj, _ owner: H.Owner, _ scope: H.Scope, _ env: WalkEnv, _ boundSet: Set<String>?) {
        for key in templates.sortedKeys {
            guard let tmpl = templates.d[key]?.str else { continue }
            if H.excluded.contains(key) || H.markers.contains(key) || key == "data_templates" {
                log.append("data_templates.\(key): excluded key — ignored"); continue
            }
            if let cls = H.classOf(owner, key), cls != "string" {
                log.append("data_templates.\(key): \(cls) key — ignored"); continue
            }
            if boundSet?.contains(key) == true { continue } // the binding wins
            // A `step` token in a data_templates entry inside sheet_blocks is a publish error;
            // at runtime the entry counts as unresolved (the sibling stays).
            if env.inSheet && H.extractTokens(tmpl).contains(where: { $0.root == "step" }) { continue }
            let url = H.isUrlKey(key)
            let r = H.resolveString(tmpl, scope: scope, url: url, deferStep: false, legacy: ctx.legacyResolve)
            let flags = optionState[o]
            var resolved = !r.unresolved && !r.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if resolved && url && !H.isValidTemplatedUrl(r.value) { resolved = false }
            if !resolved {
                if let flags, flags.generated, key == "value" { flags.valueUnresolved = true }
                continue
            }
            o.d[key] = .string(r.value)
            if let flags, key == "label" { flags.labelUnresolved = false; flags.labelUnresolvedHookData = false }
            if let flags, flags.generated, key == "value" { flags.valueUnresolved = false }
            if var s = unresolvedKeys[o] { s.remove(key); unresolvedKeys[o] = s }
            recordDisplacedLoc(env, env.path + [.key(key)])
        }
    }

    private func recordDisplacedLoc(_ env: WalkEnv, _ path: [PathPart]) {
        guard let blockId = env.block.d["id"]?.str else { return }
        var pattern = ""
        var index: Int? = nil
        for p in path {
            switch p {
            case .index(let i):
                pattern += "[]"
                if index == nil { index = i }
            case .key(let k):
                pattern += (pattern.isEmpty ? "" : ".") + k
            }
        }
        for row in BlockKeyTypes.localizationSuffixes where row.blockType == env.blockType && row.key == pattern {
            let suffix = row.suffix.replacingOccurrences(of: "<i>", with: String(index ?? 0))
            displacedLocKeys.insert("block.\(blockId).\(suffix)")
        }
    }

    // MARK: Options after the pass

    private func settleOptions(_ block: HDObj) {
        let opts = (block.d["field_options"]?.arr ?? []).compactMap { $0.obj }
        let pending = ctx.pending
        var generated: [HDObj] = []
        var extras: [HDObj] = []
        var hidden = 0
        for o in opts {
            let st = optionState[o]
            if let st, st.generated, st.valueUnresolved {
                log.append("option \(o.d["id"]?.str ?? ""): generated value unresolved/empty — dropped")
                continue
            }
            if let st {
                let label = o.d["label"]?.str ?? ""
                let hide = (st.labelUnresolved && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    || (pending && st.labelUnresolvedHookData)
                if hide { hidden += 1; continue }
            }
            if st?.generated == true { generated.append(o) } else { extras.append(o) }
        }
        func valueOf(_ o: HDObj) -> String {
            if let v = o.d["value"], !v.isNull { return H.stringify(v) ?? "" }
            if let v = o.d["id"], !v.isNull { return H.stringify(v) ?? "" }
            return ""
        }
        let extraValues = Set(extras.map(valueOf))
        var seen = Set<String>()
        let keptGenerated = generated.filter { o in
            let v = valueOf(o)
            if extraValues.contains(v) || seen.contains(v) {
                log.append("option \(o.d["id"]?.str ?? ""): duplicate value \(v) — dropped")
                return false
            }
            seen.insert(v)
            return true
        }
        block.d["field_options"] = .arr((keptGenerated + extras).map { .obj($0) })
        hiddenCount[block] = hidden
    }

    private func sanitizeStat(_ stat: HDObj) -> HDObj? {
        let flags = unresolvedKeys[stat]
        let valueUnresolved = flags?.contains("value") ?? false
        let labelUnresolved = flags?.contains("label") ?? false
        let hasLabel = !(stat.d["label"]?.str ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if valueUnresolved && (labelUnresolved || !hasLabel) { return nil }
        if valueUnresolved { stat.d["value"] = .string("—") }
        if labelUnresolved { stat.d.removeValue(forKey: "label") }
        return stat
    }

    func sheetPathsOf(_ block: HDObj) -> [SheetStepPath]? {
        guard let list = sheetPaths[block], !list.isEmpty else { return nil }
        return list.sorted { a, b in a.path != b.path ? a.path < b.path : a.kind < b.kind }
    }
}

/// The "source longer than max" debug line, once per changed source per block.
/// Bounded: it forgets everything past 256 blocks.
enum RepeatOverflowLog {
    private static let lock = NSLock()
    private static var last: [String: Int] = [:]

    static func fingerprint(_ source: HostJSON, max: Int) -> Int {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var h = Hasher()
        h.combine((try? e.encode(source)) ?? Data())
        h.combine(max)
        return h.finalize()
    }

    static func shouldLog(blockId: String, fingerprint: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if last[blockId] == fingerprint { return false }
        if last.count >= 256 { last.removeAll() }
        last[blockId] = fingerprint
        return true
    }
}
