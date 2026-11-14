import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// #1656 — the date wheel as VOICEOVER reaches it, in a real key window.
///
/// The other wheel tests find a column by its class and call its increment directly. VoiceOver does not: it walks the
/// accessibility tree from the window, stops at the first view that IS an accessibility element, focuses that element and
/// sends the swipe-up/-down as `accessibilityIncrement()` / `accessibilityDecrement()` on it. So this test reaches the
/// columns the same way, which is what catches a column that is drawn but unreachable (hidden behind an element that
/// swallows its children), or a wheel whose ROW labels leak into the tree and make VoiceOver read 31 numbers in turn.
///
/// The simulator runs no VoiceOver and XCUITest has no increment verb, so this is the route to the adjust actions (Rule 25).
final class DateWheelVoiceOverRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    override func tearDown() { host.tearDown(); super.tearDown() }

    /// Every accessibility element under `root`, in VoiceOver's order of discovery: a view that is an element ends the
    /// descent, a hidden subtree is skipped, and an explicit `accessibilityElements` list replaces the subviews.
    private func voiceOverElements(under root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        func walk(_ object: NSObject) {
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden { return }
            if object.isAccessibilityElement { out.append(object); return }
            if let explicit = object.accessibilityElements as? [NSObject] { explicit.forEach(walk); return }
            (object as? UIView)?.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    private func column(_ name: String, in elements: [NSObject]) -> NSObject? {
        elements.first { $0.accessibilityLabel == name && $0.accessibilityTraits.contains(.adjustable) }
    }

    func testVoiceOverReachesEachColumnAndAdjustsItBothWays() throws {
        let store = DateWheelTestHost.Store()
        let window = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2024-02-28"]), store: store).view.window!
        let elements = voiceOverElements(under: window)

        // The walk sees the three columns, and nothing of their rows: a column is itself the element, so VoiceOver never
        // descends into its labels. Were a column ever to stop being an element, its rows ("27", "Mar"…) would surface here
        // one by one, which is what the second assertion catches. (Red-checked: an emptied `accessibilityDecrement` fails
        // the adjust assertions below, so they read the column, not a copy of it.)
        let adjustable = elements.filter { $0.accessibilityTraits.contains(.adjustable) }
        XCTAssertEqual(adjustable.map { $0.accessibilityLabel ?? "" }, ["Month", "Day", "Year"], "en_US order, each reachable")
        XCTAssertFalse(elements.contains { ($0.accessibilityLabel ?? "") == "27" || ($0.accessibilityLabel ?? "") == "Mar" },
                       "a row label leaked into the accessibility tree: \(elements.map { $0.accessibilityLabel ?? "?" })")
        for element in adjustable {
            XCTAssertTrue(window.bounds.intersects(element.accessibilityFrame), "\(element.accessibilityLabel ?? "") is off screen")
        }

        let day = try XCTUnwrap(column("Day", in: elements))
        let month = try XCTUnwrap(column("Month", in: elements))
        XCTAssertEqual(day.accessibilityValue, "28")

        // Swipe up: a leap-year February has a 29th.
        day.accessibilityIncrement(); host.settle(0.5)
        XCTAssertEqual(day.accessibilityValue, "29")
        XCTAssertEqual(store.inputs["born"] as? String, "2024-02-29")

        // Swipe down twice: back past the start value.
        day.accessibilityDecrement(); host.settle(0.5)
        day.accessibilityDecrement(); host.settle(0.5)
        XCTAssertEqual(day.accessibilityValue, "27")
        XCTAssertEqual(store.inputs["born"] as? String, "2024-02-27")

        // The month column, down: February → January keeps the day.
        month.accessibilityDecrement(); host.settle(0.5)
        XCTAssertEqual(month.accessibilityValue, "Jan")
        XCTAssertEqual(store.inputs["born"] as? String, "2024-01-27")
    }

    func testDecrementStopsAtTheFirstRow() throws {
        let store = DateWheelTestHost.Store()
        let window = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2024-01-01"]), store: store).view.window!
        let day = try XCTUnwrap(column("Day", in: voiceOverElements(under: window)))
        day.accessibilityDecrement(); host.settle(0.5)
        XCTAssertEqual(day.accessibilityValue, "1", "a swipe down on the first row stays there")
        XCTAssertEqual(store.inputs["born"] as? String, "2024-01-01")
    }
}
