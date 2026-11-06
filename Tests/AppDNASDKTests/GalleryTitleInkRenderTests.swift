import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED, through the real `ContentBlockRendererView`: a `media_gallery` title with no `gallery_title_color`
 takes the unstyled ink for what is behind it — dark on a light step (it was white, invisible there), light on a
 dark step. THE CONTROLS: the title authored white / dark draws, or does not draw, the pixels.
*/
@MainActor
final class GalleryTitleInkRenderTests: XCTestCase {
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

    private func gallery(_ color: String?, bg: String) throws -> some View {
        var raw: [String: Any] = ["id": "g", "type": "media_gallery", "gallery_title": "WWWWWWWW WWWW",
                                  "gallery_images": ["https://example.invalid/a.png"]]
        if let color { raw["gallery_title_color"] = color }
        let blocks = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: [raw]))
        return ContentBlockRendererView(blocks: blocks, onAction: { _, _ in }, toggleValues: .constant([:]), inputValues: .constant([:]))
            .padding(16).frame(width: 393, height: 260).background(Color(hex: bg))
            .environment(\.googleAttributionBackdrop, .plain(hex: bg))
    }

    private let size = CGSize(width: 393, height: 260)
    private let white = { (r: UInt8, g: UInt8, b: UInt8) in r > 225 && g > 225 && b > 225 }
    private let black = { (r: UInt8, g: UInt8, b: UInt8) in r < 70 && g < 70 && b < 70 }

    func testAnUnstyledGalleryTitleOnALightStepIsDark() throws {
        let light = try count(gallery("#FFFFFF", bg: "#FFFFFF"), size: size, match: black)
        let dark = try count(gallery("#111111", bg: "#FFFFFF"), size: size, match: black)
        let unstyled = try count(gallery(nil, bg: "#FFFFFF"), size: size, match: black)
        NSLog("[gallery-title light] white=\(light) dark=\(dark) unstyled=\(unstyled)")
        XCTAssertGreaterThan(dark, light + 100, "harness control")
        XCTAssertGreaterThan(unstyled, light + 100, "an unstyled gallery title on a light step is not dark")
    }

    func testAnUnstyledGalleryTitleOnADarkStepIsLight() throws {
        let dark = try count(gallery("#111111", bg: "#0F1117"), size: size, match: white)
        let light = try count(gallery("#FFFFFF", bg: "#0F1117"), size: size, match: white)
        let unstyled = try count(gallery(nil, bg: "#0F1117"), size: size, match: white)
        NSLog("[gallery-title dark] dark=\(dark) white=\(light) unstyled=\(unstyled)")
        XCTAssertGreaterThan(light, dark + 100, "harness control")
        XCTAssertGreaterThan(unstyled, dark + 100, "an unstyled gallery title on a dark step is not light")
    }
}
