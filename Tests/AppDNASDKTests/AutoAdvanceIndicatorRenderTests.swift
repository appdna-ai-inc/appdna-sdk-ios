import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED: the countdown a self-advancing step draws, through the real decode, the real resolver
 and the real `AutoAdvanceIndicatorDrawing`, at two moments of a 3 s wait. The label ticks down and the
 magenta bar is SHORTER at the later moment. THE CONTROL: a step without `show: true` resolves to
 nothing, and a frame drawn from it has no magenta at all — so "the bar got shorter" cannot pass on a
 harness that draws nothing.
*/
@MainActor
final class AutoAdvanceIndicatorRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 200)

    private func step(_ indicator: [String: Any]?) throws -> OnboardingStep {
        var layout: [String: Any] = ["auto_advance_seconds": 3]
        if let indicator { layout["auto_advance_indicator"] = indicator }
        let json: [String: Any] = ["id": "splash", "type": "splash", "layout": layout]
        return try JSONDecoder().decode(OnboardingStep.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Width in points of the magenta run on the bar's row.
    private func barWidth(_ frame: AutoAdvanceIndicator.Frame?) throws -> CGFloat {
        let view = ZStack { Color.white; if let frame { AutoAdvanceIndicatorDrawing(view: frame) } }
            .frame(width: size.width, height: size.height)
        var image: UIImage?
        let done = expectation(description: "snapshot")
        Snapshotting<AnyView, UIImage>.image(layout: .fixed(width: size.width, height: size.height)).snapshot(AnyView(view)).run { image = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let cg = try XCTUnwrap(image?.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var best = 0
        for y in 0..<cg.height {
            var n = 0
            for x in 0..<cg.width { let i = (y * cg.width + x) * 4; if px[i] > 220 && px[i + 1] < 40 && px[i + 2] > 220 { n += 1 } }
            best = max(best, n)
        }
        return CGFloat(best) / (CGFloat(cg.width) / size.width)
    }

    func testTheLabelTicksDownAndTheBarEmpties() throws {
        let s = try step(["show": true, "bar_color": "#FF00FF", "bar_height": 8])
        let a = try XCTUnwrap(AutoAdvanceIndicator.resolve(step: s, elapsed: 0.1))
        let b = try XCTUnwrap(AutoAdvanceIndicator.resolve(step: s, elapsed: 1.2))
        XCTAssertEqual(a.label, "Continuing in 3")
        XCTAssertEqual(b.label, "Continuing in 2")
        let wa = try barWidth(a), wb = try barWidth(b)
        NSLog("[indicator] bar \(wa) -> \(wb)")
        XCTAssertGreaterThan(wa, wb, "the bar did not shorten")
        // 345pt track (393 − 2 × 24); 60% left at 1.2 s of 3.
        XCTAssertEqual(wb, 345 * 0.6, accuracy: 4)
    }

    func testControlWithoutShowNothingIsDrawn() throws {
        XCTAssertNil(AutoAdvanceIndicator.resolve(step: try step(nil), elapsed: 0.5))
        XCTAssertNil(AutoAdvanceIndicator.resolve(step: try step(["show": false, "bar_color": "#FF00FF"]), elapsed: 0.5))
        XCTAssertEqual(try barWidth(nil), 0)
    }

    /// Rows (in points) that contain a pixel matching `match`.
    private func rows(_ view: some View, height: CGFloat, match: (UInt8, UInt8, UInt8) -> Bool) throws -> [Int] {
        var image: UIImage?
        let done = expectation(description: "snapshot")
        Snapshotting<AnyView, UIImage>.image(layout: .fixed(width: size.width, height: height)).snapshot(AnyView(view)).run { image = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let cg = try XCTUnwrap(image?.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let scale = CGFloat(cg.width) / size.width
        var out = Set<Int>()
        for y in 0..<cg.height { for x in 0..<cg.width {
            let i = (y * cg.width + x) * 4
            if match(px[i], px[i + 1], px[i + 2]) { out.insert(Int(CGFloat(y) / scale)) }
        } }
        return out.sorted()
    }

    /**
     A countdown at the TOP takes its own space in the step host (`safeAreaInset(edge: .top)` around
     the step, as `OnboardingRenderer` does), so the step's heading starts BELOW the label — on a device
     it used to be painted over the heading. The heading is black, the label blue (#2563EB).
     */
    func testATopCountdownSitsAboveTheHeadingNotOverIt() throws {
        let s = try step(["show": true, "style": "text", "text": "Next in {seconds}s", "text_color": "#2563EB", "font_size": 20, "position": "top"])
        let frame = try XCTUnwrap(AutoAdvanceIndicator.resolve(step: s, elapsed: 1))
        let host = VStack(alignment: .leading) {
            Text("HEADING").font(.system(size: 28, weight: .bold)).foregroundColor(.black)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .top, spacing: 0) {
            AutoAdvanceIndicatorDrawing(view: frame, inline: true)
        }
        .frame(width: size.width, height: 300).background(Color.white)
        let blue = try rows(host, height: 300) { r, g, b in b > 180 && r < 90 && g < 140 }
        let black = try rows(host, height: 300) { r, g, b in r < 40 && g < 40 && b < 40 }
        let label = try XCTUnwrap(blue.last), heading = try XCTUnwrap(black.first)
        NSLog("[indicator-top] label rows \(blue.first ?? -1)…\(label), heading from \(heading)")
        XCTAssertLessThan(label, heading, "the countdown overlaps the heading")
    }
}
