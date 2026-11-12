// MeasurementPickerRenderTests.swift
//
// RENDERED through the real `ContentBlockRendererView`, pixels counted:
//   - a `wheel`-style measurement picker draws its band, the value on the band, the rows around it, the unit label and
//     both toggle labels in the colours authored for them (each a pure primary);
//   - a `linear`-style picker draws its slider: the thumb in `thumb_color` and the track in `track_color`;
//   - CONTROLS on the same harness: nothing authored draws none of those primaries, and a `ruler` with the same
//     thumb colour draws no thumb — so a count is the key reaching a pixel, not a harness that finds colour anywhere.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class MeasurementPickerRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 520)

    private func frame(_ fieldConfig: String) throws -> [UInt8] {
        let json = #"[{ "id": "w", "type": "wheel_picker", "field_id": "weight", "highlight_color": "#888888", "field_config": \#(fieldConfig) }]"#
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
        let host = UIHostingController(rootView: ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16)
            .frame(width: size.width, height: size.height).background(Color.white)
            .environment(\.colorScheme, .light))
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return px
    }

    /// Pixels within a small distance of (r, g, b).
    private func count(_ px: [UInt8], _ r: Int, _ g: Int, _ b: Int, tol: Int = 14) -> Int {
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4)
        where abs(Int(px[i]) - r) < tol && abs(Int(px[i + 1]) - g) < tol && abs(Int(px[i + 2]) - b) < tol { n += 1 }
        return n
    }

    /// Strongly green-dominant pixels: the faded rows arrive blended over white.
    private func greenish(_ px: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4)
        where Int(px[i + 1]) > 200 && Int(px[i + 1]) - Int(px[i]) > 80 && Int(px[i + 1]) - Int(px[i + 2]) > 80 { n += 1 }
        return n
    }

    private let units = #"[{"id":"kg","label":"kg","min":30,"max":200,"step":0.5,"decimals":1,"factor":1,"offset":0},{"id":"lbs","label":"lbs","min":66,"max":441,"step":1,"decimals":0,"factor":2.20462,"offset":0}]"#

    private func wheel(_ colours: String) -> String {
        #"{"measurement_type":"weight","measurement_style":"wheel","measurement_default":115,"unit_default":"kg","unit_font_size":40,"units":\#(units)\#(colours)}"#
    }

    func testEveryAuthoredPartOfTheWheelReachesThePixels() throws {
        let authored = try frame(wheel(#","band_color":"#FF0000","band_text_color":"#0000FF","row_text_color":"#00FF00","unit_color":"#FF00FF","toggle_active_color":"#FFFF00","toggle_active_text_color":"#00FFFF","toggle_text_color":"#800000""#))
        let plain = try frame(wheel(""))
        let checks: [(String, ([UInt8]) -> Int)] = [
            ("band_color", { self.count($0, 255, 0, 0) }),
            ("band_text_color", { self.count($0, 0, 0, 255) }),
            ("row_text_color", { self.greenish($0) }),
            ("unit_color", { self.count($0, 255, 0, 255) }),
            ("toggle_active_color", { self.count($0, 255, 255, 0) }),
            ("toggle_active_text_color", { self.count($0, 0, 255, 255) }),
            ("toggle_text_color", { self.count($0, 128, 0, 0) }),
        ]
        for (key, measure) in checks {
            let a = measure(authored), p = measure(plain)
            NSLog("[measurement-palette] \(key) authored=\(a) unauthored=\(p)")
            XCTAssertGreaterThan(a, 15, "\(key) drew \(a) pixels")
            XCTAssertLessThanOrEqual(p, 15, "control: unauthored, \(key)'s colour drew \(p) pixels")
        }
    }

    func testTheLinearStyleDrawsItsSliderInItsColours() throws {
        let one = #"[{"id":"cm","label":"cm","min":100,"max":220,"step":1,"decimals":0,"factor":1,"offset":0}]"#
        let linear = try frame(#"{"measurement_type":"height","measurement_style":"linear","measurement_default":160,"units":\#(one),"thumb_color":"#FF0000","track_color":"#0000FF","thumb_size":40}"#)
        let ruler = try frame(#"{"measurement_type":"height","measurement_style":"ruler","measurement_default":160,"units":\#(one),"thumb_color":"#FF0000","track_color":"#0000FF","thumb_size":40}"#)
        let thumb = count(linear, 255, 0, 0), track = count(linear, 0, 0, 255)
        NSLog("[measurement-linear] thumb=\(thumb) track=\(track) ruler-thumb=\(count(ruler, 255, 0, 0))")
        XCTAssertGreaterThan(thumb, 400, "the linear thumb is drawn in thumb_color")
        XCTAssertGreaterThan(track, 200, "the linear track is drawn in track_color")
        XCTAssertLessThanOrEqual(count(ruler, 255, 0, 0), 15, "control: a ruler draws no thumb")
    }
}
