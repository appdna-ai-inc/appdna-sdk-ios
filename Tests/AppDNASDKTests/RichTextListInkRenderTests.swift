import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 RENDERED: unstyled `rich_text` and `list` on a dark fill (one dark section zone, on a white step), through
 the real `ContentBlockRendererView`. They must be drawn light, as text is. THE CONTROLS: the same block
 styled #FFFFFF draws near-white pixels and styled #111111 draws none, so the harness both sees white text
 and does not always see it.
*/
@MainActor
final class RichTextListInkRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 500)

    private func nearWhite(_ child: String) throws -> Int {
        let json = """
        [{ "id": "sec", "type": "section_background", "height": 480,
           "field_config": { "background_zones": [ { "weight": 1, "color": "#0F172A" } ], "content_arrangement": "center" },
           "stack_children": [ \(child) ] }]
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
        let w = cg.width, h = cg.height
        for y in stride(from: h / 10, to: h * 9 / 10, by: 1) {
            for x in stride(from: w / 10, to: w * 9 / 10, by: 2) {
                let i = (y * w + x) * 4
                if px[i] > 200, px[i + 1] > 200, px[i + 2] > 200 { count += 1 }
            }
        }
        return count
    }

    private func richText(_ style: String) -> String {
        #"{ "id": "rt", "type": "rich_text", "markdown_content": "WWWWWWWW WWWWWWWW WWWWWWWW"\#(style) }"#
    }
    private func list(_ style: String) -> String {
        #"{ "id": "ls", "type": "list", "items": ["WWWWWWWWWW", "WWWWWWWWWW", "WWWWWWWWWW"]\#(style) }"#
    }

    func testUnstyledRichTextOnADarkFillIsLight() throws {
        let dark = try nearWhite(richText(##", "base_style": { "color": "#111111" }"##))
        let white = try nearWhite(richText(##", "base_style": { "color": "#FFFFFF" }"##))
        let unstyled = try nearWhite(richText(""))
        NSLog("[rich-text-ink] dark=\(dark) white=\(white) unstyled=\(unstyled)")
        XCTAssertGreaterThan(white, dark + 100, "harness control")
        XCTAssertGreaterThan(unstyled, dark + 100, "unstyled rich_text on a dark fill is not light")
    }

    func testUnstyledListOnADarkFillIsLight() throws {
        let dark = try nearWhite(list(##", "style": { "color": "#111111" }"##))
        let white = try nearWhite(list(##", "style": { "color": "#FFFFFF" }"##))
        let unstyled = try nearWhite(list(""))
        NSLog("[list-ink] dark=\(dark) white=\(white) unstyled=\(unstyled)")
        XCTAssertGreaterThan(white, dark + 100, "harness control")
        XCTAssertGreaterThan(unstyled, dark + 100, "unstyled list on a dark fill is not light")
    }
}
