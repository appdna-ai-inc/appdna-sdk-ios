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
}
