// SurfaceInkTimelineTests.swift
//
// A timeline's titles take their ink from the step behind them, not the phone's appearance.

import XCTest
@testable import AppDNASDK

@MainActor
final class SurfaceInkTimelineTests: SurfaceInkTestCase {
    private let labels = ["Done item", "Now item", "Later item"]
    private let block = #"{"id":"b_tl","type":"timeline","show_line":false,"timeline_items":[{"id":"1","title":"Done item","status":"completed"},{"id":"2","title":"Now item","status":"current"},{"id":"3","title":"Later item","status":"upcoming"}]}"#

    func testATimelineOnAWhiteStepInADarkAppearanceIsDark() throws {
        let counts = try render(flow(background: Self.white, blocksJSON: block), elements: labels, appearance: .dark)
        for (name, c) in counts { XCTAssertGreaterThan(c.inkOnWhite, ink, "\(name) on white in dark mode: \(c)") }
    }

    func testATimelineOnADarkStepInALightAppearanceIsLight() throws {
        let counts = try render(flow(background: Self.navy, blocksJSON: block), elements: labels, appearance: .light)
        for (name, c) in counts { XCTAssertGreaterThan(c.inkOnDark, ink, "\(name) on navy in light mode: \(c)") }
    }
}
