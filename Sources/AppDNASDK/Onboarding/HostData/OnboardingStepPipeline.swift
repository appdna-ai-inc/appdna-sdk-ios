import Foundation

// SPEC-496 §A1 / §A4 — the ONE step pipeline.
//
//   raw pass (HostDataResolver) → typed decode with per-key revert → StepConfigOverrideMerger →
//   interaction layering (ElementInteractionResult options + field_config patches)
//
// It produces ONE layered block list, and every reader of the presented step's blocks evaluates that
// same list: the Select views, the required-field gate / `canAdvance`, the validation toast, the OTP
// resolver and the consent-CTA colour gate. `OnboardingStepRouter` runs it for real rendering; the
// shared-fixture runner runs the SAME function for `host_data_scenario`, so what the fixtures prove is
// what ships.
//
// Readers that deliberately stay on the AUTHORED (stamped) blocks in P1 — they read `step.config`,
// never this output: image prefetch (`OnboardingFlowHost.collectImageURLs`), secret-field ids
// (`AuthSecretRedactor`), `optionAliases` for branching (`OnboardingAdvance`) and
// `OnboardingCTAFlag.applyTo` (reads only excluded keys).

/// Test seam for §A1 "No whole-block failure": makes the typed decode of one block reject while the
/// value at `keyPath` differs from its post-expansion value. Never set in production.
struct HostDataDecodeSeam {
    let blockId: String
    /// Dot path, e.g. `field_options.0.subtitle`.
    let keyPath: String
}

/// The presented step after the pipeline.
struct ResolvedOnboardingStep {
    /// The effective config: resolved + host-merged + interaction-layered `content_blocks`, resolved
    /// `localizations`; every other field as `StepConfigOverrideMerger` leaves it.
    var config: StepConfig
    /// Ids of every block (any depth, not sheet content) the raw pass PRODUCED. Only these honour the
    /// SDK-internal markers, bypass the view-level template pass, and get a lookup-only `loc()`.
    var rawResolvedIds: Set<String>
    /// §A1 — keys the per-key decode revert put back (debug log in P1).
    var revertedKeys: [(blockId: String, keyPath: String)]
    var log: [String]

    var blocks: [ContentBlock] { config.content_blocks ?? [] }

    func isRawResolved(_ blockId: String) -> Bool { rawResolvedIds.contains(blockId) }

    /// A `block.<id>.<suffix>` key whose block was raw-resolved → `loc()` must be lookup-only.
    func isRawResolvedLocKey(_ key: String) -> Bool {
        guard key.hasPrefix("block."), !rawResolvedIds.isEmpty else { return false }
        return rawResolvedIds.contains { key.hasPrefix("block.\($0).") }
    }
}

enum OnboardingStepPipeline {

    struct Input {
        var step: OnboardingStep
        /// `configOverrides[step.id]` — applied AFTER resolve, never before (§A4).
        var override: StepConfigOverride?
        /// §B0 — the presentation's pending flag.
        var pending: Bool
        var inputValues: [String: Any]
        /// Accumulated responses of prior steps (`responses` root).
        var responses: [String: Any]
        /// user / session roots + TemplateEngine's per-token resolver for legacy roots.
        var templateContext: TemplateContext
        /// `SelectedOptionStore` snapshot (`selected` root).
        var selected: [String: Any]
        var fieldConfigOverrides: [String: [String: Any]] = [:]
        var fieldOptionsOverrides: [String: [InputOption]] = [:]
        var decodeSeam: HostDataDecodeSeam? = nil
        /// SPEC-496 §5b C3 — the EFFECTIVE `hook_data` (the `onBeforeStepRender` base with the
        /// interaction layer applied), computed from the owners' live values. `.base` keeps the P1
        /// behaviour (`override?.dataContext`) for a caller without an interaction layer.
        var hookDataSource: HookDataSource = .base

        /// The ONE `hook_data` map every reader uses: the raw pass, the option-text resolver, patch
        /// resolution and the memo fingerprint.
        var hookData: [String: Any]? {
            switch hookDataSource {
            case .base: return override?.dataContext
            case .effective(let m): return m
            }
        }
    }

    enum HookDataSource {
        case base
        case effective([String: Any]?)
    }

