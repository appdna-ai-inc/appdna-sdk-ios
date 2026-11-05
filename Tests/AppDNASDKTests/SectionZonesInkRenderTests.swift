import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 RENDERED: unstyled text inside a section_background with dark zones, on a white step, through the real
 `ContentBlockRendererView`. The text must be drawn light (near-white pixels appear on the dark zone).
 THE CONTROLS: the text styled #111111 draws no near-white pixels and styled #FFFFFF does, so the harness
 both sees white text and does not always see it.
*/
@MainActor
final class SectionZonesInkRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 500)

    private func nearWhitePixels(textStyle: String) throws -> Int {
        let json = """
        [{ "id": "sec", "type": "section_background", "height": 480,
           "field_config": { "background_zones": [ { "weight": 1, "color": "#1E1B4B" }, { "weight": 1, "color": "#312E81" } ],
                             "content_arrangement": "center" },
           "stack_children": [ { "id": "t", "type": "heading", "text": "WWWWWWWW WWWWWWWW", "level": 1\(textStyle) } ] }]
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
        // Only inside the section's dark area: a pixel near-white AND with a dark neighbour band is text, not the page.
        var count = 0
        let w = cg.width, h = cg.height
        for y in stride(from: h / 10, to: h * 9 / 10, by: 1) {
            for x in stride(from: w / 10, to: w * 9 / 10, by: 2) {
                let i = (y * w + x) * 4
                if px[i] > 220, px[i + 1] > 220, px[i + 2] > 220 { count += 1 }
            }
        }
        return count
    }

    func testUnstyledTextOnDarkZonesIsDrawnLight() throws {
        let control = try nearWhitePixels(textStyle: ##", "style": { "color": "#111111" }"##)
        let visible = try nearWhitePixels(textStyle: ##", "style": { "color": "#FFFFFF" }"##)
        let unstyled = try nearWhitePixels(textStyle: "")
        NSLog("[section-zones-ink] near-white pixels: styled-dark control=\(control) styled-white=\(visible) unstyled=\(unstyled)")
        XCTAssertGreaterThan(visible, control + 200, "THE HARNESS CONTROL: white-styled text is not seen (\(visible))")
        XCTAssertGreaterThan(unstyled, control + 200, "unstyled text on dark zones was not drawn light (control \(control), unstyled \(unstyled))")
    }
}
