import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 RENDERED, through the real `ContentBlockRendererView` on a step whose backdrop is handed down as Android's
 `LocalGoogleAttributionBackdrop` is: unstyled stacked `input_select` option labels on a dark step must be
 light; an unstyled `summary_screen` headline on a cream step must be dark. THE CONTROLS: the colour authored
 the expected way draws the pixels, and authored the other way does not.
*/
@MainActor
final class OptionAndSummaryInkRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 300)

    private func count(_ blockJSON: String, bg: String, match: (UInt8, UInt8, UInt8) -> Bool) throws -> Int {
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: Data("[\(blockJSON)]".utf8))
        let host = UIHostingController(rootView: ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16)
            .frame(width: size.width, height: size.height).background(Color(hex: bg))
            .environment(\.googleAttributionBackdrop, .plain(hex: bg))
            .environment(\.colorScheme, .light))
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
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where match(px[i], px[i + 1], px[i + 2]) { n += 1 }
        return n
    }

    private func select(_ color: String?) -> String {
        let tc = color.map { #", "text_color": "\#($0)""# } ?? ""
        return #"{ "id": "sel", "type": "input_select", "field_id": "goal", "field_options": [ { "value": "a", "label": "WWWWWWWWWW" }, { "value": "b", "label": "WWWWWWWWWW" } ], "field_config": { "display_style": "stacked"\#(tc) } }"#
    }
    private func summary(_ color: String?) -> String {
        let tc = color.map { #", "text_color": "\#($0)""# } ?? ""
        return #"{ "id": "sum", "type": "summary_screen", "text": "WWWWWWWW WWWW"\#(tc) }"#
    }

    func testUnstyledOptionLabelsOnADarkStepAreLight() throws {
        let white = { (r: UInt8, g: UInt8, b: UInt8) in r > 200 && g > 200 && b > 200 }
        let dark = try count(select("#111111"), bg: "#0B1220", match: white)
        let light = try count(select("#FFFFFF"), bg: "#0B1220", match: white)
        let unstyled = try count(select(nil), bg: "#0B1220", match: white)
        NSLog("[option-ink] dark=\(dark) white=\(light) unstyled=\(unstyled)")
        XCTAssertGreaterThan(light, dark + 100, "harness control")
        XCTAssertGreaterThan(unstyled, dark + 100, "unstyled option labels on a dark step are not light")
    }

    func testAnUnstyledSummaryHeadlineOnCreamIsDark() throws {
        let black = { (r: UInt8, g: UInt8, b: UInt8) in r < 60 && g < 60 && b < 60 }
        let white = try count(summary("#FFFFFF"), bg: "#FFF8EC", match: black)
        let dark = try count(summary("#111111"), bg: "#FFF8EC", match: black)
        let unstyled = try count(summary(nil), bg: "#FFF8EC", match: black)
        NSLog("[summary-ink] white=\(white) black=\(dark) unstyled=\(unstyled)")
        XCTAssertGreaterThan(dark, white + 100, "harness control")
        XCTAssertGreaterThan(unstyled, white + 100, "unstyled summary headline on cream is not dark")
    }
}
