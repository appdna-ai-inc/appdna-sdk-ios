import Foundation

// SPEC-496 §5b (Phase 1b) — "Show more": `ElementInteractionResult.dataContext` and `refresh_step`.
//
//   HostDataInteractionLayer  the pure per-step interaction data layer: `effective` / `apply` /
//                             `applyBase` (C3). Unit-tested, and the only place the merge rules live.
//   HostDataInteractionStore  the flow-level OWNER (renderer `@StateObject`, router `@ObservedObject`):
//                             the layers, the base stamps, `callSeq`, the current presentation and
//                             one `InteractionCoordinator` per presentation (C3, C5.5).
//   InteractionCoordinator    ONE seam for every onElementInteraction call — the in-flight lock, the
//                             generation token, the `callSeq` draw, the 8 s refresh deadline on an
//                             injectable clock, throw → nil, `loadingBlockId` and `isTappable` (C5).
//                             Production and the fixture drivers use the same class.
//
// Main-thread only, like `HostDataPendingCoordinator`: every caller is a view or the fixture runner on
// the main actor, and replies hop back with `MainActor.run`.

/// One layer entry: a value, or a removal marker, stamped with the `callSeq` its call drew at START.
struct HostDataLayerEntry {
    enum Kind {
        case value(Any)
        case removed
    }
    let kind: Kind
    let stamp: Int

    var isValue: Bool { if case .value = kind { return true }; return false }
}

enum HostDataInteractionLayer {
    typealias Layer = [String: HostDataLayerEntry]

    /// C3 "Effective `hook_data` for step S". Start with the base; each layer entry for k applies only
    /// when k is absent from the base or its stamp is newer than the base's. An applying removal
    /// deletes k; an applying value sets k. A nil base with no applying VALUE entry → nil ("no host
    /// data"), exactly as before P1b.
    static func effective(base: [String: Any]?, baseStamp: Int?, layer: Layer) -> [String: Any]? {
        var out = base ?? [:]
        var hasData = base != nil
        for (k, e) in layer {
            let baseSetsK = base?.keys.contains(k) == true
            guard !baseSetsK || e.stamp > (baseStamp ?? Int.min) else { continue }
            switch e.kind {
            case .removed: out.removeValue(forKey: k)
            case .value(let v):
                out[k] = v
                hasData = true
            }
        }
        return hasData ? out : nil
    }

    /// C3 "Applying an interaction's `dataContext` D to S". The merge is shallow per top-level key:
    /// members not in D are untouched. A key the current base sets, answered by a call that started
    /// BEFORE that base's call, is skipped — a newer `onBeforeStepRender` call already answered it.
    /// `data` must already be normalised by `ElementInteractionResult.decodeDataContext`.
    static func apply(_ data: [String: Any], stamp: Int, base: [String: Any]?, baseStamp: Int?, layer: Layer) -> Layer {
        var out = layer
        for (k, v) in data {
            if base?.keys.contains(k) == true, let bs = baseStamp, stamp < bs { continue }
            out[k] = HostDataLayerEntry(kind: v is NSNull ? .removed : .value(v), stamp: stamp)
        }
        return out
    }

    /// C3 "Applying an `onBeforeStepRender` reply R to S": for each key R sets, layer entries OLDER
    /// than R's call are deleted — deleted, not merely outranked, so a superseded value cannot revive
    /// when a later base omits the key. Keys R does not set keep their entries.
    static func applyBase(_ base: [String: Any]?, baseStamp: Int, layer: Layer) -> Layer {
        guard let base else { return layer }
        var out = layer
        for k in base.keys {
            if let e = out[k], e.stamp < baseStamp { out.removeValue(forKey: k) }
        }
        return out
    }

    /// C3 / §B0 "cached": the layer holds at least one VALUE entry under a key the step references.
    /// Removal markers and unreferenced keys do not count. `"*"` (a bare `hook_data` reference) is
    /// satisfied by any value entry.
    static func hasReferencedValue(_ layer: Layer, referencedKeys: Set<String>) -> Bool {
        guard !referencedKeys.isEmpty else { return false }
        return layer.contains { k, e in e.isValue && (referencedKeys.contains(k) || referencedKeys.contains("*")) }
    }
}