    /// Keys host data may never set on a block's `field_config` (§A4): markers and option sources.
    static let hostStrippedFieldConfigKeys: [String] = ["option_set_id", "repeat", "empty_state", "resolve_state"]
    static let droppedPatchKeys: Set<String> = ["resolve_state", "empty_state", "sheet_step_paths", "repeat", "option_set_id"]

    // MARK: - Pending applicability (§B0 "Applies")

    /// Whether the step can ever be pending: its raw blocks (or `block.<id>.*` localizations)
    /// reference `hook_data`. A step without raw blocks is never pending.
    static func referencesHookData(_ step: OnboardingStep) -> Bool {
        guard let raw = step.rawContentBlocks else { return false }
        return HostDataResolver.stepReferencesHookData(raw, localizations: step.config.localizations)
    }

    // MARK: - Resolve

    static func hostDataContext(_ input: Input) -> HostDataContext {
        let tctx = input.templateContext
        var ctx = HostDataContext()
        ctx.stepId = input.step.id
        ctx.hookData = input.hookData.map { HostJSON(any: $0) }
        ctx.responses = HostJSON(any: input.responses)
        ctx.step = HostJSON(any: input.inputValues)
        ctx.user = tctx.userTraits.map { HostJSON(any: $0) }
        ctx.session = HostJSON(any: tctx.sessionData)
        ctx.selected = HostJSON(any: input.selected)
        ctx.pending = input.pending
        ctx.localizations = input.step.config.localizations
        ctx.legacyResolve = { path, fallback in
            TemplateEngine.shared.resolveToken(path, fallback: fallback, context: tctx)
        }
        return ctx
    }

    static func resolve(_ input: Input) -> ResolvedOnboardingStep {
        var config = input.step.config
        var rawIds = Set<String>()
        var reverted: [(blockId: String, keyPath: String)] = []
        var log: [String] = []

        if let raw = input.step.rawContentBlocks {
            let ctx = hostDataContext(input)
            let (results, localizations) = HostDataResolver.resolveRawBlocks(raw, ctx)
            let authored = input.step.config.content_blocks ?? []
            var typed: [ContentBlock] = []
            for (i, r) in results.enumerated() {
                log.append(contentsOf: r.log)
                if r.skipped {
                    // Decoded once at capture; keeps today's interpolating `loc()`.
                    if results.count == authored.count { typed.append(authored[i]) }
                    else if let b = try? decodeBlock(r.block) { typed.append(b) }
                    continue
                }
                let outcome = decodeWithRevert(r, seam: input.decodeSeam)
                reverted.append(contentsOf: outcome.reverted)
                if !outcome.reverted.isEmpty {
                    log.append("SPEC-496 decode revert \(outcome.blockId): \(outcome.reverted.map(\.keyPath).joined(separator: ", "))")
                }
                if let block = outcome.block {
                    typed.append(block)
                    collectIds(block, into: &rawIds)
                } else if results.count == authored.count {
                    // Still failing after every revert → the raw authored block (today's behaviour).
                    typed.append(authored[i])
                } else if let b = try? decodeBlock(r.stampedAuthored) {
                    typed.append(b)
                }
            }
            config.content_blocks = typed
            config.localizations = localizations
        }

        // StepConfigOverride typed merges — after resolve, never before (§A4).
        config = StepConfigOverrideMerger.apply(input.override, to: config)
        if var blocks = config.content_blocks {
            var patchCtx: HostDataContext? = nil
            for i in blocks.indices {
                let id = blocks[i].id
                // §A1 "single pass" — WHO resolves host-supplied text depends on who draws the block.
                // A raw-resolved block skips the view-level pass, so its host / interaction option
                // text is resolved HERE. Any other block (skip rule, or a step without raw capture)
                // still goes through the view-level pass, which resolves option `label` / `subtitle` /
                // `leading_text` and `field_config.summary_stats` itself — resolving them here too
                // would re-scan substituted values.
                let raw = rawIds.contains(id)
                // Host `fieldOptions` are host data already: option sources + markers removed.
                if input.override?.fieldOptions?[id] != nil {
                    if raw { blocks[i].field_options = resolveOptionText(blocks[i].field_options ?? [], input) }
                    blocks[i].field_config = stripHostKeys(blocks[i].field_config)
                }
                // ElementInteractionResult `field_config` patches — resolved by the STRUCTURAL walker
                // (§A4: URL rule §A6, excluded keys, key classes), marker / source keys dropped first.
                if let patch = input.fieldConfigOverrides[id], !patch.isEmpty {
                    var kept = patch.filter { !droppedPatchKeys.contains($0.key) }
                    // The view-level pass owns `summary_stats` on a block it draws.
                    let viewOwned: [String: Any] = raw ? [:] : kept.filter { $0.key == "summary_stats" }
                    for k in viewOwned.keys { kept.removeValue(forKey: k) }
                    if patchCtx == nil { patchCtx = hostDataContext(input) }
                    let r = HostDataResolver.resolveFieldConfigPatch(
                        kept, blockId: id, blockType: blocks[i].type.rawValue, patchCtx!
                    )
                    log.append(contentsOf: r.log)
                    var fc = blocks[i].field_config ?? [:]
                    for (k, v) in r.patch { fc[k] = AnyCodable(v) }
                    for (k, v) in viewOwned { fc[k] = AnyCodable(v) }
                    blocks[i].field_config = fc
                }
                // ElementInteractionResult options — replace, strip sources + markers.
                if let options = input.fieldOptionsOverrides[id] {
                    blocks[i].field_options = raw ? resolveOptionText(options, input) : options
                    blocks[i].field_config = stripHostKeys(blocks[i].field_config)
                }
            }
            config.content_blocks = blocks
        }
        return ResolvedOnboardingStep(config: config, rawResolvedIds: rawIds, revertedKeys: reverted, log: log)
    }

