import XCTest
@testable import AppDNASDK

/// SPEC-496 P1 implementation-audit ROUND 2 regressions (iOS): M1 nested sheet blocks resolve their
/// own `sheet_step_paths`, m1 nested §B0-scoped Selects get vanished selections cleared, m2 Segmented
/// default-first when options arrive late, m3 resync never clobbers a non-string answer.
@MainActor
final class HostDataAuditRound2Tests: XCTestCase {

    private func context() -> TemplateContext {
        TemplateContext(userTraits: nil, remoteConfig: { _ in nil }, onboardingResponses: [:],
                        computedData: [:], sessionData: [:], deviceInfo: [:])
    }

    private func block(_ json: String) throws -> ContentBlock {
        try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    // MARK: - M1 — a nested block inside sheet_blocks resolves its own step token / binding

    func testNestedSheetBlockResolvesItsOwnStepTokenAndBinding() async throws {
        SelectedOptionStore.shared.resetForTesting()
        defer { SelectedOptionStore.shared.resetForTesting() }
        let json = """
        { "id": "s", "type": "content", "config": { "content_blocks": [
          { "id": "ls", "type": "input_select", "field_id": "pick", "field_options": [
            { "id": "o1", "value": "o1", "label": "Tour", "sheet_blocks": [
              { "id": "sh_top", "type": "text", "text": "Guests {{step.party_size}}" },
              { "id": "sh_row", "type": "row", "children": [
                { "id": "sh_child", "type": "text", "text": "Total {{step.party_size}}" },
                { "id": "sh_stack", "type": "stack", "stack_children": [
                  { "id": "sh_bound", "type": "text", "text": "authored", "bindings": { "text": "step.party_note" } }
                ] }
              ] }
            ] }
          ] }
        ] } }
        """
        let stepJSON = try JSONDecoder().decode(SharedFixtureTests.AnyJSON.self, from: Data(json.utf8))
        let run = HostDataScenarioRun(fixtureId: "round2-M1", stepJSON: stepJSON, templateContext: context(), responses: [:])
        await run.present([:])
        XCTAssertTrue(run.failures.isEmpty, "\(run.failures)")
        XCTAssertEqual(run.view?.resolved?.isRawResolved("ls"), true, "the Select came out of the raw pass")

        run.view?.openSheet = ("ls", "o1")
        run.view?.sheetInputs = ["party_size": "3", "party_note": "from sheet"]
        XCTAssertEqual(run.renderedText("sh_top") as? String, "Guests 3")
        XCTAssertEqual(run.renderedText("sh_child") as? String, "Total 3",
                       "a row child's own sheet_step_paths token resolves against the sheet's inputs")
        XCTAssertEqual(run.renderedText("sh_bound") as? String, "from sheet",
                       "a stack_children binding at depth 2 applies")
    }

    func testApplySheetStepPathsRecursesButNotIntoANestedOptionSheet() throws {
        let b = try block("""
        { "id": "row", "type": "row", "children": [
          { "id": "c", "type": "text", "text": "Total {{step.n}}",
            "field_config": { "sheet_step_paths": [{ "path": "text", "kind": "token" }] } },
          { "id": "sel", "type": "input_select", "field_id": "x", "field_options": [
            { "id": "o", "value": "o", "label": "O", "sheet_blocks": [
              { "id": "deep", "type": "text", "text": "Deep {{step.n}}",
                "field_config": { "sheet_step_paths": [{ "path": "text", "kind": "token" }] } }
            ] }
          ] }
        ] }
        """)
        let out = OnboardingStepPipeline.applySheetStepPaths(b, stepInputs: ["n": "7"])
        XCTAssertEqual(out.children?.first?.text, "Total 7")
        XCTAssertEqual(out.children?.last?.field_options?.first?.sheet_blocks?.first?.text, "Deep {{step.n}}",
                       "a nested option's sheet resolves against THAT sheet's inputs, when it opens")
        // No paths anywhere → the block is returned untouched (no encode/decode).
        let plain = try block(#"{ "id": "p", "type": "row", "children": [{ "id": "t", "type": "text", "text": "{{step.n}}" }] }"#)
        XCTAssertEqual(OnboardingStepPipeline.applySheetStepPaths(plain, stepInputs: ["n": "7"]).children?.first?.text, "{{step.n}}")
    }

    // MARK: - m1 — a nested §B0-scoped Select gets vanished selections cleared

    func testClearVanishedSelectionsWalksContainerChildren() throws {
        let row = try block("""
        { "id": "row", "type": "row", "children": [
          { "id": "st", "type": "stack", "stack_children": [
            { "id": "sel", "type": "input_select", "field_id": "f", "field_options": [{ "id": "a", "label": "A" }],
              "field_config": { "resolve_state": "scoped" } }
          ] }
        ] }
        """)
        let out = OnboardingStepPipeline.clearVanishedSelections(blocks: [row], rawResolvedIds: ["row", "st", "sel"],
                                                                 inputValues: ["f": "gone", "other": "kept"])
        XCTAssertNil(out.inputValues["f"], "the nested Select's vanished value is dropped")
        XCTAssertEqual(out.inputValues["other"] as? String, "kept")
        XCTAssertEqual(out.changes.map(\.fieldId), ["f"])
        XCTAssertEqual(OnboardingStepPipeline.allStepBlocks([row]).map(\.id), ["row", "st", "sel"])
    }

    func testAllStepBlocksDoesNotDescendIntoSheets() throws {
        let sel = try block("""
        { "id": "sel", "type": "input_select", "field_id": "f", "field_options": [
          { "id": "o", "value": "o", "label": "O", "sheet_blocks": [
            { "id": "inner", "type": "input_select", "field_id": "g", "field_options": [],
              "field_config": { "resolve_state": "empty_in_scope" } }
          ] }
        ] }
        """)
        XCTAssertEqual(OnboardingStepPipeline.allStepBlocks([sel]).map(\.id), ["sel"])
    }

    // MARK: - m2 — Segmented default-first when options appear late

    func testSegmentedDefaultFirstRule() throws {
        let opts = try JSONDecoder().decode([InputOption].self, from: Data(#"[{"id":"a","value":"a","label":"A"},{"id":"b","value":"b","label":"B"}]"#.utf8))
        XCTAssertNil(SegmentedDefault.pick(current: nil, options: []), "pending: no options, nothing picked")
        XCTAssertEqual(SegmentedDefault.pick(current: nil, options: opts), "a", "options arrived: the first is picked")
        XCTAssertEqual(SegmentedDefault.pick(current: "", options: opts), "a")
        XCTAssertNil(SegmentedDefault.pick(current: "b", options: opts), "an existing answer is kept")
        XCTAssertNil(SegmentedDefault.pick(current: 2, options: opts), "a host-set non-string answer is kept")
    }

    // MARK: - m3 — resync leaves an unrecognised value type alone

    func testSelectionResyncLeavesNonStringAnswersAlone() {
        XCTAssertNil(SelectionResync.single(2), "interaction patch [\"plan\": 2] — view state untouched, no \"\" write-back")
        XCTAssertNil(SelectionResync.multi(2))
        XCTAssertNil(SelectionResync.single(["a"]), "a list is not a single-select value")
        XCTAssertEqual(SelectionResync.single(nil), "", "a CLEARED entry resyncs to nothing selected")
        XCTAssertEqual(SelectionResync.multi(nil), [])
        XCTAssertEqual(SelectionResync.multi(""), [])
        XCTAssertEqual(SelectionResync.multi("a"), ["a"])
    }
}
