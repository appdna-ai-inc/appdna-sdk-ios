import XCTest
@testable import AppDNASDK

/// SPEC-419 EPIC-11 — pure logic of the interactive-state-contract result application.
/// SPEC-496 §5b C10 "Native unit tests" — the interaction data layer (`effective` / `apply`), the
/// pending-coordinator "cached" latch and the `InteractionCoordinator` seam.
final class InteractionResultTests: XCTestCase {

    func testMergesInputValuePatchesOverExisting() {
        let result = ElementInteractionResult(inputValuePatches: ["name": "Alex", "age": 25])
        let applied = applyInteractionResult(result, inputValues: ["name": "old", "city": "NYC"])
        XCTAssertEqual(applied.inputValues["name"] as? String, "Alex")  // patched
        XCTAssertEqual(applied.inputValues["age"] as? Int, 25)          // added
        XCTAssertEqual(applied.inputValues["city"] as? String, "NYC")   // untouched
        XCTAssertTrue(applied.fieldConfigOverrides.isEmpty)
        XCTAssertFalse(applied.advance)
    }

    func testExposesFieldConfigOverridesAndAdvance() {
        let result = ElementInteractionResult(
            fieldConfigPatches: ["cal": ["selected_days": [1, 2, 3]]],
            advance: true
        )
        let applied = applyInteractionResult(result, inputValues: [:])
        XCTAssertEqual(applied.fieldConfigOverrides["cal"]?["selected_days"] as? [Int], [1, 2, 3])
        XCTAssertTrue(applied.advance)
    }

    func testEmptyResultIsNoOp() {
        let applied = applyInteractionResult(ElementInteractionResult(), inputValues: ["k": "v"])
        XCTAssertEqual(applied.inputValues["k"] as? String, "v")
        XCTAssertTrue(applied.fieldConfigOverrides.isEmpty)
        XCTAssertFalse(applied.advance)
        XCTAssertNil(applied.dataContext)
        XCTAssertNil(applied.inputValuePatches)
    }

    // MARK: - SPEC-496 §5b C2 / C4.1 — pass-through fields

    func testAppliedInteractionPassesDataContextAndRawPatchesThrough() {
        let result = ElementInteractionResult(inputValuePatches: ["x": 1], dataContext: ["recommendations": ["a"]])
        let applied = applyInteractionResult(result, inputValues: ["picked": "c"])
        XCTAssertEqual(applied.dataContext?["recommendations"] as? [String], ["a"])
        // The RAW patches — not the snapshot merge — so the step scope can apply them onto its LIVE
        // values without writing the tap-time snapshot back.
        XCTAssertEqual(applied.inputValuePatches?.count, 1)
        XCTAssertEqual(applied.inputValuePatches?["x"] as? Int, 1)
        XCTAssertNil(applied.inputValuePatches?["picked"])
    }

    func testDataContextIsTheLastInitParameter() {
        // Swift argument order is part of every call; the wrappers' bridges rely on it.
        let r = ElementInteractionResult(fieldConfigPatches: nil, inputValuePatches: nil, fieldOptions: nil,
                                         advance: false, dataContext: ["k": "v"])
        XCTAssertEqual(r.dataContext?["k"] as? String, "v")
    }

    // MARK: - decodeDataContext

    func testDecodeDataContextKeepsJSONKindsAndNullMarkers() throws {
        let json = #"{"dataContext":{"n0":0,"n1":1,"t":true,"f":0.5,"s":"x","gone":null,"list":[{"a":null,"b":[1,false]}],"m":{"k":null}}}"#
        let bridged = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let d = try XCTUnwrap(ElementInteractionResult.decodeDataContext(bridged["dataContext"]))
        XCTAssertEqual(HostJSON(any: d["n0"]), .int(0), "0 stays an integer, never false")
        XCTAssertEqual(HostJSON(any: d["n1"]), .int(1), "1 stays an integer, never true")
        XCTAssertEqual(HostJSON(any: d["t"]), .bool(true))
        XCTAssertEqual(HostJSON(any: d["f"]), .double(0.5))
        XCTAssertTrue(d["gone"] is NSNull, "a top-level null is KEPT as the removal marker")
        XCTAssertEqual(HostJSON(any: d["list"]), .array([.object(["a": .null, "b": .array([.int(1), .bool(false)])])]))
        XCTAssertEqual(HostJSON(any: d["m"]), .object(["k": .null]))
    }

