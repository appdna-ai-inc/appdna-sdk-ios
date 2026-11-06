import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED, through the real `ContentBlockRendererView` on a white step: a row authored the way the console's
 Row Background control writes it (`field_config.bg_color`, `background_opacity`) draws that fill — `#2563EB`
 opaque, at 0.5 (composited `#92B1F5`), and `#2563EB80` at 0.5 (a quarter, `#C9D8FA`: the opacity multiplies the
 colour's own alpha, as on Android). THE CONTROL: a row with no fill draws none of those colours.
*/
@MainActor
final class RowFillRenderTests: XCTestCase {
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

    private func row(_ bg: String?, opacity: Double? = nil) throws -> some View {
        var cfg: [String: Any] = ["corner_radius": 0]
        if let bg { cfg["bg_color"] = bg }
        if let opacity { cfg["background_opacity"] = opacity }
        let raw: [String: Any] = ["id": "r", "type": "row", "field_config": cfg,
                                  "children": [["id": "s", "type": "spacer", "height": 80]]]
        let data = try JSONSerialization.data(withJSONObject: [raw])
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: data)
        return ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16).frame(width: 393, height: 140).background(Color.white)
            .environment(\.googleAttributionBackdrop, .plain(hex: "#FFFFFF"))
    }

    private func near(_ r0: Int, _ g0: Int, _ b0: Int) -> (UInt8, UInt8, UInt8) -> Bool {
        { r, g, b in abs(Int(r) - r0) <= 8 && abs(Int(g) - g0) <= 8 && abs(Int(b) - b0) <= 8 }
    }

    func testAConsoleAuthoredRowFillDrawsAtItsOpacity() throws {
        let size = CGSize(width: 393, height: 140)
        let opaque = near(0x25, 0x63, 0xEB), half = near(0x92, 0xB1, 0xF5), quarter = near(0xC9, 0xD8, 0xFA)
        let none = try count(row(nil), size: size) { opaque($0, $1, $2) || half($0, $1, $2) || quarter($0, $1, $2) }
        let full = try count(row("#2563EB"), size: size, match: opaque)
        let halfN = try count(row("#2563EB", opacity: 0.5), size: size, match: half)
        let quarterN = try count(row("#2563EB80", opacity: 0.5), size: size, match: quarter)
        NSLog("[row-fill] none=\(none) full=\(full) half=\(halfN) quarter=\(quarterN)")
        XCTAssertLessThan(none, 50, "control: no fill draws none of the fill colours")
        XCTAssertGreaterThan(full, 5000, "an opaque row fill did not draw")
        XCTAssertGreaterThan(halfN, 5000, "a row fill at 0.5 did not draw at half")
        XCTAssertGreaterThan(quarterN, 5000, "a #RRGGBBAA fill at 0.5 is not a quarter")
    }
}