/// C3 — the flow-level owner of the interaction data layer, its stamps and `callSeq`, beside the
/// renderer's `configOverrides` and with exactly its lifetime (one per flow presentation; a dismiss or
/// completion drops it with the flow host).
///
/// A reference type on purpose: a reply that carries only `dataContext` changes no router `@State`, and
/// the router re-resolves, prunes and gates IN THE REPLY'S OWN TURN — a copied value would still hold
/// the pre-reply layer there.
final class HostDataInteractionStore: ObservableObject {
    typealias Schedule = HostDataPendingCoordinator.Schedule

    /// Per step id. Published: a `dataContext`-only reply must re-render the step.
    @Published private(set) var layers: [String: HostDataInteractionLayer.Layer] = [:]
    /// The live `onBeforeStepRender` base for each step (`configOverrides[S]`) and the `callSeq` its
    /// call drew. Written in the same turn as the renderer's `configOverrides[S]`, and read LIVE by the
    /// router — a router copy (or a `fire` closure bound to one) never sees a stale base.
    private var bases: [String: (override: StepConfigOverride, stamp: Int)] = [:]
    /// Per-step memo of the referenced top-level `hook_data` keys (C3 "cached"), scoped to this flow
    /// presentation — it goes away with the store instead of keeping every step's raw JSON for the
    /// process lifetime.
    private var referencedKeysMemo: [String: (raw: [HostJSON], locs: [String: [String: String]]?, keys: Set<String>)] = [:]
    /// One flow-level monotonic counter, drawn at the START of every `onBeforeStepRender` and
    /// `onElementInteraction` call. Only `reset()` resets it.
    private(set) var callSeq = 0
    /// The renderer's `presentationSerial`, written in the SAME transaction that bumps it; `-1` once
    /// the flow completed or was dismissed (never a valid serial).
    private(set) var currentPresentation = 0
    /// Plain, NOT `@Published`: `coordinator(for:)` runs in `OnboardingStepRouter.init`, i.e. during
    /// the renderer's body, and must not publish there.
    private var coordinators: [Int: InteractionCoordinator] = [:]
    let schedule: Schedule?

    init(schedule: Schedule? = nil) {
        self.schedule = schedule
    }

    func nextCallSeq() -> Int {
        callSeq += 1
        return callSeq
    }

    /// C5.5 Lifetime — the get-or-create for a presentation's coordinator. An old serial, or any
    /// serial once the flow finished, gets a DETACHED, always-refusing instance that is not stored.
    func coordinator(for presentation: Int, stepId: String) -> InteractionCoordinator {
        if currentPresentation == -1 || presentation < currentPresentation {
            return InteractionCoordinator(stepId: stepId, presentation: presentation,
                                          isCurrentPresentation: { false }, seqSource: { [weak self] in self?.nextCallSeq() ?? 0 },
                                          schedule: schedule)
        }
        if let c = coordinators[presentation] { return c }
        let c = InteractionCoordinator(
            stepId: stepId, presentation: presentation,
            // Weak: store → dictionary → coordinator → closure → store would otherwise outlive a dismiss.
            isCurrentPresentation: { [weak self] in self?.currentPresentation == presentation },
            seqSource: { [weak self] in self?.nextCallSeq() ?? 0 },
            schedule: schedule
        )
        coordinators[presentation] = c
        return c
    }

    /// Move the current presentation (the renderer's serial bump, or `-1` on completion / dismissal).
    /// Every coordinator of an older serial ends: its lock and loading state are released, its reply
    /// will fail its own arrival check, and it is pruned.
    func setCurrentPresentation(_ p: Int) {
        guard p != currentPresentation else { return }
        currentPresentation = p
        for (serial, c) in coordinators where p == -1 || serial < p {
            c.presentationEnded()
            coordinators.removeValue(forKey: serial)
        }
    }

    /// C3 — an `onBeforeStepRender` reply was written to `configOverrides[stepId]`.
    func recordBase(stepId: String, override: StepConfigOverride, stamp: Int) {
        bases[stepId] = (override, stamp)
        let layer = layers[stepId] ?? [:]
        let next = HostDataInteractionLayer.applyBase(override.dataContext, baseStamp: stamp, layer: layer)
        if next.count != layer.count { layers[stepId] = next }
    }

