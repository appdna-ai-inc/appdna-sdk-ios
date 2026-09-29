// HostDataFixtureDrivers.swift
//
// SPEC-496 — the iOS drivers for the two host-data fixture kinds, dispatched from
// `SharedFixtureTests.drive`:
//
//   resolve_block       REAL: `HostDataResolver.resolveRawBlock` — the same raw pass
//                       `OnboardingStepPipeline` runs for every presented onboarding step. The resolved
//                       block JSON is compared TYPE-STRICTLY (the generic assertion treats "1" == 1).
//
//   host_data_scenario  REAL: the step decoder (`OnboardingStep`, raw capture + id stamping), the step
//                       pipeline `OnboardingStepPipeline.resolve` (raw pass → decode with per-key
//                       revert → StepConfigOverrideMerger → interaction layering), the pending state
//                       machine `HostDataPendingCoordinator` (driven on a manual clock), the gate
//                       `RequiredFieldGate.evaluate(…rawResolvedIds:)`, selection clearing, the Select
//                       tap `SelectOptionTap.apply`, the in-memory search `filterOptionsLocally`,
//                       `OnboardingStepPipeline.displayBlock` / `.loc` (what the renderer draws),
//                       `mapRoutePolyline`, `applyInteractionResult` + `mergeFieldConfigOverrides`,
//                       and `AuthSecretRedactor`. `OnboardingStepRouter` calls exactly these; the
//                       runner holds the @State the router would hold.
//
// Checkpoint semantics (fixture.schema.json): every key present must match, keys absent are not
// asserted. Map-valued observables (`input_values`, `blocks`, `rendered_text`, …) are asserted per key
// present in the expectation — `input_values: {tour: null}` means "absent", and the step legitimately
// carries other inputs. `responses_step` is additionally checked to contain NO redacted field id.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests.AnyJSON {
    /// The fixture's JSON, with its int / double / bool / string kinds intact.
    var host: HostJSON {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(\.host))
        case .object(let o): return .object(o.mapValues(\.host))
        }
    }
}

extension SharedFixtureTests {

    // MARK: - Type-strict JSON comparison

