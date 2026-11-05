import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 OPERATES the real `rating` block inside `ContentBlockRendererView` through the accessibility tree
 (`HostedStep`): VoiceOver's adjust action sets the rating, and the answer must land in the step's
 `inputValues` at `field_id`, as on Android. THE CONTROL: before any adjustment nothing is stored, and the
 element reads "0 of 5 stars", so the harness sees the block.
*/
@MainActor
final class RatingBlockStoresAnswerTests: XCTestCase {
    private final class Store { var values: [String: Any] = [:] }

    func testAdjustingTheRatingStoresItAtFieldId() throws {
        let json = #"[{ "id": "r1", "type": "rating", "max_stars": 5, "field_id": "satisfaction" }]"#
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
        let store = Store()
        let binding = Binding<[String: Any]>(get: { store.values }, set: { store.values = $0 })
        let hosted = HostedStep(ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: binding))
        defer { hosted.close() }
        hosted.spin(0.4)

        let rating = try XCTUnwrap(hosted.elements().first { ($0.accessibilityValue ?? "").contains("of 5 stars") },
                                   "no rating element; labels: \(hosted.labels())")
        XCTAssertNil(store.values["satisfaction"], "control: nothing stored before the user rates")
        rating.accessibilityIncrement()
        hosted.spin(0.2)
        rating.accessibilityIncrement()
        hosted.spin(0.2)
        XCTAssertEqual(store.values["satisfaction"] as? Double, 2, "stored: \(store.values)")
    }
}