    private static func stripHostKeys(_ fc: [String: AnyCodable]?) -> [String: AnyCodable]? {
        guard var fc else { return nil }
        for k in hostStrippedFieldConfigKeys { fc.removeValue(forKey: k) }
        return fc
    }

    /// `label`, `subtitle`, `leading_text` of host-supplied options, resolved as the view pass always
    /// did for them (an unresolved token keeps today's behaviour — the literal stays).
    static func resolveOptionText(_ options: [InputOption], _ input: Input) -> [InputOption] {
        guard let data = try? JSONEncoder().encode(options),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return options }
        var changed = false
        let hook = input.hookData
        let next: [[String: Any]] = arr.map { opt in
            var o = opt
            for key in ["label", "subtitle", "leading_text"] {
                if let s = opt[key] as? String, s.contains("{{") {
                    o[key] = resolveTemplateString(
                        s, hookData: hook, responses: input.responses,
                        sessionData: input.templateContext.sessionData,
                        userTraits: input.templateContext.userTraits,
                        stepInputs: input.inputValues
                    )
                    changed = true
                }
            }
            return o
        }
        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: next),
              let decoded = try? JSONDecoder().decode([InputOption].self, from: out) else { return options }
        return decoded
    }

    static func decodeBlock(_ h: HostJSON) throws -> ContentBlock {
        try JSONDecoder().decode(ContentBlock.self, from: h.jsonData())
    }

    private static func collectIds(_ block: ContentBlock, into ids: inout Set<String>) {
        ids.insert(block.id)
        for c in (block.children ?? []) + (block.stack_children ?? []) { collectIds(c, into: &ids) }
    }

    // MARK: - §A1 "No whole-block failure" — per-key revert

    /// A revert unit: a top-level key, or one key of one option (`field_options.<i>.<key>`).
    private enum PathPart: Equatable {
        case key(String)
        case index(Int)
    }

    private struct HostCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init(intValue: Int) { self.stringValue = "Index \(intValue)"; self.intValue = intValue }
    }

    private static func parts(ofKeyPath path: String) -> [PathPart] {
        path.components(separatedBy: ".").map { seg in
            if let i = Int(seg), seg.allSatisfy({ $0.isASCII && $0.isNumber }) { return .index(i) }
            return .key(seg)
        }
    }

    private static func keyPathText(_ unit: [PathPart]) -> String {
        unit.map { p -> String in
            switch p { case .key(let k): return k; case .index(let i): return String(i) }
        }.joined(separator: ".")
    }

    /// Narrow a decode failure's coding path to a revert unit.
    private static func unit(fromCodingPath path: [CodingKey]) -> [PathPart]? {
        let parts: [PathPart] = path.map { k in
            if let i = k.intValue { return .index(i) }
            return .key(k.stringValue)
        }
        guard case .key(let first)? = parts.first else { return nil }
        if first == "field_options", parts.count >= 3, case .index = parts[1], case .key = parts[2] {
            return Array(parts.prefix(3))
        }
        return [.key(first)]
    }

    private static func value(_ json: [String: HostJSON], at unit: [PathPart]) -> HostJSON? {
        guard case .key(let k)? = unit.first else { return nil }
        if unit.count == 1 { return json[k] }
        guard case .index(let i) = unit[1], case .key(let ok) = unit[2],
              case .array(let opts)? = json[k], i < opts.count, case .object(let o) = opts[i] else { return nil }
        return o[ok]
    }

    private static func setting(_ json: [String: HostJSON], at unit: [PathPart], to v: HostJSON?) -> [String: HostJSON] {
        var out = json
        guard case .key(let k)? = unit.first else { return out }
        if unit.count == 1 { out[k] = v; return out }
        guard case .index(let i) = unit[1], case .key(let ok) = unit[2],
              case .array(var opts)? = json[k], i < opts.count, case .object(var o) = opts[i] else { return out }
        o[ok] = v
        opts[i] = .object(o)
        out[k] = .array(opts)
        return out
    }

    /// The value a unit reverts to: the post-expansion value (a key a BINDING wrote reverts to its
    /// authored raw value). Options are matched by id, so a hidden/dropped sibling cannot shift them.
    private static func baseline(_ unit: [PathPart], current: [String: HostJSON], r: HostDataResolveResult) -> HostJSON? {
        let post = r.postExpansion.objectValue ?? [:]
        guard case .key(let k)? = unit.first else { return nil }
        if unit.count == 1 {
            if r.boundTopLevelKeys.contains(k) { return r.stampedAuthored.objectValue?[k] }
            return post[k]
        }
        guard case .index(let i) = unit[1], case .key(let ok) = unit[2],
              case .array(let opts)? = current[k], i < opts.count, case .object(let cur) = opts[i],
              case .array(let postOpts)? = post[k] else { return nil }
        let match: [String: HostJSON]? = {
            if let id = cur["id"] {
                for p in postOpts { if case .object(let po) = p, po["id"] == id { return po } }
            }
            if i < postOpts.count, case .object(let po) = postOpts[i] { return po }
            return nil
        }()
        return match?[ok]
    }

    /// Every changed unit, in a stable order (the cumulative fallback when no key is named).
    private static func changedUnits(_ current: [String: HostJSON], r: HostDataResolveResult) -> [[PathPart]] {
        let post = r.postExpansion.objectValue ?? [:]
        var units: [[PathPart]] = []
        for k in Set(current.keys).union(post.keys).sorted() where k != "field_options" {
            let u: [PathPart] = [.key(k)]
            if value(current, at: u) != baseline(u, current: current, r: r) { units.append(u) }
        }
        if case .array(let opts)? = current["field_options"] {
            for (i, o) in opts.enumerated() {
                guard case .object(let oo) = o else { continue }
                for ok in oo.keys.sorted() {
                    let u: [PathPart] = [.key("field_options"), .index(i), .key(ok)]
                    if value(current, at: u) != baseline(u, current: current, r: r) { units.append(u) }
                }
            }
        }
        return units
    }

    struct RevertOutcome {
        let blockId: String
        let block: ContentBlock?
        let reverted: [(blockId: String, keyPath: String)]
    }

    static func decodeWithRevert(_ r: HostDataResolveResult, seam: HostDataDecodeSeam?) -> RevertOutcome {
        var current = r.block.objectValue ?? [:]
        let blockId = current["id"]?.stringValue ?? ""
        var reverted: [(blockId: String, keyPath: String)] = []
        var revertedUnits: [[PathPart]] = []
        let seamUnit = seam.flatMap { $0.blockId == blockId ? parts(ofKeyPath: $0.keyPath) : nil }

        func attempt() throws -> ContentBlock {
            if let su = seamUnit, value(current, at: su) != baseline(su, current: current, r: r) {
                throw DecodingError.typeMismatch(String.self, DecodingError.Context(
                    codingPath: su.map { p -> CodingKey in
                        switch p { case .key(let k): return HostCodingKey(stringValue: k); case .index(let i): return HostCodingKey(intValue: i) }
                    },
                    debugDescription: "SPEC-496 fixture decode seam"
                ))
            }
            return try decodeBlock(.object(current))
        }

        let maxAttempts = 64
        for _ in 0..<maxAttempts {
            do {
                let block = try attempt()
                return RevertOutcome(blockId: blockId, block: block, reverted: reverted)
            } catch {
                var target: [PathPart]? = nil
                if let de = error as? DecodingError, let u = unit(fromCodingPath: codingPath(of: de)),
                   !revertedUnits.contains(u),
                   value(current, at: u) != baseline(u, current: current, r: r) {
                    target = u
                } else {
                    // No key named (or nothing to revert there) → cumulative, one at a time.
                    target = changedUnits(current, r: r).first { !revertedUnits.contains($0) }
                }
                guard let t = target else { break }
                current = setting(current, at: t, to: baseline(t, current: current, r: r))
                revertedUnits.append(t)
                reverted.append((blockId: blockId, keyPath: keyPathText(t)))
            }
        }
        return RevertOutcome(blockId: blockId, block: nil, reverted: reverted)
    }

    private static func codingPath(of e: DecodingError) -> [CodingKey] {
        switch e {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return c.codingPath
        case .keyNotFound(let k, let c): return c.codingPath + [k]
        @unknown default: return []
        }
    }

    // MARK: - Markers (read side)

    /// `field_config.resolve_state` — honoured ONLY on a block the raw pass produced.
    static func resolveState(_ block: ContentBlock, rawResolvedIds: Set<String>) -> String? {
        guard rawResolvedIds.contains(block.id) else { return nil }
        return block.field_config?["resolve_state"]?.value as? String
    }

    /// `field_config.empty_state` — `(mode, text)`; honoured only on raw-pass blocks.
    static func emptyState(_ block: ContentBlock, rawResolved: Bool) -> (mode: String, text: String?)? {
        guard rawResolved, let es = block.field_config?["empty_state"]?.value as? [String: Any],
              let mode = es["mode"] as? String else { return nil }
        return (mode, es["text"] as? String)
    }

    static func isHiddenByEmptyState(_ block: ContentBlock, rawResolved: Bool) -> Bool {
        emptyState(block, rawResolved: rawResolved)?.mode == "hidden"
    }

    // MARK: - §B0 selection clearing

    /// When a §B0-scoped Select's rendered options no longer contain a selected value, that value is
    /// removed from `inputValues[field_id]` (and, by the caller, the view's selected state and
    /// `SelectedOptionStore`). Never on a pending, Option-Set or out-of-scope block.
    /// Every block of the step at any container depth (`children` / `stack_children`), parents
    /// first — NOT an option's `sheet_blocks` (a sheet's inputs are its own, never the step's).
    static func allStepBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var out: [ContentBlock] = []
        func walk(_ bs: [ContentBlock]) {
            for b in bs {
                out.append(b)
                walk(b.children ?? [])
                walk(b.stack_children ?? [])
            }
        }
        walk(blocks)
        return out
    }

    static func clearVanishedSelections(
        blocks: [ContentBlock], rawResolvedIds: Set<String>, inputValues: [String: Any]
    ) -> (inputValues: [String: Any], changes: [(fieldId: String, remaining: [InputOption])]) {
        var iv = inputValues
        var changes: [(fieldId: String, remaining: [InputOption])] = []
        // A §B0-scoped Select nested in a container is scoped exactly like a top-level one.
        for block in allStepBlocks(blocks) {
            guard HostDataResolver.optionBearingTypes.contains(block.type.rawValue),
                  let state = resolveState(block, rawResolvedIds: rawResolvedIds),
                  state == "scoped" || state == "empty_in_scope" else { continue }
            if let os = block.field_config?["option_set_id"]?.value as? String,
               !os.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fid = block.field_id ?? block.id
            let options = block.field_options ?? []
            let rendered = Set(options.map(\.resolvedValue))
            if let s = iv[fid] as? String {
                if !s.isEmpty && !rendered.contains(s) {
                    iv.removeValue(forKey: fid)
                    changes.append((fid, []))
                }
            } else if let arr = iv[fid] as? [String] {
                let kept = arr.filter { rendered.contains($0) }
                if kept.count != arr.count {
                    if kept.isEmpty { iv.removeValue(forKey: fid) } else { iv[fid] = kept }
                    let keptOptions = kept.compactMap { v in options.first { $0.resolvedValue == v } }
                    changes.append((fid, keptOptions))
                }
            }
        }
        return (iv, changes)
    }

    /// Apply `clearVanishedSelections`' store side.
    static func applySelectionChanges(_ changes: [(fieldId: String, remaining: [InputOption])], store: SelectedOptionStore = .shared) {
        for c in changes {
            if c.remaining.isEmpty { store.clear(fieldId: c.fieldId) }
            else { store.record(fieldId: c.fieldId, options: c.remaining) }
        }
    }

    // MARK: - What the renderer draws

    /// `loc()` for the router: translation lookup, then TemplateEngine interpolation — EXCEPT for a
    /// raw-resolved block, where it is lookup-only (the raw pass already resolved every string and
    /// every `block.<id>.*` translation; interpolating again would re-scan substituted data).
    static func loc(_ key: String, _ fallback: String, resolved: ResolvedOnboardingStep, context: () -> TemplateContext) -> String {
        let localized = LocalizationEngine.resolve(
            key: key, localizations: resolved.config.localizations,
            defaultLocale: resolved.config.default_locale, fallback: fallback
        )
        if resolved.isRawResolvedLocKey(key) { return localized }
        return TemplateEngine.shared.interpolate(localized, context: context())
    }

    /// The block `ContentBlockRendererView` draws: a raw-resolved block as-is (plus its deferred
    /// `sheet_step_paths` inside an option sheet); any other block through today's view-level pass.
    static func displayBlock(
        _ block: ContentBlock, rawResolved: Bool,
        hookData: [String: Any]?, responses: [String: Any], stepInputs: [String: Any]
    ) -> ContentBlock {
        if rawResolved { return applySheetStepPaths(block, stepInputs: stepInputs) }
        return resolveBlockTemplates(block, hookData: hookData, responses: responses, stepInputs: stepInputs)
    }

    /// §B0 "Sheet ids" — the sheet renderer resolves ONLY the paths the raw pass recorded, against
    /// the sheet's own inputs: `token` entries as `{{step.x}}` strings, `binding` entries with the
    /// §A4 class conversion. Nothing else in the block is re-scanned.
    ///
    /// Every block at ANY depth inside `sheet_blocks` carries its own `sheet_step_paths` (relative
    /// to itself), so this recurses into `children` / `stack_children` — a container's nested
    /// blocks render through `containerChildren` → `renderBlock(child)`, which does no resolution
    /// of its own. It does NOT descend into a nested option's `sheet_blocks`: those resolve against
    /// THAT sheet's inputs when it opens.
    static func applySheetStepPaths(_ block: ContentBlock, stepInputs: [String: Any]) -> ContentBlock {
        guard carriesSheetStepPaths(block),
              let data = try? JSONEncoder().encode(block),
              let h = try? JSONDecoder().decode(HostJSON.self, from: data),
              case .object(let json) = h else { return block }
        let out = applySheetStepPaths(json: json, inputs: HostJSON(any: stepInputs), stepInputs: stepInputs)
        guard let decoded = try? decodeBlock(.object(out)) else { return block }
        return decoded
    }

    /// Whether this block or any nested child (not a nested option sheet) has deferred paths —
    /// the cheap check that keeps the encode/decode off every block without them.
    private static func carriesSheetStepPaths(_ block: ContentBlock) -> Bool {
        if let entries = block.field_config?["sheet_step_paths"]?.value as? [Any], !entries.isEmpty { return true }
        if (block.children ?? []).contains(where: carriesSheetStepPaths) { return true }
        return (block.stack_children ?? []).contains(where: carriesSheetStepPaths)
    }

    private static func applySheetStepPaths(json input: [String: HostJSON], inputs: HostJSON, stepInputs: [String: Any]) -> [String: HostJSON] {
        var json = input
        if case .object(let fc)? = json["field_config"], case .array(let entries)? = fc["sheet_step_paths"] {
            for case .object(let e) in entries {
                guard case .string(let path)? = e["path"], case .string(let kind)? = e["kind"] else { continue }
                let segs = path.components(separatedBy: ".")
                if kind == "token" {
                    guard case .string(let s)? = get(.object(json), segs), s.contains("{{") else { continue }
                    let r = resolveTemplateString(s, hookData: nil, responses: [:], stepInputs: stepInputs)
                    json = (set(.object(json), segs, .string(r)).objectValue) ?? json
                } else if kind == "binding", case .string(let source)? = e["source"] {
                    let fid = source.components(separatedBy: ".").dropFirst().joined(separator: ".")
                    guard case .object(let io) = inputs, let v = io[fid] else { continue }
                    let cls = BlockKeyTypes.ownerKeyClasses["ContentBlock"]?[path]
                    var converted: HostJSON?
                    switch cls ?? "" {
                    case "string": converted = HostDataResolver.stringify(v).map { .string($0) }
                    case "number": if case .int = v { converted = v } else if case .double = v { converted = v }
                    case "bool": if case .bool = v { converted = v }
                    case "string_list":
                        if case .array(let a) = v {
                            let els = a.map { HostDataResolver.stringify($0) }
                            if els.allSatisfy({ $0 != nil }) { converted = .array(els.map { .string($0!) }) }
                        }
                    default: converted = nil
                    }
                    if let converted { json[path] = converted }
                }
            }
            // Applied — strip the entries so a SECOND call on this output is a no-op. A carousel's
            // pages are applied here via `children`, then drawn by a nested renderer that calls
            // `applySheetStepPaths` again; without this the already-substituted strings (which may
            // hold a user-typed `{{…}}`) would be re-scanned (§A1 no re-scan). The caller's source
            // block keeps its paths, so the next render re-applies against the live inputs.
            if case .object(var fcNow)? = json["field_config"] {
                fcNow.removeValue(forKey: "sheet_step_paths")
                json["field_config"] = .object(fcNow)
            }
        }
        for key in ["children", "stack_children"] {
            guard case .array(let kids)? = json[key] else { continue }
            json[key] = .array(kids.map { kid in
                guard case .object(let o) = kid else { return kid }
                return .object(applySheetStepPaths(json: o, inputs: inputs, stepInputs: stepInputs))
            })
        }
        return json
    }

    private static func get(_ h: HostJSON, _ segs: [String]) -> HostJSON? {
        var cur = h
        for s in segs {
            switch cur {
            case .object(let o): guard let n = o[s] else { return nil }; cur = n
            case .array(let a): guard let i = Int(s), i < a.count else { return nil }; cur = a[i]
            default: return nil
            }
        }
        return cur
    }

    private static func set(_ h: HostJSON, _ segs: [String], _ v: HostJSON) -> HostJSON {
        guard let first = segs.first else { return v }
        let rest = Array(segs.dropFirst())
        switch h {
        case .object(var o):
            guard let child = o[first] else { return h }
            o[first] = set(child, rest, v)
            return .object(o)
        case .array(var a):
            guard let i = Int(first), i < a.count else { return h }
            a[i] = set(a[i], rest, v)
            return .array(a)
        default: return h
        }
    }
}