    func testDecodeDataContextNormalisesNativeSwiftValues() throws {
        let boxedNil: String? = nil
        let native: [String: Any] = ["t": true, "i": 1, "d": 2.5, "gone": NSNull(), "boxed": boxedNil as Any,
                                     "nested": ["x": [1, true] as [Any]]]
        let d = try XCTUnwrap(ElementInteractionResult.decodeDataContext(native))
        XCTAssertEqual(HostJSON(any: d["t"]), .bool(true), "a native Bool renders \"true\", like a bridged one")
        XCTAssertEqual(HostJSON(any: d["i"]), .int(1))
        XCTAssertEqual(HostJSON(any: d["d"]), .double(2.5))
        XCTAssertTrue(d["gone"] is NSNull)
        XCTAssertTrue(d["boxed"] is NSNull, "a boxed Optional.none is a removal, like NSNull")
        XCTAssertEqual(HostJSON(any: d["nested"]), .object(["x": .array([.int(1), .bool(true)])]))
        XCTAssertNil(ElementInteractionResult.decodeDataContext("not a map"))
        XCTAssertNil(ElementInteractionResult.decodeDataContext(nil))
    }

    func testMinimumBridgeTimeoutIsEightSecondsForRefreshOnly() {
        XCTAssertEqual(ElementInteractionResult.minimumBridgeTimeout(action: "refresh"), 8.0)
        XCTAssertNil(ElementInteractionResult.minimumBridgeTimeout(action: "otp_entered"))
        XCTAssertNil(ElementInteractionResult.minimumBridgeTimeout(action: "confirmed"))
    }

    // MARK: - §5b C3 — effective / apply

    private func entry(_ v: Any?, _ stamp: Int) -> HostDataLayerEntry {
        HostDataLayerEntry(kind: v.map { HostDataLayerEntry.Kind.value($0) } ?? .removed, stamp: stamp)
    }

    func testEffectiveNilWithoutBaseOrValues() {
        XCTAssertNil(HostDataInteractionLayer.effective(base: nil, baseStamp: nil, layer: [:]))
        XCTAssertNil(HostDataInteractionLayer.effective(base: nil, baseStamp: nil, layer: ["k": entry(nil, 3)]),
                     "only removal markers and no base → no host data")
        XCTAssertEqual(HostDataInteractionLayer.effective(base: nil, baseStamp: nil, layer: ["k": entry("v", 3)])?["k"] as? String, "v")
    }

    func testApplyIsShallowPerTopLevelKey() {
        var layer = HostDataInteractionLayer.apply(["a": "1", "b": "2"], stamp: 2, base: ["c": "base"], baseStamp: 1, layer: [:])
        layer = HostDataInteractionLayer.apply(["a": "3"], stamp: 3, base: ["c": "base"], baseStamp: 1, layer: layer)
        let eff = HostDataInteractionLayer.effective(base: ["c": "base"], baseStamp: 1, layer: layer)
        XCTAssertEqual(eff?["a"] as? String, "3")
        XCTAssertEqual(eff?["b"] as? String, "2", "members not in D are untouched")
        XCTAssertEqual(eff?["c"] as? String, "base")
    }

    func testRemovalThenSet() {
        let base: [String: Any] = ["banner": "Top picks", "recs": ["a"]]
        var layer = HostDataInteractionLayer.apply(["banner": NSNull()], stamp: 2, base: base, baseStamp: 1, layer: [:])
        var eff = HostDataInteractionLayer.effective(base: base, baseStamp: 1, layer: layer)
        XCTAssertNil(eff?["banner"], "null removes the key")
        XCTAssertNotNil(eff?["recs"])
        layer = HostDataInteractionLayer.apply(["banner": "More"], stamp: 3, base: base, baseStamp: 1, layer: layer)
        eff = HostDataInteractionLayer.effective(base: base, baseStamp: 1, layer: layer)
        XCTAssertEqual(eff?["banner"] as? String, "More")
    }

    func testRemovingABaseKeyAndBaseReplyDeletesOlderEntries() {
        // An interaction removes a key the base set…
        let base1: [String: Any] = ["recs": ["a"], "cursor": "p1"]
        var layer = HostDataInteractionLayer.apply(["recs": NSNull(), "cursor": "p2"], stamp: 2, base: base1, baseStamp: 1, layer: [:])
        XCTAssertNil(HostDataInteractionLayer.effective(base: base1, baseStamp: 1, layer: layer)?["recs"])
        // …then a NEWER base sets `recs` again: the older entry is DELETED (not merely outranked),
        // and `cursor` — which the new base does not set — keeps its interaction value.
        let base2: [String: Any] = ["recs": ["x"]]
        layer = HostDataInteractionLayer.applyBase(base2, baseStamp: 4, layer: layer)
        XCTAssertNil(layer["recs"], "a superseded entry is deleted so it cannot revive")
        let eff = HostDataInteractionLayer.effective(base: base2, baseStamp: 4, layer: layer)
        XCTAssertEqual(eff?["recs"] as? [String], ["x"])
        XCTAssertEqual(eff?["cursor"] as? String, "p2")
    }

