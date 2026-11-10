import SwiftUI
import XCTest
@testable import AppDNASDK

/// What the real date block stores, and what it shows when the user comes back to it. A date-only answer is the calendar
/// date on the wheel, `yyyy-MM-dd`, whatever the phone's time zone; the zones themselves are pinned by the shared fixture.
/// THE CONTROL: a datetime answer is still a moment, so a pass is not a block that stopped writing times.
final class DateWheelAnswerRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    override func tearDown() { host.tearDown(); super.tearDown() }

    private func zoned(_ id: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: id)!
        return calendar
    }

    func testADateIsStoredAsTheDayOnTheWheel() throws {
        let store = DateWheelTestHost.Store()
        _ = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: store)
        XCTAssertEqual(store.inputs["born"] as? String, "2000-06-15")
    }

    func testAStepIncreaseStoresTheNextDay() throws {
        let store = DateWheelTestHost.Store()
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2024-02-28"]), store: store).view!
        try XCTUnwrap(DateWheelTestHost.wheel("Day", in: view)).accessibilityIncrement()
        host.settle(0.5)
        XCTAssertEqual(store.inputs["born"] as? String, "2024-02-29")
    }

    func testAStoredDateIsShownOnReturn() throws {
        let store = DateWheelTestHost.Store()
        store.inputs["born"] = "2003-02-28"
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: store).view!
        XCTAssertEqual(DateWheelTestHost.wheel("Month", in: view)?.accessibilityValue, "Feb")
        XCTAssertEqual(DateWheelTestHost.wheel("Day", in: view)?.accessibilityValue, "28")
        XCTAssertEqual(DateWheelTestHost.wheel("Year", in: view)?.accessibilityValue, "2003")
        XCTAssertEqual(store.inputs["born"] as? String, "2003-02-28")
    }

    func testAnOlderInstantAnswerIsShownAsTheDayItWasPickedOn() throws {
        let store = DateWheelTestHost.Store()
        // Stored by an earlier release on a phone at UTC+1: local midnight of 28 February.
        store.inputs["born"] = "2025-02-27T23:00:00Z"
        let view = host.showWheel(try DateWheelTestHost.block(["max_date": "2026-12-31"]), store: store, calendar: zoned("Europe/Warsaw")).view!
        XCTAssertEqual(DateWheelTestHost.wheel("Day", in: view)?.accessibilityValue, "28")
        XCTAssertEqual(DateWheelTestHost.wheel("Month", in: view)?.accessibilityValue, "Feb")
    }

    func testTheControlADatetimeIsStillAMoment() throws {
        let store = DateWheelTestHost.Store()
        _ = host.showWheel(try DateWheelTestHost.block(["picker_mode": "datetime", "default_date_value": "2000-06-15"]), store: store)
        let stored = try XCTUnwrap(store.inputs["born"] as? String)
        XCTAssertNotNil(ISO8601.date(from: stored), "a datetime answer stays an ISO instant: \(stored)")
    }
}
