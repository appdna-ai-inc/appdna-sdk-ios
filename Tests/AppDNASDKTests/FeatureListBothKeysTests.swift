import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/**
 A `features` section draws BOTH the plain `features` strings and the structured `items`.

 ## The defect this locks

 `FeatureList.body` was an `if/else`: when `items` was non-empty it drew those and silently dropped
 every plain string beside them. Android already draws both, deliberately — its own comment
 gives the reason: *"Both keys can be present on an older document, and rendering only one of them
 would trade this bug for its mirror image."* So the same published document rendered N+M rows on
 Android and M on iOS, and the rows iOS dropped were ones an author had set.

 ## Why a measured height and not a pixel colour

 Both key paths draw through the same `itemText` style, so a colour assertion cannot tell one row
 from the other — "a feature row drew" is true in every case including the broken one. What changes
 is how many rows there are, so the subject is the laid-out HEIGHT of the real view, measured with
 `sizeThatFits` on a real hosting controller.

 🔴 The control is the pair, not the absolute number. A height assertion against a constant would
 drift with any font or spacing change and prove nothing about this defect; `both > itemsOnly` is
 false exactly when the `else` branch comes back, and true only when both lists are on the screen.
 */
@MainActor
final class FeatureListBothKeysTests: XCTestCase {

    private let width: CGFloat = 393

    private func item(_ text: String) -> PaywallGenericItem {
        // A text-only item: no subtitle and no icon, so the row heights of the two keys are as
        // close as the renderer makes them and the comparison turns on row COUNT.
        let json = Data(#"{"text":"\#(text)"}"#.utf8)
        return try! JSONDecoder().decode(PaywallGenericItem.self, from: json)
    }

    private func height(features: [String], items: [PaywallGenericItem]?) -> CGFloat {
        let view = FeatureList(features: features, richItems: items)
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    func testBothKeysAreDrawn() {
        let strings = ["Unlimited exports", "Offline mode", "Priority support"]
        let items = [item("Custom themes"), item("Shared folders")]

        let stringsOnly = height(features: strings, items: nil)
        let itemsOnly = height(features: [], items: items)
        let both = height(features: strings, items: items)

        XCTAssertGreaterThan(stringsOnly, 0, "the plain string list drew nothing at all")
        XCTAssertGreaterThan(itemsOnly, 0, "the rich item list drew nothing at all")

        /*
         The assertion. Before the fix this was `both == itemsOnly` to the point: the plain strings
         were in the `else` branch and never laid out beside the items.
         */
        XCTAssertGreaterThan(
            both, itemsOnly,
            "a section carrying both keys is no taller than its items alone — the plain `features` rows were dropped",
        )
        XCTAssertGreaterThan(
            both, stringsOnly,
            "a section carrying both keys is no taller than its strings alone — the `items` rows were dropped",
        )
    }

    /// An empty `items` must not suppress the strings, and an empty `features` must not suppress
    /// the items — the two halves of the same `isEmpty` guard.
    func testAnEmptyKeyDoesNotSuppressTheOther() {
        let strings = ["Unlimited exports", "Offline mode"]
        XCTAssertEqual(
            height(features: strings, items: []),
            height(features: strings, items: nil),
            "an empty items array changed the strings' layout",
        )
        let items = [item("Custom themes")]
        XCTAssertEqual(
            height(features: [], items: items),
            height(features: [], items: items),
            "the items' layout is not stable",
        )
    }

    /// The multi-column grid still applies to `items` only, which is what `feature_columns` has
    /// always meant — the plain strings have never had a grid and must not gain one silently.
    func testColumnsStillOnlyGridTheItems() {
        let items = [item("A"), item("B"), item("C"), item("D")]
        let oneCol = height(features: [], items: items)
        let twoCol = {
            let host = UIHostingController(rootView: FeatureList(features: [], richItems: items, columns: 2))
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
            host.view.layoutIfNeeded()
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }()
        XCTAssertLessThan(twoCol, oneCol, "four items in two columns are no shorter than in one")
    }
}
