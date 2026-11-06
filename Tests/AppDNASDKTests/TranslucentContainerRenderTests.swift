import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED on a white step: a container `#00000080` keeps its alpha (~#7F7F7F) and `container_opacity` 0.5
 multiplies it (~#BFBFBF) — the iOS reference Android now matches. THE CONTROL: no black is drawn.
*/
@MainActor
final class TranslucentContainerRenderTests: XCTestCase {
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

    private func render(_ raw: [String: Any]) throws -> some View {
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: [raw]))
        return ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16).frame(width: 393, height: 260).background(Color.white)
            .environment(\.googleAttributionBackdrop, .plain(hex: "#FFFFFF"))
    }
    private func near(_ r0: Int, _ g0: Int, _ b0: Int, _ tol: Int) -> (UInt8, UInt8, UInt8) -> Bool {
        { r, g, b in abs(Int(r) - r0) <= tol && abs(Int(g) - g0) <= tol && abs(Int(b) - b0) <= tol }
    }

    func testATranslucentContainerKeepsItsAlphaAndMultipliesTheOpacity() throws {
        let size = CGSize(width: 393, height: 260)
        func box(_ opacity: Double?) -> [String: Any] {
            var cfg: [String: Any] = ["container_bg_color": "#00000080"]
            if let opacity { cfg["container_opacity"] = opacity }
            return ["id": "s", "type": "heading", "text": "WWWWWWWWWWWW", "element_width": "fill",
                    "style": ["font_size": 40, "color": "#FFFFFF"], "field_config": cfg]
        }
        let half = try count(render(box(nil)), size: size, match: near(0x7F, 0x7F, 0x7F, 6))
        let opaque = try count(render(box(nil)), size: size) { $0 < 10 && $1 < 10 && $2 < 10 }
        let quarter = try count(render(box(0.5)), size: size, match: near(0xBF, 0xBF, 0xBF, 6))
        NSLog("[translucent container] half=\(half) opaque=\(opaque) quarter=\(quarter)")
        XCTAssertGreaterThan(half, 3000); XCTAssertLessThan(opaque, 100); XCTAssertGreaterThan(quarter, 3000)
    }
}
