import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// A tap on a row of the themed wheel moves that row into the band and records it, through the column's own tap handler.
/// THE CONTROL: a tap on the row already in the band changes nothing, so a pass is not a handler that moves every tap.
final class DateWheelTapRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    override func tearDown() { host.tearDown(); super.tearDown() }

    /// The tap the column's recognizer delivers, at the middle of the row that reads `text`.
    private func tap(_ text: String, in wheel: WheelScrollView) throws {
        let row = try XCTUnwrap(DateWheelTestHost.all(UILabel.self, in: wheel).first { $0.text == text }, "no row \(text)")
        wheel.tapRow(atY: row.frame.midY)
        host.settle(1.0)
    }

    func testTappingAMonthBelowTheBandSelectsIt() throws {
        let store = DateWheelTestHost.Store()
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: store).view!
        let month = try XCTUnwrap(DateWheelTestHost.wheel("Month", in: view))
        try tap("Jul", in: month)
        XCTAssertEqual(DateWheelTestHost.wheel("Month", in: view)?.accessibilityValue, "Jul")
        XCTAssertEqual(store.inputs["born"] as? String, "2000-07-15")
    }

    func testTappingADayAboveTheBandSelectsIt() throws {
        let store = DateWheelTestHost.Store()
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: store).view!
        let day = try XCTUnwrap(DateWheelTestHost.wheel("Day", in: view))
        try tap("13", in: day)
        XCTAssertEqual(DateWheelTestHost.wheel("Day", in: view)?.accessibilityValue, "13")
        XCTAssertEqual(store.inputs["born"] as? String, "2000-06-13")
    }

    func testTheControlTappingTheBandChangesNothing() throws {
        let store = DateWheelTestHost.Store()
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: store).view!
        let month = try XCTUnwrap(DateWheelTestHost.wheel("Month", in: view))
        try tap("Jun", in: month)
        XCTAssertEqual(DateWheelTestHost.wheel("Month", in: view)?.accessibilityValue, "Jun")
        XCTAssertEqual(store.inputs["born"] as? String, "2000-06-15")
    }
}
