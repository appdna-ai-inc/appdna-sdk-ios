import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED, through the real `ContentBlockRendererView`: a heading carrying BOTH `block_style.background_color:
 #000000` and `field_config.container_bg_color: #F3F4F6` shows the `block_style` fill over the container fill —
 container outer, `block_style` inner, the order the console preview draws and Android now draws too. THE
 CONTROLS: the `block_style` fill alone draws black; the container fill alone draws no black.
*/
@MainActor
final class BlockLayerOrderRenderTests: XCTestCase {
    private func count<V: View>(_ view: V, size: CGSize, match: (UInt8, UInt8, UInt8) -> Bool) throws -> Int {
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
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where match(px[i], px[i + 1], px[i + 2]) { n += 1 }
        return n
    }

    private func heading(blockStyle: Bool, container: Bool) throws -> some View {
        var h: [String: Any] = ["id": "h", "type": "heading", "text": "WWWW", "style": ["color": "#FFFFFF", "font_size": 28]]
        if blockStyle { h["block_style"] = ["background_color": "#000000"] }
        if container { h["field_config"] = ["container_bg_color": "#F3F4F6"] }
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: [h]))
        return ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16).frame(width: 393, height: 160).background(Color(hex: "#FF0000"))
            .environment(\.googleAttributionBackdrop, .plain(hex: "#FF0000"))
    }

    func testBlockStylePaintsOverTheContainerFill() throws {
        let size = CGSize(width: 393, height: 160)
        let black = { (r: UInt8, g: UInt8, b: UInt8) in r < 10 && g < 10 && b < 10 }
        let styleOnly = try count(heading(blockStyle: true, container: false), size: size, match: black)
        let containerOnly = try count(heading(blockStyle: false, container: true), size: size, match: black)
        let both = try count(heading(blockStyle: true, container: true), size: size, match: black)
        NSLog("[layer-order] styleOnly=\(styleOnly) containerOnly=\(containerOnly) both=\(both)")
        XCTAssertGreaterThan(styleOnly, 2000, "control: block_style alone draws black")
        XCTAssertLessThan(containerOnly, 100, "control: the container alone draws no black")
        XCTAssertGreaterThan(both, styleOnly / 2, "with both, block_style is not the visible (inner) layer")
    }
}
