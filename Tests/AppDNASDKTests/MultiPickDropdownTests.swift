import XCTest
@testable import AppDNASDK

/// A dropdown-style Select with `multi_select`: what its field draws, and the write each pick makes.
/// The shared fixtures (`dropdown_multi_pick_*`) drive the same seam through a whole step; these pin the
/// field's text and the seam's answer for a single dropdown, which must not change.
final class MultiPickDropdownTests: XCTestCase {
    private func block(multi: Bool, maxSelections: Int? = nil) throws -> ContentBlock {
        var fc: [String: Any] = [:]
        if let m = maxSelections { fc["max_selections"] = m }
        let json: [String: Any] = [
            "id": "m", "type": "input_select", "field_id": "fav", "multi_select": multi, "field_config": fc,
            "field_options": [
                ["id": "a", "value": "a", "label": "Alpha"],
                ["id": "b", "value": "b", "label": "Bravo"],
            ],
        ]
        return try JSONDecoder().decode(ContentBlock.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testTheFieldDrawsThePicksInPickOrderOrThePlaceholder() throws {
        let options = try block(multi: true).field_options ?? []
        XCTAssertEqual(DropdownSelectPick.multiLabel(drawn: [], options: options, placeholder: "Pick some").text, "Pick some")
        XCTAssertTrue(DropdownSelectPick.multiLabel(drawn: [], options: options, placeholder: "Pick some").isPlaceholder)
        XCTAssertEqual(DropdownSelectPick.multiLabel(drawn: ["b", "a"], options: options, placeholder: "x").text, "Bravo, Alpha")
        XCTAssertEqual(DropdownSelectPick.multiLabel(drawn: ["zz"], options: options, placeholder: "x").text, "zz")
    }

    func testAMultiPickTogglesAListAndRecordsTheOptionsInPickOrder() throws {
        let b = try block(multi: true)
        let options = b.field_options ?? []
        let store = SelectedOptionStore()
        var iv: [String: Any] = [:]
        _ = DropdownSelectPick.apply(value: "b", options: options, block: b, selectedValues: [], inputValues: &iv, store: store)
        _ = DropdownSelectPick.apply(value: "a", options: options, block: b, selectedValues: ["b"], inputValues: &iv, store: store)
        XCTAssertEqual(iv["fav"] as? [String], ["b", "a"])
        let recorded = (store.snapshot["fav"] as? [[String: Any]])?.compactMap { $0["label"] as? String }
        XCTAssertEqual(recorded, ["Bravo", "Alpha"])
        _ = DropdownSelectPick.apply(value: "b", options: options, block: b, selectedValues: ["b", "a"], inputValues: &iv, store: store)
        XCTAssertEqual(iv["fav"] as? [String], ["a"])
    }

    func testAMultiPickRefusesAnAddPastMaxSelections() throws {
        let b = try block(multi: true, maxSelections: 1)
        let options = b.field_options ?? []
        let store = SelectedOptionStore()
        var iv: [String: Any] = ["fav": ["a"]]
        let sheet = DropdownSelectPick.apply(value: "b", options: options, block: b, selectedValues: ["a"], inputValues: &iv, store: store)
        XCTAssertNil(sheet)
        XCTAssertEqual(iv["fav"] as? [String], ["a"])
    }

    /// Negative control: a single dropdown still stores one value.
    func testASingleDropdownStoresOneValue() throws {
        let b = try block(multi: false)
        var iv: [String: Any] = [:]
        _ = DropdownSelectPick.apply(value: "b", options: b.field_options ?? [], block: b, inputValues: &iv, store: SelectedOptionStore())
        XCTAssertEqual(iv["fav"] as? String, "b")
    }
}
