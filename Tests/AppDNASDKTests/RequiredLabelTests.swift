// RequiredLabelTests.swift
//
// A required field's asterisk is part of the label's text, so it trails the last word when the label wraps.

import XCTest
@testable import AppDNASDK

@MainActor
final class RequiredLabelTests: SurfaceInkTestCase {
    private let long = Array(repeating: "Wrapped", count: 14).joined(separator: " ")

    func testTheAsteriskIsPartOfTheLabelAndDrawnRed() throws {
        let block = #"{"id":"b_in","type":"input_text","field_id":"name","field_required":true,"field_label":""# + long + #""}"#
        // One accessibility node reading "<label> *": a sibling Text is a second node, and the harness's control fails.
        let counts = try render(flow(background: Self.white, blocksJSON: block), elements: [long + " *"], appearance: .light)
        XCTAssertGreaterThan(counts[long + " *"]?.red ?? 0, 5)
    }
}
