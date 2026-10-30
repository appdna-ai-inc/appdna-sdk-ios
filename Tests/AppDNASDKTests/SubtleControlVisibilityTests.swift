// SubtleControlVisibilityTests.swift
//
// IS THE PAGER DOT ACTUALLY THERE ON A LIGHT PAGE? Rendered, and counted.
//
// `ReviewsCarouselView` drew its dots as `Color.white` and `Color.white.opacity(0.3)`. Over a
// WHITE page that is no dots at all, so a reader had no way to tell how many reviews there were or
// which one they were on. Android carried the identical constant in three places and its
// recorded pixels said what it costs there — a reviews carousel on a `#FFFFFF` page came back
// 0 non-white pixels of 780×444, a blank white rectangle.
//
// 🔴 THE INSTRUMENT IS THE ONE THE STORE-PRICE TESTS ARRIVED AT, FOR THE SAME REASON. Reading the accessibility
// tree came back `Drew: []` there — SwiftUI builds it lazily and a hostless test never triggers it
// — so what is compared is RENDERS, through `layer.render(in:)` on a hosted view inside a real key
// window. Dots are not text; there is nothing to read but pixels.
//
// 🔴 WHAT IS COUNTED. Not "pixels that differ from the page": Android's first attempt did that and
// passed against the broken code at a ratio of 0.989, because cards and chrome drowned a handful of
// white-on-white dots. This counts the ink the fix SPECIFICALLY introduces — near-achromatic
// pixels darker than the page. Every page-derived colour here descends from `#111827`, so each one
// lands in that band; the broken code puts nothing there, because its whites stay white.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SubtleControlVisibilityTests: XCTestCase {

    private let size = CGSize(width: 393, height: 300)

    // MARK: - The document

    /// A reviews carousel on a page of `pageHex` with `reviews` reviews, no colours authored —
    /// the document an author produces by choosing a background and touching nothing else.
    ///
    /// 🔴 THE COUNT IS THE INSTRUMENT. A `TabView` shows ONE review at a time, so two documents
    /// that differ only in how many reviews they hold draw the same text and a different number of
    /// DOTS. Measuring one render cannot isolate them — the quote and author are `.secondary`,
    /// which is already dark on a light page, and they swamped the dots: the first version of this
    /// test PASSED against the broken code because the text alone cleared its floor. The
    /// difference between the two renders is the dots and nothing else.
    private func carousel(on pageHex: String, reviews reviewCount: Int = 3) throws -> PaywallConfig {
        let json = """
        {
          "id": "pw_subtle",
          "name": "Subtle controls",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "\(pageHex)" },
            "sections": [{
              "type": "reviews_carousel",
              "id": "sec_reviews",
              "config": {
                "auto_scroll": false,
                "show_rating_stars": false,
                "reviews": [\(reviewsJSON(reviewCount))]
              }
            }]
          }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    /// Every review carries the SAME text, so only the dot count can differ between two renders.
    private func reviewsJSON(_ count: Int) -> String {
        (0..<count)
            .map { #"{ "id": "r\#($0)", "text": "A short quote about the app", "author": "A. Reader" }"# }
            .joined(separator: ",")
    }

    // MARK: - The measurement

    private func render(_ config: PaywallConfig) throws -> UIImage {
        let view = PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)

        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        return UIGraphicsImageRenderer(size: size).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
    }

    /// Near-achromatic pixels darker than white — the band every `#111827`-derived colour lands in.
    private func darkAchromaticInk(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var ink = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2]), a = Int(bytes[i + 3])
            if a == 0 { continue }
            let achromatic = abs(r - g) <= 10 && abs(g - b) <= 12 && abs(r - b) <= 14
            if achromatic && r <= 225 { ink += 1 }
        }
        return ink
    }

    // MARK: - The tests

    /// A 6pt dot at @3x covers ~250px, so four of them are ~1,000 — a floor of 300 is well under
    /// what four dots must contribute and well over antialiasing noise between two renders.
    private let visibleFloor = 300

    func testThePagerDotsAreOnTheScreenOnAWhitePage() throws {
        let twoDots = try darkAchromaticInk(try render(try carousel(on: "#FFFFFF", reviews: 2)))
        let sixDots = try darkAchromaticInk(try render(try carousel(on: "#FFFFFF", reviews: 6)))

        // The text is identical in both — a TabView draws one review — so the delta is four dots.
        XCTAssertGreaterThanOrEqual(
            sixDots - twoDots, visibleFloor,
            "six dots drew \(sixDots) page-derived pixels and two drew \(twoDots): a difference of "
            + "\(sixDots - twoDots) for four extra dots. They are white on a white page, so they "
            + "are not on the screen — the reader cannot tell how many reviews there are",
        )

        // And the section itself is there, or the delta above is a difference between two blanks.
        XCTAssertGreaterThan(twoDots, visibleFloor, "the carousel drew nothing at all on a white page")
    }

    /**
     🔴 THE CONTROL FOR THE CONTROL. "There is dark ink on a white page" would also be satisfied by
     a renderer that draws dark ink everywhere regardless, which would be a different defect with
     the same green. On a DARK page the same document must put almost none of it there — because
     `readable` resolves to white and the section is drawn in white, exactly as it shipped.
     */
    func testTheSameCarouselDrawsWhiteInkOnADarkPage() throws {
        let onDark = try render(try carousel(on: "#0B1220"))

        /*
         🔴 NEAR-WHITE ink, not "not-dark" ink. The first version of this assertion counted
         dark-achromatic pixels on the dark page and expected almost none — and got 15,326, because
         `#0B1220` is ITSELF a dark near-achromatic colour and the page is most of the image. The
         band that identifies the fix on a white page identifies the BACKGROUND on a dark one. What
         the dark page must show is that the section is drawn in WHITE, exactly as it shipped.
        */
        let white = try nearWhiteInk(onDark)
        XCTAssertGreaterThan(
            white, 1000,
            "a DARK page drew only \(white) near-white pixels — the section is no longer resolving "
            + "to white there, which would change every live dark paywall",
        )

        /*
         And that white is INK rather than a background. Comparing the two pages' white-pixel
         counts was the first attempt and it is meaningless — a white page is ~1,046,000 near-white
         pixels because it is white. What distinguishes ink is that it is a small part of the
         screen: the dark render came back 184,473 of 1,061,100, about 17%.
        */
        let total = Int(size.width * 3) * Int(size.height * 3)
        XCTAssertLessThan(
            white, total / 2,
            "nearly the whole dark render is near-white (\(white) of ~\(total)) — that is a page, "
            + "not ink on one",
        )
    }

    /// Pixels at or near white — the ink a dark paywall is drawn in, and has always been drawn in.
    private func nearWhiteInk(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where Int(bytes[i + 3]) != 0 {
            if bytes[i] >= 200 && bytes[i + 1] >= 200 && bytes[i + 2] >= 200 { n += 1 }
        }
        return n
    }


    /**
     🔴 THE PROMISE THAT MAKES THE CHANGE SAFE TO SHIP: on a dark page the resolved colour IS the
     constant it replaced, so every live dark paywall draws the pixels it drew before. Asserted on
     the policy function, because a render cannot say "identical to what this used to be".

     The same two assertions exist in Android's `SubtleControlPolicyTest`, on the same hexes.
     */
    func testADarkPageResolvesToExactlyTheConstantThisReplaced() {
        XCTAssertEqual(PaywallTextDefaults.readableHex(on: "#0B1220"), "#FFFFFF",
                       "a dark page must still resolve to white")
        XCTAssertEqual(PaywallTextDefaults.subtleAlpha, 0.3,
                       "and at the same alpha the constant used")
        XCTAssertNotEqual(PaywallTextDefaults.readableHex(on: "#FFFFFF"), "#FFFFFF",
                          "a white page must NOT resolve to white, or the fix is a no-op")
    }
}