// MARK: - Memo

/// §A1 "Cost" — the pipeline is re-run only when something it reads changed: the step's raw content
/// and localizations, host data, responses, step inputs, the selected-option snapshot, user traits /
/// session data, the value of every legacy-root token the step references (`computed`,
/// `remote_config`, `device`, `onboarding`, … — resolved per token through TemplateEngine), the
/// pending flag, the locale, or a host / interaction override. One instance per presented step
/// (router `@State`), so it is scoped to one presentation.
final class OnboardingStepPipelineMemo {
    private var lastKey: Data?
    private var last: ResolvedOnboardingStep?
    /// The raw content the memoised result was built from — compared by value, not by count: a
    /// config refresh can change a block's content without changing how many there are.
    private var lastRaw: [HostJSON]?
    private var lastLocalizations: [String: [String: String]]?
    /// Legacy-root tokens of the current raw content (static per content; re-extracted on change).
    private var legacyTokens: [(path: String, fallback: String?)] = []

    func resolve(_ input: OnboardingStepPipeline.Input) -> ResolvedOnboardingStep {
        let raw = input.step.rawContentBlocks
        let locs = input.step.config.localizations
        let contentChanged = raw != lastRaw || locs != lastLocalizations
        if contentChanged { legacyTokens = Self.legacyTokens(raw: raw, localizations: locs) }
        let key = Self.fingerprint(input, legacyTokens: legacyTokens)
        if !contentChanged, let last, let key, key == lastKey { return last }
        let r = OnboardingStepPipeline.resolve(input)
        lastKey = key
        last = r
        lastRaw = raw
        lastLocalizations = locs
        return r
    }

