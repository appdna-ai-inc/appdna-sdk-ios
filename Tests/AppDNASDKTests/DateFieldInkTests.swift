// DateFieldInkTests.swift
//
// An unstyled date or time value takes its ink from the surface behind it. The field forced a light
// colour scheme, so its value was black on a dark step when the phone was in Light.

import XCTest
@testable import AppDNASDK

@MainActor
final class DateFieldInkTests: SurfaceInkTestCase {
    private var today: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
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
