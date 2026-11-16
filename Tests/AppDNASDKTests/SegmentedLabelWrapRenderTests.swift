// SegmentedLabelWrapRenderTests.swift
//
// A segmented answer's label wraps to at most two lines and is then cut, and every segment is as tall as the tallest.
// The REAL `FormInputSegmentedBlock` is drawn in a key window; the selected segment ("Yes",
// the default first option) is measured by its fill, which covers its whole cell only if the cells share one height.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SegmentedLabelWrapRenderTests: XCTestCase {
    private func block(middle: String) throws -> ContentBlock {
        let json = ##"{"id":"seg","type":"input_segmented","field_id":"goal","field_style":{"fill_color":"#1D4ED8"},"field_options":[{"id":"a","value":"a","label":"Yes"},{"id":"b","value":"b","label":"MIDDLE"},{"id":"c","value":"c","label":"No"}]}"##
            .replacingOccurrences(of: "MIDDLE", with: middle)
        return try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
    }

    /// Pixel rows that hold a run of the blue fill: the drawn height of the selected segment, in points.
    private func fillHeight(middle: String) async throws -> CGFloat {
        let size = CGSize(width: 361, height: 220)
        let view = FormInputSegmentedBlock(block: try block(middle: middle), inputValues: .constant([:]))
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.white)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var rows = 0
        for y in 0..<cg.height {
            var n = 0
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4
                if px[i] < 60, px[i + 2] > 180 { n += 1 }
            }
            if n >= 20 { rows += 1 }
        }
        return CGFloat(rows) / (CGFloat(cg.width) / size.width)
    }

    func testALongLabelWrapsToTwoLinesAndNoFurther() async throws {
        let one = try await fillHeight(middle: "Maybe")
        let two = try await fillHeight(middle: "Only on the weekends")
        let many = try await fillHeight(middle: "Only on the weekends when it rains and the shops are closed early")
        NSLog("[segmented-wrap] one=\(one) two=\(two) many=\(many)")
        XCTAssertGreaterThan(one, 20, "control: a one-line row draws the fill")
        XCTAssertGreaterThanOrEqual(two, one + 12, "a two-line label makes the row, and the selected segment with it, taller")
        XCTAssertLessThanOrEqual(many, two + 2, "a label of four or more lines is cut at two")
    }
}
