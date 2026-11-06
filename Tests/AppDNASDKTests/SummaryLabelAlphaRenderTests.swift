import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED: a `summary_screen` with `text_color` `#00000080` draws its default stat label at 0.5 x 0.7 = 0.35 over
 the #1F2937 card (~(20,27,36)), not at 0.7 (~(9,12,17)) — the iOS reference Android now matches.
*/
@MainActor
final class SummaryLabelAlphaRenderTests: XCTestCase {
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

    func testATranslucentSummaryTextColourKeepsItsAlphaUnderTheLabelAlpha() throws {
        let size = CGSize(width: 393, height: 260)
        let raw: [String: Any] = ["id": "sum", "type": "summary_screen", "text_color": "#00000080",
                                  "field_config": ["summary_stats": [["value": "1", "label": "WWWWWWWW", "color": "#FF0000"]]]]
        let at035 = try count(render(raw), size: size, match: near(20, 27, 36, 3))
        let at07 = try count(render(raw), size: size, match: near(9, 12, 17, 3))
        NSLog("[translucent label] at035=\(at035) at07=\(at07)")
        XCTAssertGreaterThan(at035, at07, "the label's 0.7 replaced the authored alpha")
    }
}
