import XCTest
@testable import AppDNASDK

/// What the presented flow supplies to label an answer no pick was recorded for, read off a decoded
/// flow the way the flow manager hands it over. Synthetic shapes only.
final class FlowOptionRecordsTests: XCTestCase {

    private func flow() throws -> OnboardingFlowConfig {
        let json = """
        {"id":"f","name":"f","version":1,"steps":[{"id":"s1","type":"form",
          "content_blocks":[
            {"id":"sel","type":"input_select","field_id":"goal","field_options":[
              {"id":"lose_weight","label":"Lose weight"},
              {"id":"o2","value":"gain","label":"Gain muscle"},
              {"id":"tmpl","label":"{{hook_data.x}}"}]},
            {"id":"stack","type":"stack","children":[
              {"id":"nest","type":"input_chips","field_id":"tags","field_options":[{"id":"t1","label":"Tag one"}]}]}],
          "config":{"fields":[{"id":"plan","type":"select","label":"Plan","options":[{"id":"pro","label":"Pro"}]}]}}],"settings":{}}
        """
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    func testReadsEveryInputsOptionsByFieldAndStoredValue() throws {
        let records = SelectedOptionStore.optionRecords(of: try flow())
        let goal = try XCTUnwrap(records["goal"] as? [[String: Any]])
        XCTAssertEqual(goal.map { $0["value"] as? String }, ["lose_weight", "gain"], "a template label is left out")
        XCTAssertEqual(goal.map { $0["label"] as? String }, ["Lose weight", "Gain muscle"])
        XCTAssertEqual((records["tags"] as? [[String: Any]])?.first?["label"] as? String, "Tag one")
        XCTAssertEqual((records["plan"] as? [[String: Any]])?.first?["label"] as? String, "Pro")
    }

    func testAFlowSetOnTheStoreLabelsAnAnswerWithNoRecordedPickAndARecordedPickStillWins() throws {
        let store = SelectedOptionStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }
        store.setFlowOptions(try flow())
        // The store writes on a barrier queue; a read after it observes the write.
        XCTAssertEqual(SelectedOptionStore.drawnAnswer(field: "goal", answer: "lose_weight", selected: store.drawingRecords), "Lose weight")
        store.seedForTesting(fieldId: "goal", value: ["value": "lose_weight", "label": "Lose it"])
        XCTAssertEqual(SelectedOptionStore.drawnAnswer(field: "goal", answer: "lose_weight", selected: store.drawingRecords), "Lose it")
    }

    /// Two steps answering one field id with different labels under the same values: each step's own options are kept
    /// under its scoped key, and an answer path naming the step reads them first.
    func testEachStepsOptionsAreKeptUnderItsOwnKeyAndAnAnswerReadsItsOwnStepsLabel() throws {
        let json = """
        {"id":"f","name":"f","version":1,"steps":[
          {"id":"q1","type":"form","content_blocks":[{"id":"a","type":"input_select","field_id":"pick","field_options":[{"id":"a","label":"Alpha first"}]}]},
          {"id":"q2","type":"form","content_blocks":[{"id":"b","type":"input_select","field_id":"pick","field_options":[{"id":"a","label":"Alpha second"}]}]}],"settings":{}}
        """
        let records = SelectedOptionStore.optionRecords(of: try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8)))
        XCTAssertEqual((records["q1/pick"] as? [[String: Any]])?.map { $0["label"] as? String }, ["Alpha first"])
        XCTAssertEqual((records["q2/pick"] as? [[String: Any]])?.map { $0["label"] as? String }, ["Alpha second"])
        // The latest tap was on q2; q1's answer still draws q1's label.
        let selected = SelectedOptionStore.drawingRecords(selected: ["pick": ["value": "a", "label": "Alpha second"]], flowOptions: records)
        XCTAssertEqual(SelectedOptionStore.drawnAnswer(atPath: "responses.q1.pick", answer: "a", selected: selected), "Alpha first")
        XCTAssertEqual(SelectedOptionStore.drawnAnswer(atPath: "responses.q2.pick", answer: "a", selected: selected), "Alpha second")
    }
}
