import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 The real `ContentBlockRendererView` draws a Multi-buttons block whose middle child the host-data raw pass
 hid (`empty_state.mode: hidden`), and the buttons on screen are read from the accessibility tree
 (`HostedStep`). The hidden one is not drawn; THE CONTROL: outside a raw-resolved step the marker is
 ignored, so all three are drawn and this harness can see them.
*/
@MainActor
final class MultiButtonsHostDataTests: XCTestCase {
    private func labels(rawResolvedIds: Set<String>) throws -> [String] {
        let json = """
        [{ "id": "mb", "type": "multi_buttons", "children": [
          { "id": "b1", "type": "button", "text": "Answer one", "action": "next" },
          { "id": "b2", "type": "button", "text": "Answer two", "action": "next", "field_config": { "empty_state": { "mode": "hidden" } } },
          { "id": "b3", "type": "button", "text": "Answer three", "action": "next" }
        ] }]
        """
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
        var view = ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
        view.rawResolvedIds = rawResolvedIds
        let hosted = HostedStep(view)
        defer { hosted.close() }
        hosted.spin(0.4)
        return hosted.labels()
    }

    func testAHiddenChildIsNotDrawn() throws {
        let control = try labels(rawResolvedIds: [])
        XCTAssertTrue(control.contains { $0.contains("Answer two") }, "control: all three drawn outside a raw-resolved step: \(control)")
        let hidden = try labels(rawResolvedIds: ["mb", "b1", "b2", "b3"])
        XCTAssertTrue(hidden.contains { $0.contains("Answer one") } && hidden.contains { $0.contains("Answer three") }, "\(hidden)")
        XCTAssertFalse(hidden.contains { $0.contains("Answer two") }, "the hidden child was drawn: \(hidden)")
    }
}
