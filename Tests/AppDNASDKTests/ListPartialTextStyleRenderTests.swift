import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 — RENDERED through the real `ContentBlockRendererView`: a `list` whose `style` sets only a colour keeps
 the item's own 17pt default, as Android merges over its 17sp base. Before the fix a colour-only style redrew
 every item at the legacy 16pt.

 The oracle is an explicit `font_size: 17` with the same colour: it must draw the SAME ink as colour-only.
 THE CONTROL: `font_size: 16` must draw different ink, so the harness can see a one-point size change.
 RED CONTROL: revert `listBlock`'s `itemText.applyTextStyle(style, defaults: …)` to `.applyTextStyle(block.style)`
 — colour-only then draws 16pt, equals the control, and `testAColourOnlyListStyleKeepsThe17ptDefault` fails.
*/
@MainActor
final class ListPartialTextStyleRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 400)

    private func darkInk(_ style: String) throws -> Int {
        let json = """
        [{ "id": "ls", "type": "list", "items": ["Seven days in a row", "Thirty lessons done", "One streak kept"], "style": \(style) }]
        """
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data(json.utf8))
        let host = UIHostingController(rootView: ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light))
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var count = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] < 80 && px[i + 1] < 80 && px[i + 2] < 80 && px[i + 3] > 200 {
            count += 1
        }
        return count
    }

    func testAColourOnlyListStyleKeepsThe17ptDefault() throws {
        _ = try darkInk(##"{ "color": "#111111" }"##) // warm-up render
        let colourOnly = try darkInk(##"{ "color": "#111111" }"##)
        let explicit17 = try darkInk(##"{ "color": "#111111", "font_size": 17 }"##)
        let legacy16 = try darkInk(##"{ "color": "#111111", "font_size": 16 }"##)
        NSLog("[1805-list] colourOnly=\(colourOnly) explicit17=\(explicit17) legacy16=\(legacy16)")
        XCTAssertNotEqual(explicit17, legacy16, "harness control: a one-point size change must be visible")
        XCTAssertEqual(colourOnly, explicit17, "a colour-only list style must keep the item's 17pt default")
    }
}
