import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED: the real `AnimatedImageStrip` drawing a striped test image at two moments half a second
 apart. The strip has to MOVE between the two frames — by exactly speed × 0.5 s, in the authored
 direction — and the loop has to be seamless (a frame one whole tile-period later equals the first).
 THE CONTROL: two frames at the same moment are identical, so "the frames differ" cannot pass because
 the harness is noisy.
*/
@MainActor
final class AnimatedImageRenderTests: XCTestCase {
    private let size = CGSize(width: 200, height: 50)

    /// 400×100 image: a 20pt red bar at its left edge, the rest blue. Scaled to 50pt high → 200pt tile.
    private func stripe(vertical: Bool = false) -> UIImage {
        let s = vertical ? CGSize(width: 100, height: 400) : CGSize(width: 400, height: 100)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(origin: .zero, size: s))
            UIColor.red.setFill(); ctx.fill(vertical ? CGRect(x: 0, y: 0, width: 100, height: 40) : CGRect(x: 0, y: 0, width: 40, height: 100))
        }
    }

    private func frame(_ direction: String, at t: Double, image: UIImage? = nil, size: CGSize? = nil) throws -> (px: [UInt8], w: Int, h: Int, scale: CGFloat) {
        let sz = size ?? self.size
        let start = Date(timeIntervalSince1970: 0)
        let view = AnimatedImageStrip(image: image ?? stripe(), direction: direction, speed: 40, startDate: start, now: start.addingTimeInterval(t))
            .frame(width: sz.width, height: sz.height).clipped()
        var out: UIImage?
        let done = expectation(description: "snapshot")
        Snapshotting<AnyView, UIImage>.image(layout: .fixed(width: sz.width, height: sz.height)).snapshot(AnyView(view)).run { out = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let cg = try XCTUnwrap(out?.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (px, cg.width, cg.height, CGFloat(cg.width) / sz.width)
    }

    /// Leading edge of the red bar along the middle row, in points (horizontal strip).
    private func redStartX(_ f: (px: [UInt8], w: Int, h: Int, scale: CGFloat)) -> CGFloat? {
        let y = f.h / 2
        for x in 0..<f.w {
            let i = (y * f.w + x) * 4
            if f.px[i] > 200 && f.px[i + 2] < 60 { return CGFloat(x) / f.scale }
        }
        return nil
    }

    func testControlTheSameMomentDrawsTheSameFrame() throws {
        XCTAssertEqual(try frame("left", at: 1).px, try frame("left", at: 1).px)
    }

    func testLeftMovesTheStripLeftBySpeedTimesTime() throws {
        // At t = 1 the strip has moved 40pt left: the bar of the SECOND copy starts at 200 − 40 = 160.
        let a = try frame("left", at: 1), b = try frame("left", at: 1.5)
        XCTAssertNotEqual(a.px, b.px, "the strip did not move")
        XCTAssertEqual(try XCTUnwrap(redStartX(a)), 160, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(redStartX(b)), 140, accuracy: 1.5, "0.5 s at 40pt/s is 20pt further left")
    }

    func testRightMovesTheStripRight() throws {
        // Right starts one tile back (−200) and moves forward: at t = 1 the bar is at −200 + 40 + 200 = 40.
        let a = try frame("right", at: 1), b = try frame("right", at: 1.5)
        XCTAssertEqual(try XCTUnwrap(redStartX(a)), 40, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(redStartX(b)), 60, accuracy: 1.5)
    }

    func testTheLoopIsSeamless() throws {
        // One tile is 200pt; at 40pt/s that is 5 s. A frame 5 s later is the same frame.
        XCTAssertEqual(try frame("left", at: 1).px, try frame("left", at: 6).px)
    }

    func testUpAndDownMoveVertically() throws {
        let tall = CGSize(width: 50, height: 200)
        let up1 = try frame("up", at: 1, image: stripe(vertical: true), size: tall)
        let up2 = try frame("up", at: 1.5, image: stripe(vertical: true), size: tall)
        let down1 = try frame("down", at: 1, image: stripe(vertical: true), size: tall)
        XCTAssertNotEqual(up1.px, up2.px, "up did not move")
        XCTAssertNotEqual(up1.px, down1.px, "up and down drew the same frame")
    }
}