    /// C4 step 2 — one interaction reply's `dataContext`, stamped with its call's `callSeq`. Every
    /// `dataContext` goes through the core decoder first — including one a native host built.
    func applyInteractionData(stepId: String, dataContext: [String: Any]?, stamp: Int) {
        guard let d = ElementInteractionResult.decodeDataContext(dataContext), !d.isEmpty else { return }
        let base = bases[stepId]
        layers[stepId] = HostDataInteractionLayer.apply(d, stamp: stamp, base: base?.override.dataContext, baseStamp: base?.stamp,
                                                         layer: layers[stepId] ?? [:])
    }

    /// The effective `hook_data` of `stepId` — the ONE map every reader uses (C3). `fallbackBase` is
    /// used only when no base was ever recorded here (a router built without the flow host).
    func effectiveHookData(stepId: String, fallbackBase: [String: Any]?) -> [String: Any]? {
        let b = bases[stepId]
        return HostDataInteractionLayer.effective(
            base: b.map { $0.override.dataContext } ?? fallbackBase,
            baseStamp: b?.stamp,
            layer: layers[stepId] ?? [:]
        )
    }

    func baseStamp(stepId: String) -> Int? { bases[stepId]?.stamp }

    /// The LIVE base override of `stepId` (nil when none was recorded here).
    func baseOverride(stepId: String) -> StepConfigOverride? { bases[stepId]?.override }

    /// C3 — the step's referenced top-level `hook_data` keys, computed once per step content.
    func referencedHookDataKeys(_ step: OnboardingStep) -> Set<String> {
        guard let raw = step.rawContentBlocks else { return [] }
        let locs = step.config.localizations
        if let c = referencedKeysMemo[step.id], c.raw == raw, c.locs == locs { return c.keys }
        let k = HostDataResolver.stepHookDataKeys(raw, localizations: locs)
        referencedKeysMemo[step.id] = (raw, locs, k)
        return k
    }

    /// §B0 / C3 "cached" — the ONE expression the renderer and the fixture driver use: a base for
    /// the step, OR a layer VALUE under a key the step references.
    func isCached(_ step: OnboardingStep, hasBase: Bool) -> Bool {
        hasBase || hasReferencedLayerValue(stepId: step.id, referencedKeys: referencedHookDataKeys(step))
    }

    /// §B0 "cached" (P1b): a layer VALUE under a key the step references.
    func hasReferencedLayerValue(stepId: String, referencedKeys: Set<String>) -> Bool {
        HostDataInteractionLayer.hasReferencedValue(layers[stepId] ?? [:], referencedKeys: referencedKeys)
    }

    /// A new flow presentation: the layer, the stamps and `callSeq` go together, and nothing else
    /// resets them.
    func reset() {
        layers = [:]
        bases = [:]
        referencedKeysMemo = [:]
        callSeq = 0
        for c in coordinators.values { c.presentationEnded() }
        coordinators = [:]
        currentPresentation = 0
    }
}

/// C5 — one presentation's interaction seam. Every `onElementInteraction` call of the presentation
/// (a `refresh_step` tap, an OTP entry, a press-hold confirm…) starts here.
final class InteractionCoordinator: ObservableObject {
    typealias Call = () async throws -> ElementInteractionResult?
    typealias Schedule = HostDataPendingCoordinator.Schedule

    /// C5.5 — a `refresh` call ends at min(reply, 8 s). The same ceiling §D allows the host-data hook.
    static let refreshTimeout: TimeInterval = 8.0
    static let refreshAction = "refresh"

    enum StartOutcome: Equatable {
        case started(seq: Int)
        /// The presentation is no longer the current one (e.g. the outgoing step during the exit
        /// transition). No host call, no `callSeq` draw, no loading state.
        case refusedNotCurrent
        /// Another interaction of this presentation is in flight.
        case refusedInFlight
        /// `refresh_step` while the presentation is §B0-pending.
        case refusedPending
        /// C5.2 — no native `onElementInteraction` handler.
        case noDelegate
    }