    /// Structural, TYPE-STRICT: a string never equals a number or a bool; key order irrelevant, array
    /// order significant, no extra or missing keys. Numbers compare by value (3 == 3.0).
    static func strictDiff(_ expected: HostJSON, _ actual: HostJSON, path: String = "$") -> String? {
        switch (expected, actual) {
        case (.null, .null): return nil
        case (.bool(let a), .bool(let b)): return a == b ? nil : "\(path): expected \(a), got \(b)"
        case (.string(let a), .string(let b)): return a == b ? nil : "\(path): expected \"\(a)\", got \"\(b)\""
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double):
            func num(_ h: HostJSON) -> Double { if case .int(let i) = h { return Double(i) }; if case .double(let d) = h { return d }; return .nan }
            return num(expected) == num(actual) ? nil : "\(path): expected \(num(expected)), got \(num(actual))"
        case (.array(let a), .array(let b)):
            if a.count != b.count { return "\(path): expected \(a.count) elements, got \(b.count) — \(render(actual))" }
            for (i, pair) in zip(a, b).enumerated() {
                if let d = strictDiff(pair.0, pair.1, path: "\(path)[\(i)]") { return d }
            }
            return nil
        case (.object(let a), .object(let b)):
            let ka = Set(a.keys), kb = Set(b.keys)
            if ka != kb {
                return "\(path): keys differ — missing \(ka.subtracting(kb).sorted()), extra \(kb.subtracting(ka).sorted())"
            }
            for k in ka.sorted() {
                if let d = strictDiff(a[k]!, b[k]!, path: "\(path).\(k)") { return d }
            }
            return nil
        default:
            return "\(path): type differs — expected \(render(expected)), got \(render(actual))"
        }
    }

    static func render(_ h: HostJSON) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(h)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    /// A TemplateContext built from the fixture (never the live SDK singletons).
    func fixtureTemplateContext(_ f: Fixture) -> TemplateContext {
        let rc = (f.setup.remote_config?.objectValue ?? [:]).mapValues { $0.foundation }
        let sd = f.setup.session_data?.objectValue ?? [:]
        return TemplateContext(
            userTraits: (sd["user"]?.objectValue ?? f.setup.user_traits?.objectValue)?.mapValues { $0.foundation },
            remoteConfig: { key in rc[key].flatMap { TemplateEngine.stringify($0) } },
            onboardingResponses: [:],
            computedData: [:],
            sessionData: (sd["session"]?.objectValue ?? [:]).mapValues { $0.foundation },
            deviceInfo: [:]
        )
    }

    // MARK: - resolve_block

    func runResolveBlock(_ f: Fixture, _ h: Harness) {
        guard let config = f.setup.config else { return XCTFail("[\(f.id)] resolve_block needs setup.config (one raw block)") }
        let sd = f.setup.session_data?.objectValue ?? [:]
        func root(_ k: String) -> HostJSON? {
            guard let v = sd[k] else { return nil }
            if case .null = v { return nil }
            return v.host
        }
        var ctx = HostDataContext()
        ctx.hookData = root("hook_data")
        ctx.responses = root("responses")
        ctx.step = root("step")
        ctx.user = root("user")
        ctx.session = root("session")
        ctx.selected = root("selected")
        ctx.pending = sd["pending"]?.boolValue == true
        if let loc = sd["localizations"]?.objectValue {
            var out: [String: [String: String]] = [:]
            for (locale, m) in loc {
                for (k, v) in m.objectValue ?? [:] { if let s = v.stringValue { out[locale, default: [:]][k] = s } }
                if out[locale] == nil { out[locale] = [:] }
            }
            ctx.localizations = out
        }
        if let sid = sd["step_id"]?.stringValue { ctx.stepId = sid }
        if case .int(let i)? = sd["block_index"] { ctx.blockIndex = Int(i) }
        let tctx = fixtureTemplateContext(f)
        ctx.legacyResolve = { path, fb in TemplateEngine.shared.resolveToken(path, fallback: fb, context: tctx) }

        let result = HostDataResolver.resolveRawBlock(config.host, ctx)

        let state = f.expect.state_after?.objectValue ?? [:]
        guard let expectedBlock = state["resolved_block"] else {
            return XCTFail("[\(f.id)] resolve_block needs expect.state_after.resolved_block")
        }
        if let d = Self.strictDiff(expectedBlock.host, result.block) {
            XCTFail("[\(f.id)] resolved_block (type-strict) \(d)\n  actual: \(Self.render(result.block))")
        }
        h.state["resolved_block"] = result.block.foundation
        if let expectedLoc = state["resolved_localizations"] {
            let actual = HostJSON(any: result.localizations.map { $0 as Any })
            if let d = Self.strictDiff(expectedLoc.host, actual) {
                XCTFail("[\(f.id)] resolved_localizations (type-strict) \(d)\n  actual: \(Self.render(actual))")
            }
            h.state["resolved_localizations"] = actual.foundation
        }
    }

    // MARK: - decode_interaction_result (SPEC-496 §5b C2)

    /// The core `ElementInteractionResult.decodeDataContext`, fed the reply map two ways: as a BRIDGE
    /// delivers it (the JSON text parsed by `JSONSerialization` — NSNumber / CFBoolean / NSNull, as the
    /// RN and Flutter bridges see it) and as a NATIVE Swift host builds it (`Bool` / `Int` / `Double` /
    /// `NSNull`). Both must decode to the expectation TYPE-STRICTLY: 0/1 stay integers, `true` a bool,
    /// a null member the removal marker.
    func runDecodeInteractionResult(_ f: Fixture, _ h: Harness) {
        guard let reply = f.setup.session_data?.objectValue?["host_interaction_reply"] else {
            return XCTFail("[\(f.id)] decode_interaction_result needs setup.session_data.host_interaction_reply")
        }
        guard let expected = f.expect.state_after?.objectValue?["decoded_data_context"] else {
            return XCTFail("[\(f.id)] decode_interaction_result needs expect.state_after.decoded_data_context")
        }
        // 1. Bridged: through JSON text, exactly as a wrapper bridge receives it.
        guard let data = try? JSONSerialization.data(withJSONObject: reply.foundation),
              let bridged = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            return XCTFail("[\(f.id)] host_interaction_reply is not a JSON object")
        }
        let decodedBridged = ElementInteractionResult.decodeDataContext(bridged["dataContext"])
        let actualBridged = HostJSON(any: decodedBridged)
        if let d = Self.strictDiff(expected.host, actualBridged) {
            XCTFail("[\(f.id)] decoded_data_context (bridged, type-strict) \(d)\n  actual: \(Self.render(actualBridged))")
        }
        // A top-level null member is kept as the removal marker (NSNull), never dropped.
        if case .object(let exp)? = Optional(expected.host) {
            for (k, v) in exp where v == .null {
                XCTAssertTrue(decodedBridged?[k] is NSNull, "[\(f.id)] top-level null '\(k)' must decode to the NSNull removal marker")
            }
        }
        // 2. Native: the Swift values a native host would write.
        let native = (reply.objectValue?["dataContext"]).map { $0.foundation }
        let actualNative = HostJSON(any: ElementInteractionResult.decodeDataContext(native))
        if let d = Self.strictDiff(expected.host, actualNative) {
            XCTFail("[\(f.id)] decoded_data_context (native, type-strict) \(d)\n  actual: \(Self.render(actualNative))")
        }
        h.state["decoded_data_context"] = actualBridged.foundation
    }

    // MARK: - host_data_scenario

    @MainActor
    func runHostDataScenario(_ f: Fixture, _ h: Harness) async {
        SelectedOptionStore.shared.resetForTesting()
        defer { SelectedOptionStore.shared.resetForTesting() }
        guard let stepJSON = f.setup.config?.objectValue?["step"] else {
            return XCTFail("[\(f.id)] host_data_scenario needs setup.config.step")
        }
        guard let script = f.action.raw["script"]?.arrayValue else {
            return XCTFail("[\(f.id)] host_data_scenario needs action.script")
        }
        let run = HostDataScenarioRun(fixtureId: f.id, stepJSON: stepJSON, templateContext: fixtureTemplateContext(f),
                                      responses: sessionResponsesHD(f))
        let expectedCheckpoints = f.expect.state_after?.objectValue?["checkpoints"]?.objectValue ?? [:]
        var actualCheckpoints: [String: Any] = [:]

        for (i, opAny) in script.enumerated() {
            guard let op = opAny.objectValue, let name = op["op"]?.stringValue else {
                XCTFail("[\(f.id)] script[\(i)] has no op"); continue
            }
            switch name {
            case "present_step": await run.present(op)
            case "delegate_reply": await run.reply(op)
            case "cancel_delegate_call": await run.cancelCall()
            case "advance_clock_ms": await run.advanceClock(Int(op["ms"]?.doubleValue ?? 0))
            case "set_step_input":
                run.view?.inputValues[op["field_id"]?.stringValue ?? ""] = op["value"]?.foundation
                run.refresh()
            case "toggle":
                run.view?.toggleValues[op["block_id"]?.stringValue ?? ""] = op["value"]?.boolValue ?? false
                run.refresh()
            case "select_option": run.select(blockId: op["block_id"]?.stringValue ?? "", value: op["value"]?.stringValue ?? "")
            case "type_search":
                run.view?.searchQueries[op["block_id"]?.stringValue ?? ""] = op["query"]?.stringValue ?? ""
                run.refresh()
            case "open_sheet":
                run.view?.openSheet = (op["block_id"]?.stringValue ?? "", op["option_value"]?.stringValue ?? "")
                run.view?.sheetInputs = (op["sheet_inputs"]?.objectValue ?? [:]).mapValues { $0.foundation }
            case "element_interaction": await run.elementInteraction(op)
            case "complete_step": run.completeStep()
            // SPEC-496 §5b C10 — P1b ops.
            case "tap": await run.tap(op)
            case "fire_interaction": await run.fireInteraction(op)
            case "interaction_reply": await run.interactionReply(op)
            case "interaction_throw": await run.interactionThrow(op)
            case "leave_step": await run.leaveStep()
            case "begin_transition_to": await run.beginTransition(op)
            case "reuse_view_new_presentation": await run.reuseViewNewPresentation()
            case "recreate": run.refresh() // Android Activity recreation — a no-op on iOS.
            case "refire_before_render": await run.refireBeforeRender()
            case "checkpoint":
                let cp = op["name"]?.stringValue ?? ""
                guard let expected = expectedCheckpoints[cp]?.objectValue else {
                    XCTFail("[\(f.id)] checkpoint '\(cp)' has no expectation"); continue
                }
                let actual = run.observe(expected)
                actualCheckpoints[cp] = actual
                for (key, exp) in expected {
                    let e = Self.canonicalJSON(exp)
                    let a = Self.canonical(actual[key])
                    if e != a { XCTFail("[\(f.id)] checkpoint '\(cp)'.\(key): expected \(e), got \(a)") }
                }
            default:
                XCTFail("[\(f.id)] unknown host_data_scenario op '\(name)'")
            }
            if !run.failures.isEmpty {
                for m in run.failures { XCTFail("[\(f.id)] script[\(i)] \(name): \(m)") }
                run.failures.removeAll()
            }
        }
        h.state["checkpoints"] = actualCheckpoints
    }

    fileprivate func sessionResponsesHD(_ f: Fixture) -> [String: Any] {
        (f.setup.session_data?.objectValue?["responses"]?.objectValue ?? [:]).mapValues { $0.foundation }
    }
}

