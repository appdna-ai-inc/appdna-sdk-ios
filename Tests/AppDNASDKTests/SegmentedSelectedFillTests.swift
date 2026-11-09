// SegmentedSelectedFillTests.swift
//
// The selected segment of `input_segmented` draws in `field_style.fill_color`. A segmented `Picker` ignores `.tint`
// for its selected segment and stays system grey, so this counts the authored red inside the selected label's frame.

import XCTest
@testable import AppDNASDK

@MainActor
final class SegmentedSelectedFillTests: SurfaceInkTestCase {
    private func segmented(fill: String) -> String {
        #"{"id":"b_seg","type":"input_segmented","field_id":"pick","field_style":{"fill_color":""#
            + fill + #""},"field_options":[{"id":"a","value":"a","label":"Option alpha"},{"id":"b","value":"b","label":"Option beta"}]}"#
    }

    func testTheSelectedSegmentDrawsItsFillColour() throws {
        let counts = try render(flow(background: Self.white, blocksJSON: segmented(fill: "#FF0000")), elements: ["Option alpha"], appearance: .light)
        XCTAssertGreaterThan(counts["Option alpha"]?.red ?? 0, 200, "the first option is selected by default and filled red")
    }

    func testALightFillDrawsADarkLabel() throws {
        let counts = try render(flow(background: Self.navy, blocksJSON: segmented(fill: "#FFEB3B")), elements: ["Option alpha"], appearance: .light)
        XCTAssertGreaterThan(counts["Option alpha"]?.dark ?? 0, ink, "the label on a light fill is dark")
    }
}
