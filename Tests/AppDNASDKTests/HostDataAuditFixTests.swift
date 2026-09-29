import XCTest
@testable import AppDNASDK

/// SPEC-496 P1 implementation-audit regressions (iOS): M1 step view on a superseded call, m1
/// self-route presentation, m2 chips/segmented resync, m3 repeat.max clamp, m4 single resolution of
/// host / interaction options, m5 memo key, and `fieldConfigPatches` through the structural walker.
@MainActor
final class HostDataAuditFixTests: XCTestCase {

    // MARK: - Helpers

    private func step(_ json: String) throws -> OnboardingStep {
        try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
    }

    private func options(_ json: String) throws -> [InputOption] {
        try JSONDecoder().decode([InputOption].self, from: Data(json.utf8))
    }

    private func context(remote: String = "R") -> TemplateContext {
        TemplateContext(userTraits: nil, remoteConfig: { _ in remote }, onboardingResponses: [:],
                        computedData: [:], sessionData: [:], deviceInfo: [:])
    }

    private func input(_ s: OnboardingStep, override: StepConfigOverride? = nil, pending: Bool = false,
                       tctx: TemplateContext? = nil,
                       fco: [String: [String: Any]] = [:], fo: [String: [InputOption]] = [:]) -> OnboardingStepPipeline.Input {
        OnboardingStepPipeline.Input(
            step: s, override: override, pending: pending, inputValues: [:], responses: [:],
            templateContext: tctx ?? context(), selected: [:],
            fieldConfigOverrides: fco, fieldOptionsOverrides: fo
        )
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - M1 — the step view does not depend on being the latest generation

    func testStepViewFiresForAStepLeftBeforeTheDelegateReplied() async {
        let clock = HostDataManualClock()
        let coordinator = HostDataPendingCoordinator(schedule: { s, f in clock.add(s, f) })
        let host = ScriptedStepRenderDelegate()
        var viewed: [String] = []
        var applied: [String] = []

        // Step A presented; its delegate call is in flight.
        coordinator.start(presentation: 1, call: { await host.call() },
                          onSettled: { viewed.append("A") }, onFinish: { _, _ in applied.append("A") })
        await settle()
        // The user leaves for step B before A's reply: B's start bumps the generation.
        coordinator.start(presentation: 2, call: { nil },
                          onSettled: { viewed.append("B") }, onFinish: { _, _ in applied.append("B") })
        await settle()
        XCTAssertEqual(viewed, ["B"])

        // A's (now superseded) reply lands.
        XCTAssertTrue(host.reply(StepConfigOverride(dataContext: ["x": 1])))
        await settle()
        XCTAssertEqual(viewed.sorted(), ["A", "B"], "step A was viewed — onboarding_step_viewed must fire for it")
        XCTAssertEqual(applied, ["B"], "a superseded reply must not end pending / apply its override")
        XCTAssertFalse(coordinator.endedPresentations.contains(1))
        XCTAssertTrue(coordinator.endedPresentations.contains(2))
    }

    func testStepViewFiresAtTheDeadlineForASupersededNonCooperativeCall() async {
        let clock = HostDataManualClock()
        let coordinator = HostDataPendingCoordinator(schedule: { s, f in clock.add(s, f) })
        let host = ScriptedStepRenderDelegate() // never replied to
        var viewed = 0
        coordinator.start(presentation: 1, call: { await host.call() }, onSettled: { viewed += 1 }, onFinish: { _, _ in })
        await settle()
        coordinator.start(presentation: 2, call: { await host.call() }, onSettled: { viewed += 1 }, onFinish: { _, _ in })
        await settle()
        XCTAssertEqual(viewed, 0)
        clock.advance(3000)
        await settle()
        XCTAssertEqual(viewed, 2, "both step views counted once, at their deadlines")
        XCTAssertTrue(coordinator.endedPresentations.contains(2))
        XCTAssertFalse(coordinator.endedPresentations.contains(1))
    }

    func testCancelledCallCountsTheStepViewExactlyOnceViaTheRefire() async {
        let clock = HostDataManualClock()
        let coordinator = HostDataPendingCoordinator(schedule: { s, f in clock.add(s, f) })
        let host = ScriptedStepRenderDelegate()
        var viewed = 0
        coordinator.start(presentation: 1, call: { await host.call() }, onSettled: { viewed += 1 }, onFinish: { _, _ in })
        await settle()
        coordinator.cancelInFlight()
        await settle()
        XCTAssertEqual(viewed, 0, "a cancelled call is not a step view")
        XCTAssertEqual(host.calls, 2, "re-fired once")
        XCTAssertTrue(host.reply(nil))
        await settle()
        XCTAssertEqual(viewed, 1)
        clock.advance(10_000)
        await settle()
        XCTAssertEqual(viewed, 1, "the cancelled call's deadline never counts a second view")
    }

    // MARK: - m1 — a self-route is not a new presentation

    func testSelfRouteKeepsThePresentation() {
        XCTAssertEqual(OnboardingPresentation.serial(4, from: 2, to: 2), 4)
        XCTAssertEqual(OnboardingPresentation.serial(4, from: 2, to: 3), 5)
        XCTAssertEqual(OnboardingPresentation.serial(4, from: 3, to: 1), 5)
        // The pending state machine: a presentation that got no new call stays ended.
        let coordinator = HostDataPendingCoordinator(schedule: { _, _ in {} })
        XCTAssertTrue(coordinator.isPending(presentation: OnboardingPresentation.serial(0, from: 0, to: 0), applies: true, cached: false))
    }

    // MARK: - m2 — chips / segmented follow a pruned selection

    func testSelectionResyncFollowsInputValues() {
        XCTAssertEqual(SelectionResync.multi(["a", "c"]), ["a", "c"])
        XCTAssertEqual(SelectionResync.multi(nil), [], "the step cleared the whole selection")
        XCTAssertEqual(SelectionResync.single(nil), "")
        XCTAssertEqual(SelectionResync.single("b"), "b")
        // The prune that drives it: a chips value no longer rendered is dropped from inputValues.
        let blocks = [try! JSONDecoder().decode(ContentBlock.self, from: Data("""
        { "id": "c1", "type": "input_chips", "field_id": "f", "field_options": [{ "id": "a", "label": "A" }],
          "field_config": { "resolve_state": "scoped" } }
        """.utf8))]
        let out = OnboardingStepPipeline.clearVanishedSelections(blocks: blocks, rawResolvedIds: ["c1"], inputValues: ["f": ["a", "gone"]])
        XCTAssertEqual(SelectionResync.multi(out.inputValues["f"]), ["a"])
        XCTAssertNotEqual(selectionSignature(["a", "gone"]), selectionSignature(out.inputValues["f"]), "the view's onChange fires")
    }

    // MARK: - m3 — repeat.max is clamped before Int conversion

    func testHugeRepeatMaxDoesNotTrap() {
        let items: [HostJSON] = (0..<60).map { .object(["id": .string("w\($0)"), "name": .string("W\($0)")]) }
        let raw: HostJSON = .object([
            "id": .string("sel"), "type": .string("input_select"), "field_id": .string("f"),
            "field_options": .array([.object([
                "id": .string("t"), "label": .string("fallback"), "value": .string("v"),
                "data_templates": .object(["label": .string("{{item.name}}"), "value": .string("{{item.id}}")]),
            ])]),
            "field_config": .object(["repeat": .object([
                "source": .string("hook_data.list"), "template_option_id": .string("t"), "max": .double(1e30),
            ])]),
        ])
        var ctx = HostDataContext()
        ctx.hookData = .object(["list": .array(items)])
        let r = HostDataResolver.resolveRawBlock(raw, ctx)
        XCTAssertEqual(r.block.objectValue?["field_options"]?.arrayValue?.count, HostDataResolver.repeatHardMax)
    }

    // MARK: - m4 — host / interaction option text is resolved exactly once

    private let skippedSelectStep = """
    { "id": "s1", "type": "custom", "config": { "content_blocks": [
      { "id": "sel", "type": "input_select", "field_id": "f", "field_options": [{ "id": "o", "label": "Static" }] },
      { "id": "t", "type": "text", "text": "Hi {{hook_data.name}}" }
    ] } }
    """

    func testInteractionOptionsOnASkippedBlockAreResolvedOnlyByTheViewPass() throws {
        let s = try step(skippedSelectStep)
        let opts = try options(#"[{ "id": "n1", "label": "{{hook_data.a}}", "value": "n1" }]"#)
        let override = StepConfigOverride(dataContext: ["a": "{{hook_data.b}}", "b": "SECOND"])
        let r = OnboardingStepPipeline.resolve(input(s, override: override, fo: ["sel": opts]))
        XCTAssertFalse(r.isRawResolved("sel"), "precondition: the Select took the skip rule")
        let sel = try XCTUnwrap(r.blocks.first { $0.id == "sel" })
        XCTAssertEqual(sel.field_options?.first?.label, "{{hook_data.a}}", "the pipeline leaves it to the view pass")
        let shown = OnboardingStepPipeline.displayBlock(sel, rawResolved: false, hookData: override.dataContext,
                                                        responses: [:], stepInputs: [:])
        XCTAssertEqual(shown.field_options?.first?.label, "{{hook_data.b}}", "one pass: a substituted value is never re-scanned")
    }

    func testHostFieldOptionsOnARawBlockAreResolvedOnlyByThePipeline() throws {
        let s = try step("""
        { "id": "s2", "type": "custom", "config": { "content_blocks": [
          { "id": "sel", "type": "input_select", "field_id": "f", "field_label": "{{hook_data.title}}",
            "field_options": [{ "id": "o", "label": "Static" }] }
        ] } }
        """)
        let opts = try options(#"[{ "id": "n1", "label": "{{hook_data.a}}", "value": "n1" }]"#)
        let override = StepConfigOverride(fieldOptions: ["sel": opts], dataContext: ["a": "{{hook_data.b}}", "b": "SECOND", "title": "T"])
        let r = OnboardingStepPipeline.resolve(input(s, override: override))
        XCTAssertTrue(r.isRawResolved("sel"))
        let sel = try XCTUnwrap(r.blocks.first { $0.id == "sel" })
        let shown = OnboardingStepPipeline.displayBlock(sel, rawResolved: true, hookData: override.dataContext,
                                                        responses: [:], stepInputs: [:])
        XCTAssertEqual(shown.field_options?.first?.label, "{{hook_data.b}}")
    }

    // MARK: - m5 — the memo key covers raw content and legacy roots

    func testMemoRecomputesWhenRawContentChangesAtTheSameCount() throws {
        let memo = OnboardingStepPipelineMemo()
        let a = try step(#"{ "id": "s", "type": "custom", "config": { "content_blocks": [{ "id": "t", "type": "text", "text": "A {{hook_data.x}}" }] } }"#)
        let b = try step(#"{ "id": "s", "type": "custom", "config": { "content_blocks": [{ "id": "t", "type": "text", "text": "B {{hook_data.x}}" }] } }"#)
        let o = StepConfigOverride(dataContext: ["x": "1"])
        XCTAssertEqual(memo.resolve(input(a, override: o)).blocks.first?.text, "A 1")
        XCTAssertEqual(memo.resolve(input(b, override: o)).blocks.first?.text, "B 1")
    }

    func testMemoRecomputesWhenALegacyRootValueChanges() throws {
        let memo = OnboardingStepPipelineMemo()
        let s = try step(#"{ "id": "s", "type": "custom", "config": { "content_blocks": [{ "id": "t", "type": "text", "text": "Plan {{remote_config.plan}}" }] } }"#)
        XCTAssertEqual(memo.resolve(input(s, tctx: context(remote: "gold"))).blocks.first?.text, "Plan gold")
        XCTAssertEqual(memo.resolve(input(s, tctx: context(remote: "silver"))).blocks.first?.text, "Plan silver")
        XCTAssertEqual(memo.resolve(input(s, tctx: context(remote: "silver"))).blocks.first?.text, "Plan silver")
    }

    // MARK: - §A4 — fieldConfigPatches go through the structural walker

    func testFieldConfigPatchAppliesTheUrlRuleAndDropsMarkers() throws {
        let s = try step(skippedSelectStep.replacingOccurrences(of: "\"Static\"", with: "\"{{hook_data.l | L}}\""))
        let patch: [String: Any] = [
            "caption": "Hello {{hook_data.name}}",
            "hero_image_url": "{{hook_data.missing}}",
            "badge_image_url": "{{hook_data.rel}}",
            "icon_url": "{{hook_data.good}}",
            "resolve_state": "empty_in_scope",
            "repeat": ["source": "hook_data.list"],
        ]
        let override = StepConfigOverride(dataContext: ["name": "Ann", "rel": "/relative.png", "good": "https://cdn.example.com/i.png"])
        let r = OnboardingStepPipeline.resolve(input(s, override: override, fco: ["sel": patch]))
        let fc = try XCTUnwrap(r.blocks.first { $0.id == "sel" }?.field_config)
        XCTAssertEqual(fc["caption"]?.value as? String, "Hello Ann")
        XCTAssertNil(fc["hero_image_url"], "unresolved URL → not applied")
        XCTAssertNil(fc["badge_image_url"], "relative URL → not applied (§A6)")
        XCTAssertEqual(fc["icon_url"]?.value as? String, "https://cdn.example.com/i.png")
        XCTAssertNil(fc["resolve_state"])
        XCTAssertNil(fc["repeat"])
    }
}