// MARK: - The presented step, as OnboardingFlowHost + OnboardingStepRouter hold it

/// A manual clock for the coordinators' deadlines (the §B0 3 s one and the §5b 8 s refresh one).
final class HostDataManualClock {
    private(set) var nowMs = 0
    private var timers: [(id: Int, due: Int, fire: () -> Void)] = []
    private var nextId = 0

    func add(_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        let id = nextId
        nextId += 1
        timers.append((id, nowMs + Int((seconds * 1000).rounded()), fire))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(_ ms: Int) {
        let target = nowMs + ms
        // Fire in due order, each at its own time (a timer's `fire` may arm another).
        while let i = timers.indices.filter({ timers[$0].due <= target }).min(by: { timers[$0].due < timers[$1].due }) {
            let t = timers.remove(at: i)
            nowMs = max(nowMs, t.due)
            t.fire()
        }
        nowMs = target
    }
}

/// The host delegate's `onBeforeStepRender`, as the fixture scripts it: it suspends until the script
/// replies (`awaiting`) or forever, ignoring cancellation (`non_cooperative`).
final class ScriptedStepRenderDelegate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<StepConfigOverride?, Never>] = []
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func call() async -> StepConfigOverride? {
        await withCheckedContinuation { (c: CheckedContinuation<StepConfigOverride?, Never>) in
            lock.lock()
            _calls += 1
            waiting.append(c)
            lock.unlock()
        }
    }

    /// Resume the LATEST outstanding call.
    func reply(_ override: StepConfigOverride?) -> Bool {
        lock.lock()
        guard let c = waiting.popLast() else { lock.unlock(); return false }
        lock.unlock()
        c.resume(returning: override)
        return true
    }
}

/// SPEC-496 §5b C10 — the scripted host's `onElementInteraction`. It ALWAYS implements the method.
/// Every call it receives is recorded (`interaction_calls`); an addressable call (from `tap` /
/// `fire_interaction`) suspends until the script answers it — at most once — with
/// `interaction_reply` / `interaction_throw`. The answer is delivered even after the SDK ended the call
/// (its deadline fired); the SDK must drop it.
final class ScriptedInteractionHost: @unchecked Sendable {
    struct HostThrow: Error {}
    private let lock = NSLock()
    private var _calls: [[String: Any]] = []
    private var waiting: [Int: CheckedContinuation<ElementInteractionResult?, Error>] = [:]
    private var early: [Int: Result<ElementInteractionResult?, Error>] = [:]
    private var answered: Set<Int> = []

    var calls: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _calls }

    func record(stepId: String, blockId: String, action: String, value: String?) {
        lock.lock()
        _calls.append(["step_id": stepId, "block_id": blockId, "action": action, "value": value ?? NSNull()])
        lock.unlock()
    }

    func awaitAnswer(_ index: Int) async throws -> ElementInteractionResult? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<ElementInteractionResult?, Error>) in
            lock.lock()
            if let r = early.removeValue(forKey: index) {
                lock.unlock()
                c.resume(with: r)
                return
            }
            waiting[index] = c
            lock.unlock()
        }
    }

    /// false = a second answer for the same call (a driver error: the fixture is invalid).
    func answer(_ index: Int, _ r: Result<ElementInteractionResult?, Error>) -> Bool {
        lock.lock()
        guard !answered.contains(index) else { lock.unlock(); return false }
        answered.insert(index)
        if let c = waiting.removeValue(forKey: index) {
            lock.unlock()
            c.resume(with: r)
        } else {
            early[index] = r
            lock.unlock()
        }
        return true
    }
}

/// One presented step — what one `OnboardingStepRouter` instance holds: its `@State` (inputs, toggles,
/// the per-presentation overlays), its presentation serial and THAT presentation's coordinator.
@MainActor
final class HostDataStepView {
    let step: OnboardingStep
    var presentation: Int
    var coordinator: InteractionCoordinator
    var applies = false
    var inputValues: [String: Any] = [:]
    var toggleValues: [String: Bool] = [:]
    var fieldConfigOverridesByPresentation: [Int: [String: [String: Any]]] = [:]
    var fieldOptionsOverridesByPresentation: [Int: [String: [InputOption]]] = [:]
    var searchQueries: [String: String] = [:]
    var openSheet: (blockId: String, value: String)?
    /// The open sheet's OWN inputs (its renderer's `inputValues`) — never the step's.
    var sheetInputs: [String: Any] = [:]
    var decodeSeam: HostDataDecodeSeam?
    var firstResolvePending: Bool?
    var resolved: ResolvedOnboardingStep?

    init(step: OnboardingStep, presentation: Int, coordinator: InteractionCoordinator) {
        self.step = step
        self.presentation = presentation
        self.coordinator = coordinator
    }

    var fieldConfigOverrides: [String: [String: Any]] { fieldConfigOverridesByPresentation[presentation] ?? [:] }
    var fieldOptionsOverrides: [String: [InputOption]] { fieldOptionsOverridesByPresentation[presentation] ?? [:] }

    func allBlockIds() -> Set<String> {
        var ids = Set<String>()
        func walk(_ bs: [ContentBlock]) { for b in bs { ids.insert(b.id); walk((b.children ?? []) + (b.stack_children ?? [])) } }
        walk(resolved?.blocks ?? step.config.content_blocks ?? [])
        return ids
    }