    func testSkipInteractionReplyOlderThanTheBaseForKeysTheBaseSets() {
        // The interaction's call STARTED (seq 2) before the base's call (seq 3), for a key that base
        // sets → not stored; the effective value stays the base's. A key the base does not set is kept.
        let base: [String: Any] = ["recs": ["base"]]
        let layer = HostDataInteractionLayer.apply(["recs": ["late"], "other": "o"], stamp: 2, base: base, baseStamp: 3, layer: [:])
        XCTAssertNil(layer["recs"], "skipped: a newer onBeforeStepRender call already answered it")
        XCTAssertNotNil(layer["other"])
        let eff = HostDataInteractionLayer.effective(base: base, baseStamp: 3, layer: layer)
        XCTAssertEqual(eff?["recs"] as? [String], ["base"])
        XCTAssertEqual(eff?["other"] as? String, "o")
    }

    func testLaterStartedCallWinsWhateverTheReplyOrder() {
        // Interaction started at seq 5, base re-fire started at seq 4; the interaction lands FIRST.
        var layer = HostDataInteractionLayer.apply(["recs": ["a..l"]], stamp: 5, base: ["recs": ["a..d"]], baseStamp: 1, layer: [:])
        layer = HostDataInteractionLayer.applyBase(["recs": ["a..h"]], baseStamp: 4, layer: layer)
        XCTAssertEqual(HostDataInteractionLayer.effective(base: ["recs": ["a..h"]], baseStamp: 4, layer: layer)?["recs"] as? [String], ["a..l"])
    }

    func testHasReferencedValueIgnoresRemovalsAndUnreferencedKeys() {
        let layer: HostDataInteractionLayer.Layer = ["banner": entry("x", 2), "recs": entry(nil, 3)]
        XCTAssertFalse(HostDataInteractionLayer.hasReferencedValue(layer, referencedKeys: ["recs"]))
        XCTAssertTrue(HostDataInteractionLayer.hasReferencedValue(layer, referencedKeys: ["banner"]))
        XCTAssertTrue(HostDataInteractionLayer.hasReferencedValue(layer, referencedKeys: ["*"]))
        XCTAssertFalse(HostDataInteractionLayer.hasReferencedValue(layer, referencedKeys: []))
    }

    func testStoreAppliesThroughTheCoreDecoder() {
        let store = HostDataInteractionStore()
        store.recordBase(stepId: "s", override: StepConfigOverride(dataContext: ["recs": ["a"]]), stamp: store.nextCallSeq())
        let seq = store.nextCallSeq()
        store.applyInteractionData(stepId: "s", dataContext: ["flag": true, "recs": NSNull()], stamp: seq)
        let eff = store.effectiveHookData(stepId: "s", fallbackBase: nil)
        XCTAssertNil(eff?["recs"])
        XCTAssertEqual(HostJSON(any: eff?["flag"]), .bool(true))
        XCTAssertEqual(store.baseOverride(stepId: "s")?.dataContext?["recs"] as? [String], ["a"],
                       "the LIVE base a stale router copy reads")
        store.reset()
        XCTAssertEqual(store.callSeq, 0)
        XCTAssertNil(store.baseOverride(stepId: "s"))
        XCTAssertNil(store.effectiveHookData(stepId: "s", fallbackBase: nil))
    }

    // MARK: - §5b C3 — "cached" is latched per presentation

    func testPendingCoordinatorLatchesCachedPerPresentation() {
        let c = HostDataPendingCoordinator(schedule: { _, _ in {} })
        XCTAssertTrue(c.isPending(presentation: 1, applies: true, cached: false))
        XCTAssertTrue(c.isPending(presentation: 1, applies: true, cached: true), "the latch holds the first answer")
        XCTAssertFalse(c.isPending(presentation: 2, applies: true, cached: true), "a new serial samples afresh")
    }

