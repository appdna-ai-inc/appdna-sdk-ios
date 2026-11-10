import SwiftUI
import XCTest
@testable import AppDNASDK

/// The `input_date` / `input_time` / `input_datetime` field reads a saved answer back on return and keeps it in the shapes
/// the date wheel stores: a time or date-and-time as the wall time in the app's zone with its offset, a date as its day.
/// It used to show today and kept an ISO UTC instant. THE CONTROL: a date stays `yyyy-MM-dd`.
final class FormDateTimeZoneRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    private var savedZone: TimeZone?
    override func setUp() { super.setUp(); savedZone = AppDNA.appTimeZone }
    override func tearDown() { AppDNA.appTimeZone = savedZone; host.tearDown(); super.tearDown() }

    private func stored(_ type: String, _ components: DatePickerComponents, saved: String, zone: String?) throws -> String? {
        AppDNA.appTimeZone = zone.flatMap(TimeZone.init(identifier:))
        let block = try DateWheelTestHost.block(["picker_mode": NSNull(), "field_config": ["picker_variant": "compact"]], type: type)
        let store = DateWheelTestHost.Store()
        store.inputs["born"] = saved
        let binding = Binding<[String: Any]>(get: { store.inputs }, set: { store.inputs = $0 })
        _ = host.show(FormInputDateBlock(block: block, inputValues: binding, components: components))
        return store.inputs["born"] as? String
    }

    func testATimeIsKeptInTheAppZone() throws {
        XCTAssertEqual(try stored("input_time", .hourAndMinute, saved: "2026-11-10T14:03:00Z", zone: "Asia/Tokyo"), "23:03:00+09:00")
    }

    func testADateAndTimeIsKeptInTheAppZone() throws {
        XCTAssertEqual(try stored("input_datetime", [.date, .hourAndMinute], saved: "2000-06-15T00:00:00-04:00", zone: "Asia/Tokyo"),
                       "2000-06-15T13:00:00+09:00")
    }

    func testWithNoAppZoneItIsUTC() throws {
        XCTAssertEqual(try stored("input_datetime", [.date, .hourAndMinute], saved: "2000-06-15T00:00:00-04:00", zone: nil),
                       "2000-06-15T04:00:00Z")
    }

    func testTheControlADateStaysADate() throws {
        XCTAssertEqual(try stored("input_date", .date, saved: "2000-03-15", zone: "Asia/Tokyo"), "2000-03-15")
    }
}
