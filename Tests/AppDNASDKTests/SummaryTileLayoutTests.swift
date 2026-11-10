// SummaryTileLayoutTests.swift
//
// A two-column summary tile's value breaks only on word boundaries, and the tiles in one row share a height.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SummaryTileLayoutTests: SurfaceInkTestCase {
    private func summary(_ values: [String]) -> String {
        let stats = values.map { #"{"value":"\#($0)","label":"L"}"# }.joined(separator: ",")
        return ##"{"id":"b_s","type":"summary_screen","bg_color":"#FF00FF","field_config":{"summary_stats":["## + stats + "]}}"
    }

    func testAWordTooWideForTheTileStaysOnOneLine() throws {
        _ = try render(flow(background: Self.white, blocksJSON: summary(["Intermediate", "Mid"])),
                       elements: ["Intermediate", "Mid"], appearance: .light)
        let wide = try XCTUnwrap(lastFrames["Intermediate"]), short = try XCTUnwrap(lastFrames["Mid"])
        NSLog("[summary-fit] wide=\(wide.height) short=\(short.height)")
        XCTAssertLessThanOrEqual(wide.height, short.height + 1, "the word wrapped onto a second line")
    }

    func testAnUnbrokenIdStaysOnOneLine() throws {
        _ = try render(flow(background: Self.white, blocksJSON: summary(["home_basics_and_more", "Mid"])),
                       elements: ["home_basics_and_more", "Mid"], appearance: .light)
        XCTAssertLessThanOrEqual(try XCTUnwrap(lastFrames["home_basics_and_more"]).height, try XCTUnwrap(lastFrames["Mid"]).height + 1)
    }

    func testTheFitIsTheSharedPolicy() {
        XCTAssertEqual(SummaryTileFit.scale(longestWordWidth: 100, availableWidth: 137), 1)
        XCTAssertEqual(SummaryTileFit.scale(longestWordWidth: 400, availableWidth: 137), SummaryTileFit.minScale)
    }

    func testTilesInARowShareAHeight() throws {
        let size = CGSize(width: 393, height: 400)
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data("[\(summary(["Take a short walk every single day", "Mid"]))]".utf8))
        let view = ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16).frame(width: size.width, height: size.height, alignment: .top).background(Color.white)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        func extent(_ x0: Int, _ x1: Int) -> (Int, Int) {
            var top = -1, bottom = -1
            for y in 0..<cg.height { for x in x0..<x1 {
                let i = y * cg.width * 4 + x * 4
                if px[i] > 240, px[i + 1] < 20, px[i + 2] > 240 { if top < 0 { top = y }; bottom = y }
            } }
            return (top, bottom)
        }
        let l = extent(0, cg.width / 2), r = extent(cg.width / 2, cg.width)
        NSLog("[summary-row] left=\(l) right=\(r)")
        XCTAssertGreaterThanOrEqual(l.0, 0, "the control: a tile's fill was found")
        XCTAssertEqual(l.1 - l.0, r.1 - r.0, "the row's tiles share a height")
    }
}