    func testPendingCoordinatorHandsTheCallSeqToOnFinish() async {
        let c = HostDataPendingCoordinator(schedule: { _, _ in {} })
        var seqs = 0
        var got: Int?
        c.start(presentation: 1, seq: { seqs += 1; return seqs + 40 }, call: { nil }, onFinish: { _, seq in got = seq })
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(got, 41, "the value drawn at the call's START")
    }

    // MARK: - §5b C5 — InteractionCoordinator

    private final class ManualClock {
        var timers: [(due: Int, fire: () -> Void, id: Int)] = []
        var now = 0
        var nextId = 0
        func schedule(_ s: TimeInterval, _ f: @escaping () -> Void) -> () -> Void {
            let id = nextId; nextId += 1
            timers.append((now + Int(s * 1000), f, id))
            return { [weak self] in self?.timers.removeAll { $0.id == id } }
        }
        func advance(_ ms: Int) {
            now += ms
            let due = timers.filter { $0.due <= now }
            timers.removeAll { $0.due <= now }
            due.forEach { $0.fire() }
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testNoNativeDelegateMakesNoCallShowsNoLoadingAndLogs() {
        var seq = 0
        var called = false
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { true },
                                       seqSource: { seq += 1; return seq }, schedule: { _, _ in {} })
        let outcome = c.start(blockId: "more", action: "refresh", value: nil, pending: false, hasDelegate: false,
                              call: { called = true; return nil }, onReply: { _, _ in XCTFail("no reply") })
        XCTAssertEqual(outcome, .noDelegate)
        XCTAssertFalse(called)
        XCTAssertNil(c.loadingBlockId)
        XCTAssertFalse(c.inFlight)
        XCTAssertEqual(seq, 0)
        XCTAssertTrue(c.log.contains("refresh_step tapped with no onElementInteraction handler"))
    }

    func testRefusedStartDrawsNoCallSeq() {
        var seq = 0
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { false },
                                       seqSource: { seq += 1; return seq }, schedule: { _, _ in {} })
        let outcome = c.start(blockId: "more", action: "refresh", value: nil, pending: false, hasDelegate: true,
                              call: { nil }, onReply: { _, _ in })
        XCTAssertEqual(outcome, .refusedNotCurrent)
        XCTAssertEqual(seq, 0, "a refused start draws no callSeq")
        XCTAssertNil(c.loadingBlockId)
    }

    func testStoreHandsDetachedRefusingCoordinatorForOldOrFinishedSerials() {
        let store = HostDataInteractionStore(schedule: { _, _ in {} })
        store.setCurrentPresentation(3)
        let old = store.coordinator(for: 2, stepId: "s")
        XCTAssertEqual(old.start(blockId: "b", action: "confirmed", value: nil, pending: false, hasDelegate: true,
                                 call: { nil }, onReply: { _, _ in }), .refusedNotCurrent)
        XCTAssertEqual(store.callSeq, 0)
        let cur = store.coordinator(for: 3, stepId: "s")
        XCTAssertTrue(cur === store.coordinator(for: 3, stepId: "s"), "get-or-create returns the same instance")
        store.setCurrentPresentation(-1)
        XCTAssertEqual(cur.start(blockId: "b", action: "confirmed", value: nil, pending: false, hasDelegate: true,
                                 call: { nil }, onReply: { _, _ in }), .refusedNotCurrent, "completion ends every presentation")
    }

