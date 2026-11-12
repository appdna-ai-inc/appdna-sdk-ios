// DatePickerStyleRenderTests.swift
//
// RENDERED through the real `ContentBlockRendererView`, pixels counted:
//   - a Date Picker with `selection_mode: "range"` and a stored range draws the bar between its ends in `range_color`;
//   - CONTROLS on the same harness: the same picker as a single-day calendar draws no bar, and as a wheel draws none —
//     so the count is the range calendar drawing, not a harness that finds the colour anywhere.
// The selection rules and the style rule are pinned by the `date_range_selection` and `date_picker_style` fixtures.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class DatePickerStyleRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 560)

    private func red(_ fieldConfig: String, stored: [String: Any]) throws -> Int {
        let json = ##"[{ "id": "d", "type": "date_wheel_picker", "field_id": "trip", "picker_mode": "date", "highlight_color": "#0000FF", "min_date": "2026-01-01", "max_date": "2027-12-31", "default_date_value": "2026-11-05", "field_config": \##(fieldConfig) }]"##
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
        let host = UIHostingController(rootView: ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant(stored))
            .padding(16)
            .frame(width: size.width, height: size.height).background(Color.white)
            .environment(\.colorScheme, .light))
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] > 230 && px[i + 1] < 30 && px[i + 2] < 30 { n += 1 }
        return n
    }

    func testAStoredRangeIsDrawnAsABarAndTheSingleDayStylesDrawNone() throws {
        let stored: [String: Any] = ["trip": "2026-11-07/2026-11-15", "trip_start": "2026-11-07", "trip_end": "2026-11-15"]
        let range = try red(##"{"selection_mode":"range","range_color":"#FF0000"}"##, stored: stored)
        let calendar = try red(##"{"picker_variant":"graphical","range_color":"#FF0000"}"##, stored: [:])
        let wheel = try red(##"{"picker_variant":"wheel","range_color":"#FF0000"}"##, stored: [:])
        NSLog("[date-range-render] range=\(range) calendar=\(calendar) wheel=\(wheel)")
        XCTAssertGreaterThan(range, 2000, "the bar across nine days is drawn in range_color")
        XCTAssertEqual(calendar, 0, "control: a single-day calendar draws no bar")
        XCTAssertEqual(wheel, 0, "control: a wheel draws no bar")
    }
}