    func findBlock(_ id: String) -> ContentBlock? {
        HostDataScenarioRun.find(id, in: resolved?.blocks ?? [])
    }
}

@MainActor
final class HostDataScenarioRun {
    let fixtureId: String
    let stepJSON: SharedFixtureTests.AnyJSON
    let templateContext: TemplateContext
    let responses: [String: Any]
    var failures: [String] = []

    // Flow level — `OnboardingFlowHost`.
    let clock = HostDataManualClock()
    lazy var coordinator = HostDataPendingCoordinator(schedule: { [clock] seconds, fire in clock.add(seconds, fire) })
    lazy var store = HostDataInteractionStore(schedule: { [clock] seconds, fire in clock.add(seconds, fire) })
    let delegate = ScriptedStepRenderDelegate()
    let host = ScriptedInteractionHost()
    var delegateMode = "none"
    var onStepViewedCalls = 0
    /// `configOverrides[step.id]`.
    var configOverrides: [String: StepConfigOverride] = [:]
    /// Each step's last `responses_step` (what a real Back restores as `saved_responses`).
    var responsesByStep: [String: [String: Any]] = [:]
    var redactedFieldIds: [String] = []
    /// The flow host's `presentationSerial`.
    var serial = 0
    /// Addressable interaction calls (`tap` / `fire_interaction`), in start order.
    var nextCallIndex = 0
    /// The CURRENT step view; the OUTGOING one while a `begin_transition_to` is in its exit window; and
    /// the one the user last left (a placeholder is current then, and checkpoints read that view).
    var current: HostDataStepView?
    var outgoing: HostDataStepView?
    var lastLeft: HostDataStepView?

    init(fixtureId: String, stepJSON: SharedFixtureTests.AnyJSON, templateContext: TemplateContext, responses: [String: Any]) {
        self.fixtureId = fixtureId
        self.stepJSON = stepJSON
        self.templateContext = templateContext
        self.responses = responses
    }

    /// The view the step-level ops and observables address.
    var view: HostDataStepView? { current ?? lastLeft }

    /// The view that owns `blockId` — the current step's, else the outgoing step's (still live in its
    /// exit window), else the one last left.
    func view(owning blockId: String) -> HostDataStepView? {
        for v in [current, outgoing, lastLeft].compactMap({ $0 }) where v.allBlockIds().contains(blockId) { return v }
        return nil
    }

    /// The renderer's own expression (`HostDataInteractionStore.isCached`).
    func cached(_ step: OnboardingStep) -> Bool {
        store.isCached(step, hasBase: configOverrides[step.id] != nil)
    }

    /// `OnboardingFlowHost.hostDataPending(for:applies:)` / `pendingProvider(coordinator:serial:applies:cached:)`
    /// — layer-aware "cached", latched per serial.
    func pending(_ v: HostDataStepView) -> Bool {
        coordinator.isPending(presentation: v.presentation, applies: v.applies, cached: cached(v.step))
    }


    func hookData(_ v: HostDataStepView) -> [String: Any]? {
        store.effectiveHookData(stepId: v.step.id, fallbackBase: configOverrides[v.step.id]?.dataContext)
    }

