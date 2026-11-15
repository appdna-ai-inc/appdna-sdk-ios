// FacebookMarkImageTests.swift
//
// Meta's two Facebook marks ship in the SDK bundle UNMODIFIED and are decoded at a reduced size. These
// read the decoded pixels back, so "the right file, the right colour, not 17 MB" is observed, not assumed.
import XCTest
import UIKit
@testable import AppDNASDK

final class FacebookMarkImageTests: XCTestCase {

    /// RGBA of one pixel, at a fraction of the image's width and height.
    private func pixel(_ image: UIImage, _ fx: CGFloat, _ fy: CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
        let cg = image.cgImage!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = CGFloat(cg.width) * fx, y = CGFloat(cg.height) * fy
        ctx.draw(cg, in: CGRect(x: -x, y: -(CGFloat(cg.height) - y - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    func testBothMarksDecodeSmallFromTheBundle() throws {
        for v in [FacebookMark.Variant.primary, .secondary] {
            let img = try XCTUnwrap(FacebookMarkImage.image(v), "\(v.resourceName).png did not load from the SDK bundle")
            let cg = try XCTUnwrap(img.cgImage)
            XCTAssertLessThanOrEqual(max(cg.width, cg.height), 96, "decoded at full size — 17 MB for a 20pt mark")
            XCTAssertGreaterThanOrEqual(min(cg.width, cg.height), 60, "too small for 20pt at 3x")
        }
    }

    /// The circle just below its top edge: Facebook Blue on the primary mark, white on the secondary.
    /// 🔴 The two must DIFFER there — a loader that returned the same file for both would pass a
    /// per-image "it loaded" check and draw the wrong mark on half the buttons.
    func testPrimaryIsBlueAndSecondaryIsWhite() throws {
        let p = pixel(try XCTUnwrap(FacebookMarkImage.image(.primary)), 0.5, 0.1)
        let s = pixel(try XCTUnwrap(FacebookMarkImage.image(.secondary)), 0.5, 0.1)
        XCTAssertEqual(p.a, 255)
        XCTAssertTrue(p.b > 200 && p.r < 60, "primary should be Facebook Blue, got \(p)")
        XCTAssertTrue(s.r > 240 && s.g > 240 && s.b > 240, "secondary should be white, got \(s)")
    }

    /// The "f" itself: white on the primary mark, transparent on the secondary — Meta's two expressions.
    func testTheFIsWhiteOnPrimaryAndTransparentOnSecondary() throws {
        // A point inside the f's stem, below its crossbar.
        let p = pixel(try XCTUnwrap(FacebookMarkImage.image(.primary)), 0.47, 0.8)
        let s = pixel(try XCTUnwrap(FacebookMarkImage.image(.secondary)), 0.47, 0.8)
        XCTAssertTrue(p.r > 240 && p.g > 240 && p.b > 240 && p.a == 255, "primary f should be white, got \(p)")
        XCTAssertLessThan(s.a, 20, "secondary f should be transparent, got \(s)")
    }
}