    func testRefreshLoadingDeadlineAndLateReplyDropped() async {
        let clock = ManualClock()
        var seq = 0
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { true },
                                       seqSource: { seq += 1; return seq }, schedule: clock.schedule)
        var cont: CheckedContinuation<ElementInteractionResult?, Never>?
        var replies = 0
        let outcome = c.start(blockId: "more", action: "refresh", value: "v", pending: false, hasDelegate: true,
                              call: { await withCheckedContinuation { cont = $0 } }, onReply: { _, _ in replies += 1 })
        XCTAssertEqual(outcome, .started(seq: 1))
        XCTAssertEqual(c.loadingBlockId, "more")
        XCTAssertFalse(c.isTappable(blockId: "more", pending: false))
        await settle()
        clock.advance(7_999)
        XCTAssertTrue(c.inFlight)
        clock.advance(1)
        XCTAssertFalse(c.inFlight, "the 8 s deadline ends the call")
        XCTAssertNil(c.loadingBlockId)
        XCTAssertTrue(c.isTappable(blockId: "more", pending: false))
        cont?.resume(returning: ElementInteractionResult(dataContext: ["k": "late"]))
        await settle()
        XCTAssertEqual(replies, 0, "a reply after the deadline is dropped")
    }

    func testNonRefreshHasNoDeadlineAndLocksRefreshButtons() async {
        let clock = ManualClock()
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { true },
                                       seqSource: { 1 }, schedule: clock.schedule)
        var cont: CheckedContinuation<ElementInteractionResult?, Never>?
        var got: Int?
        c.start(blockId: "otp", action: "otp_entered", value: "1234", pending: false, hasDelegate: true,
                call: { await withCheckedContinuation { cont = $0 } }, onReply: { _, s in got = s })
        XCTAssertNil(c.loadingBlockId, "only the tapped refresh button shows a spinner")
        XCTAssertFalse(c.isTappable(blockId: "more", pending: false), "refresh is locked while ANY interaction is in flight")
        XCTAssertEqual(c.start(blockId: "more", action: "refresh", value: nil, pending: false, hasDelegate: true,
                               call: { nil }, onReply: { _, _ in }), .refusedInFlight)
        await settle()
        clock.advance(60_000)
        XCTAssertTrue(c.inFlight, "no SDK timeout for a non-refresh interaction")
        cont?.resume(returning: ElementInteractionResult(advance: false))
        await settle()
        XCTAssertEqual(got, 1)
        XCTAssertFalse(c.inFlight)
    }

    func testPendingLocksRefreshOnly() {
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { true },
                                       seqSource: { 1 }, schedule: { _, _ in {} })
        XCTAssertFalse(c.isTappable(blockId: "more", pending: true))
        XCTAssertEqual(c.start(blockId: "more", action: "refresh", value: nil, pending: true, hasDelegate: true,
                               call: { nil }, onReply: { _, _ in }), .refusedPending)
        XCTAssertFalse(c.inFlight)
    }

    func testThrowingHostIsANilAnswer() async {
        struct Boom: Error {}
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { true },
                                       seqSource: { 1 }, schedule: { _, _ in {} })
        var replies = 0
        c.start(blockId: "more", action: "refresh", value: nil, pending: false, hasDelegate: true,
                call: { throw Boom() }, onReply: { _, _ in replies += 1 })
        await settle()
        XCTAssertEqual(replies, 0)
        XCTAssertFalse(c.inFlight)
        XCTAssertNil(c.loadingBlockId)
    }

    func testReplyAfterPresentationEndedIsDroppedAndLockReleased() async {
        var current = true
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { current },
                                       seqSource: { 1 }, schedule: { _, _ in {} })
        var cont: CheckedContinuation<ElementInteractionResult?, Never>?
        var replies = 0
        c.start(blockId: "hold", action: "confirmed", value: nil, pending: false, hasDelegate: true,
                call: { await withCheckedContinuation { cont = $0 } }, onReply: { _, _ in replies += 1 })
        await settle()
        current = false
        c.presentationEnded()
        XCTAssertFalse(c.inFlight, "presentation end releases the lock")
        cont?.resume(returning: ElementInteractionResult(advance: true))
        await settle()
        XCTAssertEqual(replies, 0, "a late advance never runs")
    }

    // MARK: - Audit round 1 minors

    func testStaleFireReadsTheLiveBase() {
        // A fold run through an OLD router copy (whose copied `configOverride` is nil) must still see the
        // base the flow host recorded since — through the router's own resolution helper.
        let store = HostDataInteractionStore(schedule: { _, _ in {} })
        XCTAssertEqual(OnboardingStepRouter.liveOverride(store: store, stepId: "s",
                                                         copied: StepConfigOverride(dataContext: ["recs": ["copy"]]))?
                        .dataContext?["recs"] as? [String], ["copy"], "no base recorded → the copy")
        store.recordBase(stepId: "s", override: StepConfigOverride(dataContext: ["recs": ["new"]]), stamp: store.nextCallSeq())
        XCTAssertEqual(OnboardingStepRouter.liveOverride(store: store, stepId: "s", copied: nil)?.dataContext?["recs"] as? [String], ["new"])
    }

    func testStaleRouterCopyReadsPendingLive() {
        // The copy was built while pending; pending has since ended for its serial.
        let c = HostDataPendingCoordinator(schedule: { _, _ in {} })
        XCTAssertTrue(c.isPending(presentation: 1, applies: true, cached: false))
        let provider = { c.isPending(presentation: 1, applies: true, cached: false) }
        XCTAssertTrue(OnboardingStepRouter.livePending(provider: provider, copied: true))
        // Deterministic: fulfilled by the coordinator's own finish, which ends pending first.
        let exp = expectation(description: "pending ends")
        c.start(presentation: 1, call: { nil }, onFinish: { _, _ in exp.fulfill() })
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(OnboardingStepRouter.livePending(provider: provider, copied: true), "the stale copied `true` is not used")
        XCTAssertTrue(OnboardingStepRouter.livePending(provider: nil, copied: true))
    }

    func testFoldCommitsBeforePruneAndGateAndKeepsCurrentPicks() {
        let store = HostDataInteractionStore(schedule: { _, _ in {} })
        var committed: InteractionReplyFold.Writes?
        var order: [String] = []
        InteractionReplyFold.apply(
            ElementInteractionResult(fieldConfigPatches: ["b": ["k": 1]], inputValuePatches: ["other": "x"], advance: true,
                                     dataContext: ["recs": ["a"]]),
            seq: 2, snapshot: ["pick": "old"], stepId: "s", presentation: 5, store: store,
            current: .init(inputValues: ["pick": "c"],
                           fieldConfigOverridesByPresentation: [4: ["stale": ["k": 0]]],
                           fieldOptionsOverridesByPresentation: [:]),
            commit: { committed = $0; order.append("commit") },
            resolveAndPrune: { order.append("prune") },
            advance: { order.append("advance") }
        )
        XCTAssertEqual(order, ["commit", "prune", "advance"])
        XCTAssertEqual(committed?.inputValues["pick"] as? String, "c", "a pick made during the call survives")
        XCTAssertEqual(committed?.inputValues["other"] as? String, "x")
        XCTAssertEqual(committed.map { Array($0.fieldConfigOverridesByPresentation.keys) }, [5], "other serials pruned")
        XCTAssertEqual(store.effectiveHookData(stepId: "s", fallbackBase: nil)?["recs"] as? [String], ["a"])
    }

    func testTapRefreshRuleIsShared() {
        let c = InteractionCoordinator(stepId: "s", presentation: 1, isCurrentPresentation: { true },
                                       seqSource: { 1 }, schedule: { _, _ in {} })
        var fired: [String] = []
        let locked = StepInteraction.make(presentation: 1, coordinator: c, pending: true, fire: { id, a, v in fired.append("\(id)|\(a)|\(v ?? "")") })
        XCTAssertFalse(locked.tapRefresh(blockId: "more", actionValue: "v"))
        let open = StepInteraction.make(presentation: 1, coordinator: c, pending: false, fire: { id, a, v in fired.append("\(id)|\(a)|\(v ?? "")") })
        XCTAssertTrue(open.tapRefresh(blockId: "more", actionValue: "v"))
        XCTAssertEqual(fired, ["more|refresh|v"])
    }

    func testCachedIsEvaluatedOnlyUntilLatched() {
        let c = HostDataPendingCoordinator(schedule: { _, _ in {} })
        var evaluations = 0
        func cached() -> Bool { evaluations += 1; return false }
        _ = c.isPending(presentation: 1, applies: true, cached: cached())
        _ = c.isPending(presentation: 1, applies: true, cached: cached())
        _ = c.isPending(presentation: 1, applies: true, cached: cached())
        XCTAssertEqual(evaluations, 1, "the referenced-keys walk runs once per presentation")
    }

    func testPendingProviderBindsTheRoutersOwnSerial() {
        let c = HostDataPendingCoordinator(schedule: { _, _ in {} })
        // Serial N is pending (first arrival); the router for N gets its provider.
        XCTAssertTrue(c.isPending(presentation: 1, applies: true, cached: false))
        let providerN = OnboardingFlowHost.pendingProvider(coordinator: c, serial: 1, applies: true)
        XCTAssertTrue(providerN())
        // Serial N+1 arrives and ENDS its pending phase.
        XCTAssertTrue(c.isPending(presentation: 2, applies: true, cached: false))
        // Deterministic: fulfilled by the coordinator's own finish, which ends pending first.
        let exp = expectation(description: "N+1 ends")
        c.start(presentation: 2, call: { nil }, onFinish: { _, _ in exp.fulfill() })
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(OnboardingFlowHost.pendingProvider(coordinator: c, serial: 2, applies: true)())
        XCTAssertTrue(providerN(), "serial N's provider is unchanged — its own serial is bound, not the live one")
        // `applies` is captured: a non-applying step is never pending, whatever the serial.
        XCTAssertFalse(OnboardingFlowHost.pendingProvider(coordinator: c, serial: 1, applies: false)())
    }
}
