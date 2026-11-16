// DateFieldInkTests.swift
//
// An unstyled date or time value takes its ink from the surface behind it. The field forced a light
// colour scheme, so its value was black on a dark step when the phone was in Light.

import XCTest
@testable import AppDNASDK

@MainActor
final class DateFieldInkTests: SurfaceInkTestCase {
    private var savedZone: TimeZone?
    override func setUp() {
        super.setUp()
        savedZone = AppDNA.appTimeZone
        AppDNA.appTimeZone = appZoneWhoseTodayDiffersFromTheDevice()
    }
    override func tearDown() { AppDNA.appTimeZone = savedZone; super.tearDown() }

    /// Today as the field draws it: in the APP's time zone, not the device's.
    private var today: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = AnswerTime.zone
        return f.string(from: Date())
    }

    private let block = #"{"id":"b_d","type":"input_date","field_id":"when"}"#

    func testAnUnstyledDateValueIsLightOnADarkStepOnALightPhone() throws {
        let counts = try render(flow(background: Self.navy, blocksJSON: block), elements: [today], appearance: .light)
        let value = try XCTUnwrap(counts[today])
        NSLog("[date-ink] dark step, light phone: light=\(value.light) dark=\(value.dark)")
        XCTAssertGreaterThan(value.light, ink, "the value is not light ink on the dark step")
    }

    func testAnUnstyledDateValueIsDarkOnALightStepOnADarkPhone() throws {
        let counts = try render(flow(background: Self.white, blocksJSON: block), elements: [today], appearance: .dark)
        let value = try XCTUnwrap(counts[today])
        NSLog("[date-ink] light step, dark phone: light=\(value.light) dark=\(value.dark)")
        XCTAssertGreaterThan(value.inkOnWhite, ink, "the value is not dark ink on the light step")
    }

    func testAnAuthoredValueColourStillWins() throws {
        let styled = ##"{"id":"b_d","type":"input_date","field_id":"when","field_style":{"text_color":"#FF0000"}}"##
        let counts = try render(flow(background: Self.navy, blocksJSON: styled), elements: [today], appearance: .light)
        let value = try XCTUnwrap(counts[today])
        XCTAssertGreaterThan(value.red, ink, "an authored colour still draws")
    }
}

/// A zone whose calendar day differs from the device's at this moment, so a test that reads "today" proves it reads
/// the APP's today. These tests failed only in the hour around midnight when they read the device's, which is
/// exactly the hour the two days differ. Nil only if no candidate differs (never, for a +14 / -11 pair).
func appZoneWhoseTodayDiffersFromTheDevice(now: Date = Date()) -> TimeZone? {
    let local = Calendar.current.dateComponents([.year, .month, .day], from: now)
    for id in ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
        guard let zone = TimeZone(identifier: id) else { continue }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        if cal.dateComponents([.year, .month, .day], from: now) != local { return zone }
    }
    return nil
}