    /// Every token in the raw blocks / `block.*` localizations whose root is NOT a block root: those
    /// resolve through TemplateEngine (§A5), from state the other key parts do not cover.
    static func legacyTokens(raw: [HostJSON]?, localizations: [String: [String: String]]?) -> [(path: String, fallback: String?)] {
        var seen = Set<String>()
        var out: [(path: String, fallback: String?)] = []
        func add(_ s: String) {
            guard s.contains("{{") else { return }
            for t in HostDataResolver.extractTokens(s) where !HostDataResolver.blockRoots.contains(t.root) {
                let k = t.path + "\u{1F}" + (t.fallback ?? "\u{1E}")
                if seen.insert(k).inserted { out.append((t.path, t.fallback)) }
            }
        }
        func scan(_ h: HostJSON) {
            switch h {
            case .string(let s): add(s)
            case .array(let a): a.forEach(scan)
            case .object(let o): o.values.forEach(scan)
            default: break
            }
        }
        (raw ?? []).forEach(scan)
        for map in (localizations ?? [:]).values { for (k, v) in map where k.hasPrefix("block.") { add(v) } }
        return out
    }

    static func fingerprint(_ input: OnboardingStepPipeline.Input, legacyTokens: [(path: String, fallback: String?)] = []) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func options(_ o: [String: [InputOption]]?) -> HostJSON {
            guard let o, let d = try? encoder.encode(o), let h = try? JSONDecoder().decode(HostJSON.self, from: d) else { return .null }
            return h
        }
        var ov: [String: HostJSON] = [:]
        if let o = input.override {
            ov["title"] = o.title.map { .string($0) } ?? .null
            ov["subtitle"] = o.subtitle.map { .string($0) } ?? .null
            ov["cta"] = o.ctaText.map { .string($0) } ?? .null
            ov["defaults"] = HostJSON(any: o.fieldDefaults)
            ov["options"] = options(o.fieldOptions)
            ov["routes"] = .object((o.mapRoutes ?? [:]).mapValues { r in
                .object([
                    "p": r.polyline.map { .string($0) } ?? .null,
                    "s": .array(r.stops.map { .array([.double($0.lat), .double($0.lng), $0.title.map { .string($0) } ?? .null]) }),
                ])
            })
        }
        let key: HostJSON = .object([
            "step": .string(input.step.id),
            "raw": .int(Int64(input.step.rawContentBlocks?.count ?? -1)),
            "pending": .bool(input.pending),
            "inputs": HostJSON(any: input.inputValues),
            "responses": HostJSON(any: input.responses),
            "user": HostJSON(any: input.templateContext.userTraits),
            "session": HostJSON(any: input.templateContext.sessionData),
            "selected": HostJSON(any: input.selected),
            "fco": HostJSON(any: input.fieldConfigOverrides),
            "fo": options(input.fieldOptionsOverrides),
            "override": input.override == nil ? .null : .object(ov),
            // §5b C3 — the EFFECTIVE hook_data (base + interaction layer), not `override.dataContext`:
            // a `dataContext`-only interaction reply must bust the memo.
            "hook_data": HostJSON(any: input.hookData),
            "locale": .string(Locale.current.identifier),
            "legacy": .array(legacyTokens.map { t in
                .string(TemplateEngine.shared.resolveToken(t.path, fallback: t.fallback, context: input.templateContext))
            }),
        ])
        return try? encoder.encode(key)
    }
}