    /// Let the delegate call / coordinator tasks run.
    func settle() async {
        for _ in 0..<25 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Presentations

    func decodeStep(_ json: Any, rawAbsent: Bool = false) -> OnboardingStep? {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let decoded = try? JSONDecoder().decode(OnboardingStep.self, from: data) else { return nil }
        if rawAbsent {
            // A step built without raw capture (constructed in code) → today's view-level pass.
            return OnboardingStep(id: decoded.id, type: decoded.type, config: decoded.config, hook: decoded.hook,
                                  hide_progress: decoded.hide_progress, hide_back: decoded.hide_back,
                                  next_step_rules: decoded.next_step_rules, name: decoded.name)
        }
        return decoded
    }

    /// A new presentation: the serial moves and the store's current presentation moves with it, in
    /// the same transaction (the renderer's navigation).
    func newPresentation() -> Int {
        serial += 1
        store.setCurrentPresentation(serial)
        return serial
    }

    /// `OnboardingFlowHost.handleStepAppear` — the `onBeforeStepRender` call for `v`'s presentation,
    /// raced against the (manual) deadline, drawing `callSeq` at start.
    func startBeforeRender(_ v: HostDataStepView, mode: String) {
        let d = delegate
        let stepId = v.step.id
        let s = store
        coordinator.start(
            presentation: v.presentation,
            seq: { s.nextCallSeq() },
            call: {
                if mode == "none" { return nil } // no delegate: `host?.onBeforeStepRender` is nil
                return await d.call()
            },
            onSettled: { [weak self] in self?.onStepViewedCalls += 1 },
            onFinish: { [weak self] override, seq in
                guard let self else { return }
                // Applied only if the user is STILL on this step (renderer `:622`).
                if let override, self.current?.step.id == stepId {
                    self.configOverrides[stepId] = override
                    self.store.recordBase(stepId: stepId, override: override, stamp: seq)
                }
                self.refresh()
            }
        )
    }

    func present(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        // REAL: the SDK's step decoder (raw capture + id stamping), exactly as RemoteConfigManager.
        guard let step = decodeStep(stepJSON.foundation, rawAbsent: op["raw"]?.stringValue == "absent") else {
            failures.append("present_step: the SDK could not decode setup.config.step"); return
        }
        // A present_step while another step is current is a navigation away from it.
        if let c = current { lastLeft = c }
        outgoing = nil
        let p = newPresentation()
        let v = HostDataStepView(step: step, presentation: p, coordinator: store.coordinator(for: p, stepId: step.id))
        // A revisit restores the step's last answers, as a real Back does, unless the op says otherwise.
        if let saved = op["saved_responses"]?.objectValue {
            v.inputValues = saved.mapValues { $0.foundation }
        } else if let last = responsesByStep[step.id] {
            v.inputValues = last
        }
        if let fd = op["force_decode_failure"]?.objectValue,
           let b = fd["block_id"]?.stringValue, let k = fd["key_path"]?.stringValue {
            v.decodeSeam = HostDataDecodeSeam(blockId: b, keyPath: k)
        }
        delegateMode = op["delegate"]?.stringValue ?? "none"
        v.applies = delegateMode != "none" && OnboardingStepPipeline.referencesHookData(step)
        current = v
        // §B0 "Starts synchronously" — the FIRST resolve happens before the call starts (onAppear);
        // this first `isPending` is also where "cached" is sampled and latched for the serial.
        v.firstResolvePending = pending(v)
        refresh()
        startBeforeRender(v, mode: delegateMode)
        await settle()
        refresh()
    }

    /// `leave_step` — Back off the step: the presentation ends, nothing is written. The flow host
    /// moves to a placeholder step (a new presentation), which never fires interactions.
    func leaveStep() async {
        guard let c = current else { failures.append("leave_step: no step is presented"); return }
        lastLeft = c
        current = nil
        outgoing = nil
        _ = newPresentation()
        await settle()
        refresh()
    }

    /// `begin_transition_to` — navigation to a second step B while A stays live (its exit window).
    func beginTransition(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        guard let a = current else { failures.append("begin_transition_to: no step is presented"); return }
        guard let stepAny = op["step"], let b = decodeStep(stepAny.foundation) else {
            failures.append("begin_transition_to: the SDK could not decode op.step"); return
        }
        let aIds = a.allBlockIds()
        var bIds = Set<String>()
        func walk(_ bs: [ContentBlock]) { for x in bs { bIds.insert(x.id); walk((x.children ?? []) + (x.stack_children ?? [])) } }
        walk(b.config.content_blocks ?? [])
        if !aIds.isDisjoint(with: bIds) {
            failures.append("begin_transition_to: block ids must be unique across the two steps (\(aIds.intersection(bIds).sorted()))")
            return
        }
        outgoing = a
        let p = newPresentation()
        let v = HostDataStepView(step: b, presentation: p, coordinator: store.coordinator(for: p, stepId: b.id))
        let mode = op["delegate"]?.stringValue ?? "none"
        v.applies = mode != "none" && OnboardingStepPipeline.referencesHookData(b)
        current = v
        v.firstResolvePending = pending(v)
        refresh()
        startBeforeRender(v, mode: mode)
        await settle()
        refresh()
    }

    /// `reuse_view_new_presentation` — the SAME router identity moves to a new presentation (a 0→1→0
    /// inside the exit animation): its `@State` stays, `store.coordinator(for:)` hands it a NEW
    /// coordinator, the per-presentation overlays read empty, and `onBeforeStepRender` re-fires.
    func reuseViewNewPresentation() async {
        guard let v = current else { failures.append("reuse_view_new_presentation: no step is presented"); return }
        let p = newPresentation()
        v.presentation = p
        v.coordinator = store.coordinator(for: p, stepId: v.step.id)
        v.firstResolvePending = pending(v)
        refresh()
        startBeforeRender(v, mode: delegateMode)
        await settle()
        refresh()
    }

    /// `refire_before_render` — the iOS paywall-uncover `handleStepAppear` on the SAME presentation.
    func refireBeforeRender() async {
        guard let v = current else { failures.append("refire_before_render: no step is presented"); return }
        startBeforeRender(v, mode: delegateMode == "none" ? "awaiting" : delegateMode)
        await settle()
        refresh()
    }

    func reply(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        var override: StepConfigOverride? = nil
        let dataContext = op["data_context"]?.objectValue?.mapValues { $0.foundation }
        let options = Self.decodeOptions(op["field_options"])
        if dataContext != nil || options != nil {
            override = StepConfigOverride(fieldOptions: options, dataContext: dataContext)
        }
        if !delegate.reply(override) { failures.append("delegate_reply: no delegate call is waiting") }
        await settle()
        refresh()
    }

    func cancelCall() async {
        coordinator.cancelInFlight()
        await settle()
        refresh()
    }

    func advanceClock(_ ms: Int) async {
        clock.advance(ms)
        await settle()
        refresh()
    }

    // MARK: Resolve (OnboardingStepRouter.resolvedStep + clearVanishedSelections)

    func refresh() {
        for v in [current, outgoing, lastLeft].compactMap({ $0 }) { refresh(v) }
    }

    func refresh(_ v: HostDataStepView) {
        let isPending = pending(v)
        func resolveNow() -> ResolvedOnboardingStep {
            OnboardingStepPipeline.resolve(OnboardingStepPipeline.Input(
                step: v.step,
                override: configOverrides[v.step.id],
                pending: isPending,
                inputValues: v.inputValues,
                responses: responses,
                templateContext: templateContext,
                selected: SelectedOptionStore.shared.snapshot,
                fieldConfigOverrides: v.fieldConfigOverrides,
                fieldOptionsOverrides: v.fieldOptionsOverrides,
                decodeSeam: v.decodeSeam,
                hookDataSource: .effective(hookData(v))
            ))
        }
        var r = resolveNow()
        let cleared = OnboardingStepPipeline.clearVanishedSelections(blocks: r.blocks, rawResolvedIds: r.rawResolvedIds, inputValues: v.inputValues)
        if !cleared.changes.isEmpty {
            v.inputValues = cleared.inputValues
            OnboardingStepPipeline.applySelectionChanges(cleared.changes)
            r = resolveNow()
        }
        v.resolved = r
    }

    static func find(_ id: String, in blocks: [ContentBlock]) -> ContentBlock? {
        for b in blocks {
            if b.id == id { return b }
            if let c = find(id, in: (b.children ?? []) + (b.stack_children ?? [])) { return c }
        }
        return nil
    }

    func select(blockId: String, value: String) {
        refresh()
        guard let v = view(owning: blockId) ?? view, let block = v.findBlock(blockId) else {
            failures.append("select_option: no block \(blockId)"); return
        }
        let options = block.field_options ?? []
        guard let option = options.first(where: { $0.resolvedValue == value }) else {
            failures.append("select_option: block \(blockId) renders no option \(value) (renders \(options.map(\.resolvedValue)))")
            return
        }
        let fid = block.field_id ?? block.id
        let currentValues = (v.inputValues[fid] as? [String]) ?? []
        _ = SelectOptionTap.apply(option: option, block: block, selectedValues: currentValues,
                                  sourcedOptions: filterOptionsLocally(options, query: v.searchQueries[blockId] ?? ""),
                                  inputValues: &v.inputValues)
        refresh()
    }

    // MARK: Interactions (OnboardingStepRouter.handleInteract → InteractionCoordinator)

    static func decodeOptions(_ raw: SharedFixtureTests.AnyJSON?) -> [String: [InputOption]]? {
        guard let fo = raw?.objectValue else { return nil }
        var out: [String: [InputOption]] = [:]
        for (blockId, list) in fo {
            if let data = try? JSONSerialization.data(withJSONObject: list.foundation),
               let opts = try? JSONDecoder().decode([InputOption].self, from: data) { out[blockId] = opts }
        }
        return out
    }

    /// The fixture's `result` object → the `ElementInteractionResult` the host returns. `null` → nil.
    static func interactionResult(_ raw: SharedFixtureTests.AnyJSON?) -> ElementInteractionResult? {
        guard let res = raw?.objectValue else { return nil }
        let patches = res["field_config_patches"]?.objectValue?.compactMapValues { $0.objectValue?.mapValues { $0.foundation } }
        let inputPatches = res["input_values"]?.objectValue?.mapValues { $0.foundation }
        let dataContext = res["data_context"]?.objectValue?.mapValues { $0.foundation }
        return ElementInteractionResult(
            fieldConfigPatches: patches, inputValuePatches: inputPatches, fieldOptions: decodeOptions(res["field_options"]),
            advance: res["advance"]?.boolValue ?? false, dataContext: dataContext
        )
    }

    /// Start one call through `v`'s coordinator, exactly as `handleInteract` does. `sync` = the host
    /// answers in the same op (synchronous `element_interaction`, not addressable); otherwise the call
    /// stays in flight until `interaction_reply` / `interaction_throw` answers its `call_index`.
    @discardableResult
    func startInteraction(_ v: HostDataStepView, blockId: String, action: String, value: String?,
                          sync: ElementInteractionResult?? = nil) -> InteractionCoordinator.StartOutcome {
        let h = host
        let stepId = v.coordinator.stepId
        let snapshot = v.inputValues
        let index = nextCallIndex
        let isSync = sync != nil
        let syncResult = sync ?? nil
        let outcome = v.coordinator.start(
            blockId: blockId, action: action, value: value,
            pending: pending(v),
            hasDelegate: true, // the scripted host ALWAYS implements onElementInteraction
            call: {
                h.record(stepId: stepId, blockId: blockId, action: action, value: value)
                if isSync { return syncResult }
                return try await h.awaitAnswer(index)
            },
            onReply: { [weak self, weak v] result, seq in
                guard let self, let v else { return }
                self.applyInteractionReply(v, result, seq: seq, snapshot: snapshot)
            }
        )
        if case .started = outcome, !isSync { nextCallIndex += 1 }
        return outcome
    }

    /// `OnboardingStepRouter.applyInteractionReply` — the SAME `InteractionReplyFold`: the four writes,
    /// then one resolve + §B0 prune, then the gated advance.
    func applyInteractionReply(_ v: HostDataStepView, _ result: ElementInteractionResult, seq: Int, snapshot: [String: Any]) {
        InteractionReplyFold.apply(
            result, seq: seq, snapshot: snapshot, stepId: v.step.id, presentation: v.presentation,
            store: store,
            current: .init(inputValues: v.inputValues,
                           fieldConfigOverridesByPresentation: v.fieldConfigOverridesByPresentation,
                           fieldOptionsOverridesByPresentation: v.fieldOptionsOverridesByPresentation),
            commit: { w in
                v.inputValues = w.inputValues
                v.fieldConfigOverridesByPresentation = w.fieldConfigOverridesByPresentation
                v.fieldOptionsOverridesByPresentation = w.fieldOptionsOverridesByPresentation
            },
            // `refresh()` = resolve + clearVanishedSelections (OnboardingStepRouter.resolvedStep +
            // clearVanishedSelections).
            resolveAndPrune: { refresh() },
            // handleBlockAction("next") → advanceCollectingStepData: gate, then complete. Blocked →
            // the step stays.
            advance: {
                if let r = v.resolved,
                   RequiredFieldGate.evaluate(blocks: r.blocks, inputValues: v.inputValues, rawResolvedIds: r.rawResolvedIds).canAdvance {
                    complete(v)
                }
            }
        )
    }

    private func isRefreshButton(_ b: ContentBlock) -> Bool {
        (b.type == .button) && (b.action ?? "next") == "refresh_step"
    }

    /// The existing SYNCHRONOUS op: tap and reply in one step, through the coordinator like any call.
    func elementInteraction(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        refresh()
        let blockId = op["block_id"]?.stringValue ?? ""
        guard let v = view(owning: blockId) ?? view else { failures.append("element_interaction: no step is presented"); return }
        let block = v.findBlock(blockId)
        let action: String
        if let a = op["action"]?.stringValue { action = a }
        else if let b = block, isRefreshButton(b) { action = InteractionCoordinator.refreshAction }
        else { failures.append("element_interaction: 'action' is required for \(blockId), which is not a refresh_step button"); return }
        let value: String? = op.keys.contains("value") ? op["value"]?.stringValue : block?.action_value
        let result = Self.interactionResult(op["result"])
        let outcome = startInteraction(v, blockId: blockId, action: action, value: value, sync: .some(result))
        if case .started = outcome {} else { failures.append("element_interaction on \(blockId) was refused: \(outcome)") }
        await settle()
        refresh()
    }

    /// `tap {block_id}` — a user tap on a rendered `refresh_step` button at any depth.
    func tap(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        refresh()
        let blockId = op["block_id"]?.stringValue ?? ""
        guard let v = view(owning: blockId), let block = v.findBlock(blockId) else {
            failures.append("tap: no rendered block \(blockId)"); return
        }
        guard isRefreshButton(block) else {
            failures.append("tap: \(blockId) is not a refresh_step button (use fire_interaction) — the fixture is invalid"); return
        }
        // The button's own rule (C5.3 / C5.4) — the SAME `StepInteraction` the router provides: a
        // locked button's tap is not a call.
        let channel = StepInteraction.make(presentation: v.presentation, coordinator: v.coordinator, pending: pending(v),
                                           fire: { [weak self, weak v] id, action, value in
                                               guard let self, let v else { return }
                                               self.startInteraction(v, blockId: id, action: action, value: value)
                                           })
        channel.tapRefresh(blockId: blockId, actionValue: block.action_value)
        await settle()
        refresh()
    }

    /// `fire_interaction {block_id, action, value?}` — a generic in-flight interaction.
    func fireInteraction(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        refresh()
        let blockId = op["block_id"]?.stringValue ?? ""
        guard let v = view(owning: blockId) else { failures.append("fire_interaction: no rendered block \(blockId)"); return }
        guard let action = op["action"]?.stringValue else { failures.append("fire_interaction: action is required"); return }
        startInteraction(v, blockId: blockId, action: action, value: op["value"]?.stringValue)
        await settle()
        refresh()
    }

    private func callIndex(_ op: [String: SharedFixtureTests.AnyJSON]) -> Int? {
        if case .int(let i)? = op["call_index"] { return Int(i) }
        if let d = op["call_index"]?.doubleValue { return Int(d) }
        return nextCallIndex > 0 ? nextCallIndex - 1 : nil
    }

    func interactionReply(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        guard let idx = callIndex(op), idx < nextCallIndex else {
            failures.append("interaction_reply: no addressable call \(op["call_index"].map { "\($0)" } ?? "(latest)")"); return
        }
        let result = Self.interactionResult(op["result"])
        if !host.answer(idx, .success(result)) {
            failures.append("interaction_reply: call \(idx) was already answered — the fixture is invalid")
        }
        await settle()
        refresh()
    }

    func interactionThrow(_ op: [String: SharedFixtureTests.AnyJSON]) async {
        guard let idx = callIndex(op), idx < nextCallIndex else {
            failures.append("interaction_throw: no addressable call"); return
        }
        if !host.answer(idx, .failure(ScriptedInteractionHost.HostThrow())) {
            failures.append("interaction_throw: call \(idx) was already answered — the fixture is invalid")
        }
        await settle()
        refresh()
    }

    // MARK: Completion

    /// OnboardingStepRouter.advanceCollectingStepData → OnboardingFlowHost.handleStepCompleted.
    func completeStep() {
        refresh()
        guard let v = view else { return }
        guard let r = v.resolved,
              RequiredFieldGate.evaluate(blocks: r.blocks, inputValues: v.inputValues, rawResolvedIds: r.rawResolvedIds).canAdvance else {
            failures.append("complete_step: the required-field gate blocked the advance"); return
        }
        complete(v)
    }

    /// `complete_step` / an allowed advance. ASSUMPTION: the completion always NAVIGATES — the driver
    /// models no `onBeforeStepAdvance` `.stay` outcome and no server `step.hook`, so the presentation
    /// always ends here (as production's does once `handleStepCompleted` routes on).
    private func complete(_ v: HostDataStepView) {
        var data: [String: Any] = [:]
        for (k, val) in v.toggleValues { data["toggle_\(k)"] = val }
        for (k, val) in v.inputValues { data[k] = val }
        let safe = AuthSecretRedactor.redact(data.isEmpty ? nil : data, in: v.step) ?? [:]
        responsesByStep[v.step.id] = safe
        redactedFieldIds = AuthSecretRedactor.secretFieldIds(in: v.step).sorted()
        for id in redactedFieldIds where safe[id] != nil {
            failures.append("complete_step: secret field \(id) reached the persisted step responses")
        }
        // C10 — a completion (and an allowed advance) ENDS the presentation: the flow host navigates
        // on, exactly as `leave_step` does, but with `responses_step` written.
        if current === v {
            lastLeft = v
            current = nil
            outgoing = nil
            _ = newPresentation()
        }
    }

    // MARK: Observation

    func displayed(_ v: HostDataStepView, _ block: ContentBlock) -> ContentBlock {
        OnboardingStepPipeline.displayBlock(
            block, rawResolved: v.resolved?.isRawResolved(block.id) == true,
            hookData: hookData(v), responses: responses, stepInputs: v.inputValues
        )
    }

    func renderedText(_ id: String) -> Any {
        guard let v = view(owning: id) ?? view, let r = v.resolved else { return NSNull() }
        // An open option sheet renders its blocks through a NESTED renderer: no loc, no hook data,
        // its own (empty) inputs, and — for a raw-resolved Select — the raw-resolved flag.
        // The sheet renderer resolves each TOP-LEVEL sheet block; a nested block (row child) is drawn
        // from its resolved parent via containerChildren → renderBlock(child), so it is looked up
        // inside the displayed top-level block.
        if let sheet = v.openSheet, let owner = v.findBlock(sheet.blockId),
           let opt = owner.field_options?.first(where: { $0.resolvedValue == sheet.value }),
           let sb = opt.sheet_blocks?.first(where: { Self.find(id, in: [$0]) != nil }) {
            let d = OnboardingStepPipeline.displayBlock(sb, rawResolved: r.isRawResolved(owner.id),
                                                        hookData: nil, responses: [:], stepInputs: v.sheetInputs)
            return Self.find(id, in: [d])?.text ?? NSNull()
        }
        guard let b = v.findBlock(id) else { return NSNull() }
        let d = displayed(v, b)
        let tctx = templateContext
        return OnboardingStepPipeline.loc("block.\(b.id).text", d.text ?? "", resolved: r, context: { tctx })
    }

    func blockObservation(_ id: String, spec: [String: SharedFixtureTests.AnyJSON]) -> [String: Any] {
        var out: [String: Any] = [:]
        guard let v = view(owning: id) ?? view, let r = v.resolved else { return out }
        let block = v.findBlock(id)
        let raw = r.isRawResolved(id)
        let d = block.map { displayed(v, $0) }
        let opts = block?.field_options ?? []
        let dOpts = d?.field_options ?? []
        let es = block.flatMap { OnboardingStepPipeline.emptyState($0, rawResolved: raw) }
        for (k, sub) in spec {
            switch k {
            case "rendered_option_values": out[k] = opts.map(\.resolvedValue)
            case "rendered_option_ids": out[k] = opts.map(\.id)
            case "visible_option_values": out[k] = filterOptionsLocally(opts, query: v.searchQueries[id] ?? "").map(\.resolvedValue)
            case "option_labels": out[k] = dOpts.map { $0.label ?? "" }
            case "option_subtitles": out[k] = dOpts.map { $0.subtitle ?? "" }
            case "resolve_state": out[k] = block.flatMap { OnboardingStepPipeline.resolveState($0, rawResolvedIds: r.rawResolvedIds) } ?? NSNull()
            case "empty_state":
                if let es { var m: [String: Any] = ["mode": es.mode]; if let t = es.text { m["text"] = t }; out[k] = m } else { out[k] = NSNull() }
            case "hidden": out[k] = block.map { OnboardingStepPipeline.isHiddenByEmptyState($0, rawResolved: raw) } ?? false
            case "rendered":
                out[k] = block.map { b in
                    !OnboardingStepPipeline.isHiddenByEmptyState(b, rawResolved: raw)
                        && evaluateVisibilityCondition(b.visibility_condition, responses: responses, hookData: hookData(v))
                } ?? false
            case "field_label": out[k] = d?.field_label ?? NSNull()
            case "image_url": out[k] = d?.image_url ?? NSNull()
            case "field_config_has_repeat": out[k] = block?.field_config?["repeat"] != nil
            case "field_config_has_option_set_id": out[k] = block?.field_config?["option_set_id"] != nil
            case "route_polyline_used": out[k] = d.flatMap { mapRoutePolyline($0, rawResolved: raw) } ?? NSNull()
            case "field_config":
                // The LAYERED, RESOLVED field_config — only the listed keys.
                var m: [String: Any] = [:]
                for key in (sub.objectValue ?? [:]).keys { m[key] = block?.field_config?[key]?.value ?? NSNull() }
                out[k] = m
            case "loading":
                out[k] = v.coordinator.loadingBlockId == id
            case "tappable":
                // The locks apply only to refresh buttons (C5.3 / C5.4).
                if let b = block, isRefreshButton(b) {
                    out[k] = StepInteraction.make(presentation: v.presentation, coordinator: v.coordinator,
                                                  pending: pending(v), fire: { _, _, _ in }).refreshTappable
                } else {
                    out[k] = true
                }
            default: failures.append("unknown block observable '\(k)'")
            }
        }
        return out
    }

    func observe(_ expected: [String: SharedFixtureTests.AnyJSON]) -> [String: Any] {
        refresh()
        var out: [String: Any] = [:]
        guard let v = view, let r = v.resolved else { return out }
        for (key, exp) in expected {
            switch key {
            case "pending": out[key] = current.map { pending($0) } ?? false
            case "first_resolve_pending": out[key] = v.firstResolvePending ?? NSNull()
            case "delegate_calls": out[key] = delegate.calls
            case "on_step_viewed_calls": out[key] = onStepViewedCalls
            case "block_ids":
                var ids: [String] = []
                func walk(_ bs: [ContentBlock]) { for b in bs { ids.append(b.id); walk((b.children ?? []) + (b.stack_children ?? [])) } }
                walk(r.blocks)
                out[key] = ids
            case "rendered_text":
                var m: [String: Any] = [:]
                for id in (exp.objectValue ?? [:]).keys { m[id] = renderedText(id) }
                out[key] = m
            case "toggle_values":
                var m: [String: Any] = [:]
                for id in (exp.objectValue ?? [:]).keys { m[id] = v.toggleValues[id] ?? NSNull() }
                out[key] = m
            case "input_values":
                var m: [String: Any] = [:]
                for id in (exp.objectValue ?? [:]).keys { m[id] = v.inputValues[id] ?? NSNull() }
                out[key] = m
            case "selected_option_store":
                let snap = SelectedOptionStore.shared.snapshot
                var m: [String: Any] = [:]
                for id in (exp.objectValue ?? [:]).keys {
                    switch snap[id] {
                    case let one as [String: Any]: m[id] = one["value"] ?? NSNull()
                    case let many as [[String: Any]]: m[id] = many.map { $0["value"] ?? NSNull() }
                    default: m[id] = NSNull()
                    }
                }
                out[key] = m
            case "redacted_field_ids": out[key] = redactedFieldIds
            case "responses_step":
                var m: [String: Any] = [:]
                let rs = responsesByStep[v.step.id]
                for id in (exp.objectValue ?? [:]).keys { m[id] = rs?[id] ?? NSNull() }
                out[key] = m
            case "option_set_queries":
                var m: [String: Any] = [:]
                for id in (exp.objectValue ?? [:]).keys {
                    // The view's `.task(id: optionSetId)` loads + queries the Option Set store iff the
                    // LAYERED block still names a set — read through the view's own accessor.
                    let setId = v.findBlock(id).flatMap { FormInputSelectBlock.optionSetId(of: $0) } ?? ""
                    m[id] = setId.isEmpty ? 0 : 1
                }
                out[key] = m
            case "reverted_keys_logged":
                out[key] = r.revertedKeys.map { ["block_id": $0.blockId, "key_path": $0.keyPath] }
            case "gate":
                let g = RequiredFieldGate.evaluate(blocks: r.blocks, inputValues: v.inputValues, rawResolvedIds: r.rawResolvedIds)
                let toast: Any = g.canAdvance ? NSNull() : (g.blockedByPending ? "loading" : "validation")
                out[key] = ["can_advance": g.canAdvance, "toast_kind": toast] as [String: Any]
            case "blocks":
                var m: [String: Any] = [:]
                for (id, spec) in exp.objectValue ?? [:] {
                    m[id] = blockObservation(id, spec: spec.objectValue ?? [:])
                }
                out[key] = m
            // SPEC-496 §5b C10.
            case "hook_data":
                let eff = hookData(v) ?? [:]
                var m: [String: Any] = [:]
                for k in (exp.objectValue ?? [:]).keys { m[k] = eff[k] ?? NSNull() }
                out[key] = m
            case "interaction_calls":
                out[key] = host.calls
            default:
                failures.append("unknown checkpoint observable '\(key)'")
            }
        }
        return out
    }
}

extension SharedFixtureTests {
    /// SPEC-496 — the umbrella test must not pass vacuously: the host-data corpus is loaded for iOS.
    func testHostDataFixtureCorpusIsLoaded() throws {
        let fixtures = try loadFixtures()
        let resolve = fixtures.filter { $0.action.kind == "resolve_block" }.count
        let scenario = fixtures.filter { $0.action.kind == "host_data_scenario" }.count
        let decode = fixtures.filter { $0.action.kind == "decode_interaction_result" }.count
        XCTAssertGreaterThanOrEqual(resolve, 23, "resolve_block fixtures loaded for iOS")
        // P1 corpus + the §5b C10 fixtures that list ios (the Android-only throw fixture excluded).
        XCTAssertGreaterThanOrEqual(scenario, 23 + 26, "host_data_scenario fixtures loaded for iOS")
        XCTAssertGreaterThanOrEqual(decode, 1, "decode_interaction_result fixture loaded for iOS")
    }
}
