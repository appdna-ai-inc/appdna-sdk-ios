import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED, through the real `ContentBlockRendererView` on a white step: a heading NESTED in a stack, with its own
 `field_config.container_bg_color: #000000`, draws that black fill behind it, as the same heading does at the
 top level and as Android draws both. THE CONTROL: without the container colour, no black fill is drawn.
*/
@MainActor
final class NestedContainerStyleRenderTests: XCTestCase {
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

    private func heading(_ fill: String?) -> [String: Any] {
        var h: [String: Any] = ["id": "h", "type": "heading", "text": "WWWW", "style": ["color": "#FFFFFF", "font_size": 28]]
        if let fill { h["field_config"] = ["container_bg_color": fill] }
        return h
    }

    private func render(_ raw: [String: Any]) throws -> some View {
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: [raw]))
        return ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16).frame(width: 393, height: 160).background(Color.white)
            .environment(\.googleAttributionBackdrop, .plain(hex: "#FFFFFF"))
    }

    func testANestedBlockDrawsItsContainerFill() throws {
        let size = CGSize(width: 393, height: 160)
        let black = { (r: UInt8, g: UInt8, b: UInt8) in r < 10 && g < 10 && b < 10 }
        let none = try count(render(["id": "s", "type": "stack", "children": [heading(nil)]]), size: size, match: black)
        let nested = try count(render(["id": "s", "type": "stack", "children": [heading("#000000")]]), size: size, match: black)
        let top = try count(render(heading("#000000")), size: size, match: black)
        NSLog("[nested-container] none=\(none) nested=\(nested) top=\(top)")
        XCTAssertLessThan(none, 100, "control: no container colour, no black fill")
        XCTAssertGreaterThan(top, 2000, "harness: a top-level container fill draws")
        XCTAssertGreaterThan(nested, 2000, "a nested block's container fill is not drawn")
    }
}