    /// The coordinator's OWN step — what the host is told, never the flow's current index.
    let stepId: String
    let presentation: Int
    private let isCurrentPresentation: () -> Bool
    private let seqSource: () -> Int
    private let schedule: Schedule

    /// UI-facing state is `@Published`: with plain fields the spinner would never appear on tap, and
    /// after a nil reply or the deadline it would stay drawn until some unrelated re-render.
    @Published private(set) var inFlight = false
    @Published private(set) var loadingBlockId: String?
    /// A refresh deadline is armed (the call has not ended yet).
    @Published private(set) var refreshDeadlineArmed = false

    private var generation = 0
    private var ended = false
    /// Debug log lines (tests read them). DEBUG builds only, capped — never an unbounded production buffer.
    private(set) var log: [String] = []

    private final class Flight {
        let generation: Int
        let seq: Int
        let isRefresh: Bool
        var finished = false
        var task: Task<Void, Never>?
        var cancelDeadline: (() -> Void)?
        init(generation: Int, seq: Int, isRefresh: Bool) {
            self.generation = generation
            self.seq = seq
            self.isRefresh = isRefresh
        }
    }

    init(stepId: String, presentation: Int, isCurrentPresentation: @escaping () -> Bool,
         seqSource: @escaping () -> Int, schedule: Schedule? = nil) {
        self.stepId = stepId
        self.presentation = presentation
        self.isCurrentPresentation = isCurrentPresentation
        self.seqSource = seqSource
        self.schedule = schedule ?? { seconds, fire in
            let t = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !Task.isCancelled { fire() }
            }
            return { t.cancel() }
        }
    }

    /// C5.3 / C5.4 — may a `refresh_step` button of this presentation be tapped now? Not while ANY
    /// interaction of the presentation is in flight, and not while the presentation is §B0-pending.
    func isTappable(blockId: String, pending: Bool) -> Bool {
        !inFlight && !pending
    }

    private func debug(_ line: String) {
        #if DEBUG
        log.append(line)
        if log.count > 100 { log.removeFirst(log.count - 100) }
        #endif
        Log.debug("[Onboarding] \(line)")
    }

    /// Start one interaction call. `onReply` runs at most once, on the main thread, only for a
    /// non-nil reply of the LATEST call that arrived while this presentation is still current — and
    /// with the `callSeq` the call drew at start.
    @discardableResult
    func start(
        blockId: String,
        action: String,
        value: String?,
        pending: Bool,
        hasDelegate: Bool,
        call: @escaping Call,
        onReply: @escaping (ElementInteractionResult, Int) -> Void
    ) -> StartOutcome {
        let isRefresh = action == Self.refreshAction
        // Evaluated at call START: a call from a presentation that is no longer current is refused.
        guard !ended, isCurrentPresentation() else {
            debug("interaction \(action) on \(blockId) refused: presentation \(presentation) of step \(stepId) is no longer current")
            return .refusedNotCurrent
        }
        guard hasDelegate else {
            debug(isRefresh
                  ? "refresh_step tapped with no onElementInteraction handler"
                  : "interaction \(action) on \(blockId) with no onElementInteraction handler")
            return .noDelegate
        }
        guard !inFlight else {
            debug("interaction \(action) on \(blockId) dropped: another interaction is in flight")
            return .refusedInFlight
        }
        if isRefresh && pending {
            debug("refresh_step on \(blockId) refused: host data is still pending")
            return .refusedPending
        }
        let seq = seqSource()
        generation += 1
        let f = Flight(generation: generation, seq: seq, isRefresh: isRefresh)
        inFlight = true
        loadingBlockId = isRefresh ? blockId : nil
        refreshDeadlineArmed = isRefresh
        f.task = Task { [weak self] in
            // A throw is a nil answer (iOS's delegate is non-throwing; a wrapper bridge answers nil).
            let reply: ElementInteractionResult? = (try? await call()) ?? nil
            await MainActor.run { self?.finish(f, reply: reply, timedOut: false, onReply: onReply) }
        }
        if isRefresh {
            // A timer INDEPENDENT of the host call: a host that never answers still ends at 8 s.
            f.cancelDeadline = schedule(Self.refreshTimeout) { [weak self] in
                self?.finish(f, reply: nil, timedOut: true, onReply: onReply)
            }
        }
        return .started(seq: seq)
    }

    /// Each call ends exactly once: at its reply, a throw, or (refresh only) its deadline.
    private func finish(_ f: Flight, reply: ElementInteractionResult?, timedOut: Bool,
                        onReply: (ElementInteractionResult, Int) -> Void) {
        guard !f.finished else {
            debug("interaction reply for call seq \(f.seq) arrived after the call ended — dropped")
            return
        }
        f.finished = true
        f.cancelDeadline?()
        if timedOut {
            f.task?.cancel()
            debug("refresh call seq \(f.seq) reached its \(Int(Self.refreshTimeout)) s deadline")
        }
        if f.generation == generation {
            inFlight = false
            loadingBlockId = nil
            refreshDeadlineArmed = false
        }
        guard !timedOut, let reply else { return } // nil / throw / deadline → nothing changes
        // Evaluated again at ARRIVAL, before anything is written or `advance` runs.
        guard !ended, isCurrentPresentation(), f.generation == generation else {
            debug("interaction reply for call seq \(f.seq) dropped: presentation \(presentation) of step \(stepId) is no longer current")
            return
        }
        onReply(reply, f.seq)
    }

    /// The presentation ended: release this instance's lock and loading state. The call itself still
    /// ends at its reply, throw or deadline, and that outcome is dropped by the arrival check.
    func presentationEnded() {
        ended = true
        if inFlight { inFlight = false }
        if loadingBlockId != nil { loadingBlockId = nil }
        if refreshDeadlineArmed { refreshDeadlineArmed = false }
    }
}

