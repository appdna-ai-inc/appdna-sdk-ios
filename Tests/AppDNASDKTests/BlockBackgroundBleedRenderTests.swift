import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED, through the real `ContentBlockRendererView`: a multi-buttons group with a magenta background
 and `background_bleed_*` set to 20 points on every side paints a band 20 points wide around the group,
 and the buttons inside do not move. THE CONTROL: the same group with nothing authored paints only its
 own box — so a harness that could not see the fill would fail the first assertion, not pass it.
*/
@MainActor
final class BlockBackgroundBleedRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 300)

    private func pixels<V: View>(_ view: V) throws -> (px: [UInt8], w: Int, h: Int, scale: CGFloat) {
        var image: UIImage?
        let done = expectation(description: "snapshot")
        Snapshotting<AnyView, UIImage>.image(layout: .fixed(width: size.width, height: size.height), traits: .init(userInterfaceStyle: .light))
            .snapshot(AnyView(view)).run { image = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let cg = try XCTUnwrap(image?.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (px, cg.width, cg.height, CGFloat(cg.width) / size.width)
    }

    private func isMagenta(_ p: [UInt8], _ i: Int) -> Bool { p[i] > 240 && p[i + 1] < 15 && p[i + 2] > 240 }

    private func render(_ fc: [String: Any]) throws -> some View {
        let raw: [String: Any] = [
            "id": "group", "type": "multi_buttons", "field_config": fc,
            "block_style": ["background_color": "#FF00FF"],
            "stack_children": [
                ["id": "b1", "type": "button", "text": "One", "action": "next"],
                ["id": "b2", "type": "button", "text": "Two", "action": "next"],
            ],
        ]
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: [raw]))
        return VStack {
            Spacer()
            ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
                .padding(60)
            Spacer()
        }
        .frame(width: size.width, height: size.height).background(Color.white)
    }

    /// The magenta pixels' bounding box, in points.
    private func box(_ r: (px: [UInt8], w: Int, h: Int, scale: CGFloat)) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<r.h { for x in 0..<r.w where isMagenta(r.px, (y * r.w + x) * 4) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / r.scale, y: CGFloat(minY) / r.scale,
                      width: CGFloat(maxX - minX + 1) / r.scale, height: CGFloat(maxY - minY + 1) / r.scale)
    }

    func testASetAmountOnEverySidePaintsThatFarPastTheGroup() throws {
        let control = try XCTUnwrap(box(try pixels(render([:]))), "harness: the group's own fill is visible")
        let bled = try XCTUnwrap(box(try pixels(render([
            "background_bleed_top": 20, "background_bleed_bottom": 20,
            "background_bleed_left": 20, "background_bleed_right": 20,
        ]))))
        NSLog("[bleed] control=\(control) bled=\(bled)")
        XCTAssertEqual(bled.minX, control.minX - 20, accuracy: 1.5, "left reaches 20pt further")
        XCTAssertEqual(bled.maxX, control.maxX + 20, accuracy: 1.5, "right reaches 20pt further")
        XCTAssertEqual(bled.minY, control.minY - 20, accuracy: 1.5, "top reaches 20pt further")
        XCTAssertEqual(bled.maxY, control.maxY + 20, accuracy: 1.5, "bottom reaches 20pt further")
    }

    func testOnlyTheAuthoredSideMoves() throws {
        let control = try XCTUnwrap(box(try pixels(render([:]))))
        let bled = try XCTUnwrap(box(try pixels(render(["background_bleed_bottom": 30]))))
        XCTAssertEqual(bled.minY, control.minY, accuracy: 1.5)
        XCTAssertEqual(bled.minX, control.minX, accuracy: 1.5)
        XCTAssertEqual(bled.maxY, control.maxY + 30, accuracy: 1.5)
    }
}
