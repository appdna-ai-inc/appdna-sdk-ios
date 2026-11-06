import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED, through the real `ContentBlockRendererView`: an unstyled multi-pick dropdown Select on a dark step
 (light appearance) draws its placeholder and chevron in light ink. THE CONTROL: with an authored light field
 fill on the same step it draws dark ink and none of that white.
*/
@MainActor
final class DropdownFieldInkRenderTests: XCTestCase {
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

    private func select(fill: String?) throws -> some View {
        var raw: [String: Any] = ["id": "sel", "type": "input_select", "field_id": "goal", "multi_select": true,
                                  "field_placeholder": "WWWWWWWW WWWW", "field_options": [["value": "a", "label": "A"]]]
        if let fill { raw["field_style"] = ["background_color": fill] }
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: [raw]))
        return ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16).frame(width: 393, height: 120).background(Color(hex: "#0B1220"))
            .environment(\.googleAttributionBackdrop, .plain(hex: "#0B1220"))
    }

    func testAnUnstyledMultiDropdownOnADarkStepDrawsLightInk() throws {
        let size = CGSize(width: 393, height: 120)
        // The light placeholder ink (white at 0.6 over the step), not the #D1D5DB border.
        let white = { (r: UInt8, g: UInt8, b: UInt8) in (130...195).contains(r) && (130...195).contains(g) && (130...200).contains(b) }
        // Dark ink (the placeholder is `.secondary` grey), not the step behind the field (#0B1220).
        let dark = { (r: UInt8, g: UInt8, b: UInt8) in r < 170 && g < 170 && b < 180 && !(abs(Int(r) - 11) <= 4 && abs(Int(g) - 18) <= 4 && abs(Int(b) - 32) <= 4) }
        let filledInk = try count(select(fill: "#F9FAFB"), size: size, match: dark)
        let unstyled = try count(select(fill: nil), size: size, match: white)
        NSLog("[dropdown-ink] filled-dark-ink=\(filledInk) unstyled-light=\(unstyled)")
        XCTAssertGreaterThan(filledInk, 100, "harness control: a light-filled field draws dark ink")
        // Before the fix: 124 (antialiasing of the near-black text); after: 6114.
        XCTAssertGreaterThan(unstyled, 1000, "an unstyled dropdown on a dark step draws no light ink")
    }
}