/// SPEC-496 §5b C4 — the ONE fold of an interaction reply, used by `OnboardingStepRouter` and by the
/// fixture driver alike. The four outputs are computed from the CURRENT state and committed together
/// (`commit` — patches onto the current inputs, the layer, and the two overlays under THIS presentation
/// only), then exactly one re-resolve + §B0 prune (`resolveAndPrune`), then — if asked — the gated
/// advance (`advance`, which runs the gate itself).
///
/// No `inout` on purpose: an `inout` of view state is written back only when the call returns, so the
/// prune and the gate — which read that state — would still see the pre-reply values.
enum InteractionReplyFold {
    struct Writes {
        var inputValues: [String: Any]
        var fieldConfigOverridesByPresentation: [Int: [String: [String: Any]]]
        var fieldOptionsOverridesByPresentation: [Int: [String: [InputOption]]]
    }

    static func apply(
        _ result: ElementInteractionResult,
        seq: Int,
        snapshot: [String: Any],
        stepId: String,
        presentation: Int,
        store: HostDataInteractionStore,
        current: Writes,
        commit: (Writes) -> Void,
        resolveAndPrune: () -> Void,
        advance: () -> Void
    ) {
        let applied = applyInteractionResult(result, inputValues: snapshot)
        var w = current
        // 1. `inputValuePatches` key by key onto the CURRENT values — the tap-time snapshot is only what
        //    the host was sent, and is never written back (a pick made during the call survives).
        for (k, v) in applied.inputValuePatches ?? [:] { w.inputValues[k] = v }
        // 3. + 4. The overlays, under this presentation only; entries for other serials are pruned.
        let fco = mergeFieldConfigOverrides(w.fieldConfigOverridesByPresentation[presentation] ?? [:],
                                            with: applied.fieldConfigOverrides)
        w.fieldConfigOverridesByPresentation = [presentation: fco]
        var fo = w.fieldOptionsOverridesByPresentation[presentation] ?? [:]
        for (blockId, options) in applied.fieldOptionsOverrides { fo[blockId] = options }
        w.fieldOptionsOverridesByPresentation = [presentation: fo]
        // 2. `dataContext` → the step's layer, stamped with the call's `callSeq` — same turn.
        store.applyInteractionData(stepId: stepId, dataContext: applied.dataContext, stamp: seq)
        commit(w)
        // 5. + 6. One re-resolve from the state just written, and the §B0 prune — BEFORE the gate.
        resolveAndPrune()
        // 7. The gated advance.
        if applied.advance { advance() }
    }
}
