import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED, through the real `ContentBlockRendererView`, in a LIGHT appearance: a filled button on a dark fill
 with a Typography `style` that sets no colour (only a size) draws its label in the variant's white, as
 Android does — not the `.primary` the style used to bake in. An outline button does the same with its fill
 colour. THE CONTROLS: the label authored white / dark draws, or does not draw, the pixels.
*/
@MainActor
final class ButtonLabelInkRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 120)

    // Captured the way the committed goldens are (SnapshotTesting's `.image` strategy). A hosted
    // `layer.render` drew a SwiftUI `Button`'s fill and border but not its label, and `ImageRenderer` drew
    // every label black whatever colour was authored — both caught by the controls below, not by the fix.
    private func count(_ blockJSON: String, bg: String, match: (UInt8, UInt8, UInt8) -> Bool) throws -> Int {
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data("[\(blockJSON)]".utf8))
        let view = ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16)
            .frame(width: size.width, height: size.height).background(Color(hex: bg))
            .environment(\.googleAttributionBackdrop, .plain(hex: bg))
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

    private func button(text color: String?, variant: String = "primary") -> String {
        let tc = color.map { ##", "text_color": "\##($0)""## } ?? ""
        return ##"{ "id": "b", "type": "button", "text": "WWWWWWWW WWWW", "variant": "\##(variant)", "bg_color": "#111827"\##(tc), "style": { "font_size": 20 } }"##
    }
    private let whitePx = { (r: UInt8, g: UInt8, b: UInt8) in r > 225 && g > 225 && b > 225 }

    func testAStyleWithoutAColourKeepsTheFilledVariantsWhiteLabel() throws {
        let dark = try count(button(text: "#111111"), bg: "#0B1220", match: whitePx)
        let white = try count(button(text: "#FFFFFF"), bg: "#0B1220", match: whitePx)
        let styled = try count(button(text: nil), bg: "#0B1220", match: whitePx)
        NSLog("[button-ink filled] dark=\(dark) white=\(white) styled=\(styled)")
        XCTAssertGreaterThan(white, dark + 100, "harness control")
        XCTAssertGreaterThan(styled, dark + 100, "a colourless style overrode the filled variant's white label")
    }

    func testAStyleWithoutAColourKeepsTheOutlineVariantsFillColouredLabel() throws {
        // On a white step the outline label is the fill colour (#111827): dark pixels, not the system primary's
        // black — both are dark, so the assertion is on the colour: near #111827, not near #000000.
        let fillPx = { (r: UInt8, g: UInt8, b: UInt8) in abs(Int(r) - 0x11) < 6 && abs(Int(g) - 0x18) < 6 && abs(Int(b) - 0x27) < 6 }
        let black = try count(button(text: "#000000", variant: "outline"), bg: "#FFFFFF", match: fillPx)
        let fill = try count(button(text: "#111827", variant: "outline"), bg: "#FFFFFF", match: fillPx)
        let styled = try count(button(text: nil, variant: "outline"), bg: "#FFFFFF", match: fillPx)
        NSLog("[button-ink outline] black=\(black) fill=\(fill) styled=\(styled)")
        XCTAssertGreaterThan(fill, black + 100, "harness control")
        XCTAssertGreaterThan(styled, black + 100, "a colourless style overrode the outline variant's fill-coloured label")
    }
}
