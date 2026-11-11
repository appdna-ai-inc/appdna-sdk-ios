import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// RENDERED, mid-scroll: a themed wheel column's rows stay inside the wheel and fade out at its top and bottom edge, the
/// way the system wheel's rows do, instead of sliding past the edge as a hard-cut line.
///
/// The column is held half a row between two values, which is where a drag or a fling leaves it on every frame: a row
/// then straddles each edge. THE CONTROLS: the same reader sees the rows inside the wheel, and sees full ink one row in
/// from the edge, so a pass is not a harness that sees no ink at all.
final class DateWheelClipRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    override func tearDown() { host.tearDown(); super.tearDown() }

    private let wheelHeight: CGFloat = 200

    /// Blue row ink (the authored `wheel_text_color`) over the white step, per point row, inside `xs`: the strongest
    /// blue-over-red excess on each line, 0 where there is none.
    private func ink(_ window: UIWindow, xs: ClosedRange<CGFloat>) -> [Int: Int] {
        let scale: CGFloat = 2
        let w = Int(window.bounds.width * scale), h = Int(window.bounds.height * scale)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            // The presentation tree: what is on screen in the middle of a scroll, not the model the column will rest at.
            (window.layer.presentation() ?? window.layer).render(in: ctx)
        }
        var out: [Int: Int] = [:]
        for y in 0..<h {
            var best = 0
            for x in Int(xs.lowerBound * scale)..<min(w, Int(xs.upperBound * scale)) {
                let i = (y * w + x) * 4
                best = max(best, Int(px[i + 2]) - Int(px[i]))
            }
            let line = Int(CGFloat(y) / scale)
            out[line] = max(out[line] ?? 0, best)
        }
        return out
    }

    /// The year column of a date wheel, scrolled `shift` points off its row, and the wheel's frame in the window.
    private func midScroll(shift: CGFloat) throws -> (window: UIWindow, column: ClosedRange<CGFloat>, wheel: ClosedRange<CGFloat>) {
        let block = try DateWheelTestHost.block(["default_date_value": "2010-06-15", "min_date": "1950-01-01", "max_date": "2025-12-31",
                                                 "highlight_color": "#00FF00", "wheel_height": Double(wheelHeight),
                                                 "field_config": ["picker_variant": "wheel", "wheel_text_color": "#0000FF"]])
        let view = host.showWheel(block, store: .init()).view!
        let year = try XCTUnwrap(DateWheelTestHost.wheel("Year", in: view))
        let frame = year.convert(year.bounds, to: nil)
        // The wheel is the authored height, centred on the band, whatever frame the column itself was given.
        let wheel = (frame.midY - wheelHeight / 2)...(frame.midY + wheelHeight / 2)
        // Held where a drag or fling draws it on a frame: the column's bounds (its scroll position) animated to `shift`
        // past the row, the way the scroll view moves them. The model stays on the row, so the column's own layout
        // pass does not snap it back before the frame is read.
        let held = CABasicAnimation(keyPath: "bounds.origin.y")
        held.fromValue = year.bounds.origin.y + shift
        held.toValue = year.bounds.origin.y + shift
        held.duration = 30
        year.layer.add(held, forKey: "mid-scroll")
        CATransaction.flush()
        host.settle(0.1)
        XCTAssertEqual(year.layer.presentation()?.bounds.origin.y ?? 0, year.bounds.origin.y + shift, accuracy: 0.5, "the column is drawn mid-scroll")
        return (try XCTUnwrap(view.window), (frame.minX + 4)...(frame.maxX - 4), wheel)
    }

    func testRowsMidScrollAreDrawnOnlyInsideTheWheel() throws {
        for shift: CGFloat in [19, -19, 57, -57] {
            let (window, column, wheel) = try midScroll(shift: shift)
            let lines = ink(window, xs: column)
            let outside = lines.filter { (CGFloat($0.key) < wheel.lowerBound - 1 || CGFloat($0.key) > wheel.upperBound + 1) && $0.value > 60 }
            let inside = lines.filter { wheel.contains(CGFloat($0.key)) && $0.value > 60 }
            XCTAssertGreaterThan(inside.count, 20, "harness control: the reader sees the rows inside the wheel (shift \(shift))")
            XCTAssertTrue(outside.isEmpty, "row ink outside the wheel \(wheel) at shift \(shift): lines \(outside.keys.sorted().prefix(12))")
            host.tearDown()
        }
    }

    func testARowAtTheEdgeFadesOutInsteadOfBeingCutOff() throws {
        // Half a row off: a row is centred on each edge, so before the fade its glyphs were cut there at full ink.
        let (window, column, wheel) = try midScroll(shift: 19)
        let lines = ink(window, xs: column)
        let edgeTop = (Int(wheel.lowerBound)...Int(wheel.lowerBound) + 3).map { lines[$0] ?? 0 }.max() ?? 0
        let edgeBottom = (Int(wheel.upperBound) - 4...Int(wheel.upperBound) - 1).map { lines[$0] ?? 0 }.max() ?? 0
        // One row and a half in from the top edge: the row above the band, which the fade leaves at full ink.
        let inner = (Int(wheel.lowerBound) + 40...Int(wheel.lowerBound) + 70).map { lines[$0] ?? 0 }.max() ?? 0
        XCTAssertGreaterThan(inner, 100, "harness control: a row one row in from the edge is drawn in full ink")
        XCTAssertLessThan(edgeTop, 40, "a row straddling the top edge is drawn at full ink (\(edgeTop)), cut off rather than faded")
        XCTAssertLessThan(edgeBottom, 40, "a row straddling the bottom edge is drawn at full ink (\(edgeBottom)), cut off rather than faded")
    }

    func testAtRestTheOutermostRowsAreSofterThanTheRowsBesideTheBand() throws {
        // No shift: rows sit at -2, -1, band, +1, +2. The outermost pair sits inside the fade, the inner pair does not.
        let (window, column, wheel) = try midScroll(shift: 0)
        let lines = ink(window, xs: column)
        let row: CGFloat = (wheel.upperBound - wheel.lowerBound) / 2 - 2.5 * 38 + 38 // the first full row's top, from the edge
        func sum(from a: CGFloat, to b: CGFloat) -> Int { (Int(a)...Int(b)).map { lines[$0] ?? 0 }.reduce(0, +) }
        let outer = sum(from: wheel.lowerBound, to: wheel.lowerBound + row - 1) + sum(from: wheel.upperBound - row + 1, to: wheel.upperBound)
        let inner = sum(from: wheel.lowerBound + row, to: wheel.lowerBound + row + 37) + sum(from: wheel.upperBound - row - 37, to: wheel.upperBound - row)
        XCTAssertGreaterThan(inner, 1000, "harness control: the rows beside the band are drawn")
        XCTAssertGreaterThan(outer, inner / 4, "the outermost rows are still drawn, softened, not hidden")
        XCTAssertLessThan(Double(outer), Double(inner) * 0.85, "the outermost rows are drawn as strongly as the rows beside the band: no fade")
    }
}
