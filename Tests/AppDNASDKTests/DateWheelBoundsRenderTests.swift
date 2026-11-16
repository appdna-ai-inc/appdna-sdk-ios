import SwiftUI
import XCTest
@testable import AppDNASDK

/// The band shows a date the wheel may store. A wheel with no default and no answer opens on today brought inside the
/// authored bounds, and stores nothing until the user moves it. THE CONTROL: a today inside the bounds opens on today.
final class DateWheelBoundsRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    private var savedZone: TimeZone?
    override func setUp() {
        super.setUp()
        savedZone = AppDNA.appTimeZone
        // The wheel's today is the app's: a zone whose day differs from the device's makes that visible.
        AppDNA.appTimeZone = appZoneWhoseTodayDiffersFromTheDevice()
    }
    override func tearDown() { AppDNA.appTimeZone = savedZone; host.tearDown(); super.tearDown() }

    private func band(_ view: UIView) -> [String?] {
        ["Month", "Day", "Year"].map { DateWheelTestHost.wheel($0, in: view)?.accessibilityValue }
    }

    func testAWheelWhoseBoundsAreAllPastOpensOnTheLatestDay() throws {
        let store = DateWheelTestHost.Store()
        let view = host.showWheel(try DateWheelTestHost.block(["min_date": "2000-03-15", "max_date": "2000-12-31"]), store: store).view!
        XCTAssertEqual(band(view), ["Dec", "31", "2000"])
        XCTAssertNil(store.inputs["born"], "nothing is stored before the user moves the wheel")
    }

    func testAWheelWhoseBoundsAreAllFutureOpensOnTheEarliestDay() throws {
        let store = DateWheelTestHost.Store()
        let view = host.showWheel(try DateWheelTestHost.block(["min_date": "2190-03-15", "max_date": "2195-12-31"]), store: store).view!
        XCTAssertEqual(band(view), ["Mar", "15", "2190"])
        XCTAssertNil(store.inputs["born"])
    }

    func testTheControlTodayInsideTheBoundsOpensOnToday() throws {
        let view = host.showWheel(try DateWheelTestHost.block([:]), store: .init()).view!
        var appCalendar = Calendar(identifier: .gregorian)
        appCalendar.timeZone = AnswerTime.zone
        let today = appCalendar.dateComponents([.year, .day], from: Date())
        XCTAssertEqual(band(view)[1], String(today.day!))
        XCTAssertEqual(band(view)[2], String(today.year!))
    }
}
