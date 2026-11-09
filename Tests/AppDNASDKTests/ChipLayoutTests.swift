// ChipLayoutTests.swift
//
// A chip is as wide as its label, on one line. An equal grid cell made a label wider than the cell wrap inside it.

import XCTest
@testable import AppDNASDK

@MainActor
final class ChipLayoutTests: SurfaceInkTestCase {
    func testAChipHugsItsLabelOnOneLine() throws {
        let labels = ["Pasta", "Chicken", "Tinned tomatoes and beans"]
        let options = labels.enumerated().map { #"{"id":"o\#($0.offset)","value":"o\#($0.offset)","label":"\#($0.element)"}"# }.joined(separator: ",")
        let block = #"{"id":"b_c","type":"input_chips","field_id":"pick","field_options":["# + options + "]}"
        _ = try render(flow(background: Self.white, blocksJSON: block), elements: labels, appearance: .light)
        let heights = labels.compactMap { lastFrames[$0]?.height }
        XCTAssertEqual(heights.count, labels.count)
        let tallest = try XCTUnwrap(heights.max()), shortest = try XCTUnwrap(heights.min())
        XCTAssertEqual(tallest, shortest, accuracy: 1, "every chip is one line tall: \(heights)")
        let long = try XCTUnwrap(lastFrames[labels[2]]), short = try XCTUnwrap(lastFrames[labels[0]])
        XCTAssertGreaterThan(long.width, short.width * 1.5, "a chip is as wide as its label, not an equal cell")
    }

    func testALabelWiderThanTheRowStaysOnOneLine() throws {
        let wide = Array(repeating: "Wrapped", count: 30).joined(separator: " ")
        let block = #"{"id":"b_c","type":"input_chips","field_id":"pick","field_options":[{"id":"a","value":"a","label":"Pasta"},{"id":"b","value":"b","label":""# + wide + #""}]}"#
        _ = try render(flow(background: Self.white, blocksJSON: block), elements: ["Pasta", wide], appearance: .light)
        XCTAssertEqual(try XCTUnwrap(lastFrames[wide]).height, try XCTUnwrap(lastFrames["Pasta"]).height, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(lastFrames[wide]).width, 393)
    }
}
