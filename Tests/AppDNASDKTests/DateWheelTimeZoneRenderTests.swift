import SwiftUI
import XCTest
@testable import AppDNASDK

/// A time or date-and-time wheel works in the app's time zone (the console's app setting; UTC when none): it opens on,
/// shows and stores the wall time there, with the zone's offset. THE CONTROL: a date-only wheel stays a calendar date.
final class DateWheelTimeZoneRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    private var savedZone: TimeZone?
    override func setUp() { super.setUp(); savedZone = AppDNA.appTimeZone }
    override func tearDown() { AppDNA.appTimeZone = savedZone; host.tearDown(); super.tearDown() }

    private func stored(_ extra: [String: Any], zone: String?) throws -> (String?, UIView) {
        AppDNA.appTimeZone = zone.flatMap(TimeZone.init(identifier:))
        let store = DateWheelTestHost.Store()
        let view = host.showWheel(try DateWheelTestHost.block(extra), store: store).view!
        return (store.inputs["born"] as? String, view)
    }

    func testADateAndTimeIsStoredAsTheWallTimeInTheAppZone() throws {
        let (answer, _) = try stored(["picker_mode": "datetime", "default_date_value": "2000-06-15"], zone: "America/New_York")
        XCTAssertEqual(answer, "2000-06-15T00:00:00-04:00")
    }

    func testWithNoAppZoneItIsUTC() throws {
        let (answer, _) = try stored(["picker_mode": "datetime", "default_date_value": "2000-06-15"], zone: nil)
        XCTAssertEqual(answer, "2000-06-15T00:00:00Z")
    }

    func testAStoredMomentIsShownInTheAppZone() throws {
        // A zone unlike the simulator's, so the phone's zone cannot pass for the app's.
        AppDNA.appTimeZone = TimeZone(identifier: "Asia/Tokyo")
        let store = DateWheelTestHost.Store()
        store.inputs["born"] = "2026-11-10T14:03:00Z"
        let view = host.showWheel(try DateWheelTestHost.block(["picker_mode": "time", "time_format": "24h"]), store: store).view!
        XCTAssertEqual(DateWheelTestHost.wheel("Hour", in: view)?.accessibilityValue, "23")
        XCTAssertEqual(DateWheelTestHost.wheel("Minute", in: view)?.accessibilityValue, "03")
    }

    func testTheControlADateStaysACalendarDate() throws {
        let (answer, _) = try stored(["picker_mode": "date", "default_date_value": "2000-06-15"], zone: "Pacific/Tongatapu")
        XCTAssertEqual(answer, "2000-06-15")
    }
}
