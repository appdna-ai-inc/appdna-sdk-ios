import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 RENDERED, through the real `ContentBlockRendererView`, with the step's backdrop handed down as a step hands
 it: an unstyled `warning_banner` (no `text_color`, no `bg_color`) on a light step draws its message in dark
 ink, on a dark step in white, and on its own dark `bg_color` in white. The icon is hidden so the only ink
 counted is the message's. THE CONTROLS: the colour authored each way draws, or does not draw, the pixels.
*/
@MainActor
final class WarningBannerInkRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 160)

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

    private func banner(text color: String?, bg: String? = nil) -> String {
        let tc = color.map { #", "text_color": "\#($0)""# } ?? ""
        let bc = bg.map { #", "bg_color": "\#($0)""# } ?? ""
        return #"{ "id": "wb", "type": "warning_banner", "text": "WWWWWWWW WWWWWWWW"\#(tc)\#(bc), "field_config": { "banner_variant": "warning", "banner_hide_icon": true } }"#
    }

    private let darkPx = { (r: UInt8, g: UInt8, b: UInt8) in r < 70 && g < 70 && b < 70 }
    private let whitePx = { (r: UInt8, g: UInt8, b: UInt8) in r > 225 && g > 225 && b > 225 }

    func testAnUnstyledBannerOnALightStepDrawsDarkInk() throws {
        let white = try count(banner(text: "#FFFFFF"), bg: "#FFFFFF", match: darkPx)
        let dark = try count(banner(text: "#111111"), bg: "#FFFFFF", match: darkPx)
        let unstyled = try count(banner(text: nil), bg: "#FFFFFF", match: darkPx)
        NSLog("[banner-ink light] white=\(white) dark=\(dark) unstyled=\(unstyled)")
        XCTAssertGreaterThan(dark, white + 100, "harness control: authored dark ink must draw dark pixels")
        XCTAssertGreaterThan(unstyled, white + 100, "an unstyled banner on a light step draws no dark ink")
    }

    func testAnUnstyledBannerOnADarkStepKeepsWhiteInk() throws {
        let dark = try count(banner(text: "#111111"), bg: "#0F1117", match: whitePx)
        let white = try count(banner(text: "#FFFFFF"), bg: "#0F1117", match: whitePx)
        let unstyled = try count(banner(text: nil), bg: "#0F1117", match: whitePx)
        NSLog("[banner-ink dark] dark=\(dark) white=\(white) unstyled=\(unstyled)")
        XCTAssertGreaterThan(white, dark + 100, "harness control")
        XCTAssertGreaterThan(unstyled, dark + 100, "an unstyled banner on a dark step lost its white ink")
    }

    func testAnAuthoredDarkFillOnALightStepKeepsWhiteInk() throws {
        let dark = try count(banner(text: "#111111", bg: "#1F2937"), bg: "#FFFFFF", match: whitePx)
        let white = try count(banner(text: "#FFFFFF", bg: "#1F2937"), bg: "#FFFFFF", match: whitePx)
        let unstyled = try count(banner(text: nil, bg: "#1F2937"), bg: "#FFFFFF", match: whitePx)
        NSLog("[banner-ink fill] dark=\(dark) white=\(white) unstyled=\(unstyled)")
        XCTAssertGreaterThan(white, dark + 100, "harness control")
        XCTAssertGreaterThan(unstyled, dark + 100, "an unstyled banner on its own dark fill lost its white ink")
    }
}
