import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 RENDERED through the real `ContentBlockRendererView`: a `list` on its own card (`block_style.background_color`) with
 `element_width: "100%"` draws a card as wide as the row, as Android and the console preview do. Before the fix the
 card was drawn around the hugging VStack, so it was only as wide as the longest item, whatever the width said.

 Measured as the right-most column of the card's colour.
 THE CONTROL: the same list with no width still hugs its rows, so the harness can tell a hugging card from a full one.
 RED CONTROL: drop the `.frame(maxWidth: listFillsWidth(...))` in `listBlock` and `testASizedListCardFillsTheRow` fails.
*/
@MainActor
final class ListCardWidthRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 300)

    /// The right-most x (in points) of a pure-red pixel, or -1.
    private func cardRightEdge(width: String?) throws -> Int {
        let widthJSON = width.map { #", "element_width": "\#($0)""# } ?? ""
        let json = """
        [{ "id": "ls", "type": "list", "list_style": "check", "items": ["Short", "A bit longer row"],
           "style": { "color": "#111111" },
           "block_style": { "background_color": "#FF0000", "padding_top": 12, "padding_bottom": 12, "padding_left": 12, "padding_right": 12 },
           "horizontal_align": "left"\(widthJSON) }]
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
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var right = -1
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4
                if px[i] > 220 && px[i + 1] < 40 && px[i + 2] < 40 && x > right { right = x }
            }
        }
        return right
    }

    func testASizedListCardFillsTheRow() throws {
        _ = try cardRightEdge(width: nil) // warm-up render
        let hugging = try cardRightEdge(width: nil)
        let filled = try cardRightEdge(width: "100%")
        NSLog("[list-card] hugging=\(hugging) filled=\(filled) row=\(Int(size.width))")
        XCTAssertGreaterThan(hugging, 0, "harness control: the card colour must be visible")
        XCTAssertLessThan(hugging, Int(size.width) - 120, "harness control: an unsized list hugs its rows")
        XCTAssertGreaterThan(filled, Int(size.width) - 60, "a list authored 100% wide draws its card across the row")
    }

    func testOnlyAnAuthoredWidthFills() {
        XCTAssertFalse(listFillsWidth(nil))
        XCTAssertFalse(listFillsWidth("auto"))
        XCTAssertTrue(listFillsWidth("100%"))
        XCTAssertTrue(listFillsWidth("fill"))
        XCTAssertTrue(listFillsWidth("80%"))
    }
}
