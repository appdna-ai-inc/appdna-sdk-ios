// PartialTextStyleRenderTests.swift
//
// #1800 — RENDERED: a colour-only `text_style` keeps the element's default typography.
//
// The defect, as it reached a device: a generated paywall's header carried
// `style.elements.title.text_style = {"color": "#111827"}` (the server's contrast pass), and iOS drew
// the title at body size and regular weight while Android drew the large bold centred title.
//
// The claim is about pixels, so it is measured on pixels. The harness is `SocialProofRenderTests`':
// a real `PaywallRenderer` in a real key window, `layer.render(in:)`, PNG out.
//
// For each element: on a white page the unstyled colour is `PaywallTextDefaults.dark` (#111827), so a
// style that sets ONLY that colour must render PIXEL-IDENTICAL to no style at all. Before the fix it
// rendered at system 16pt regular, so the PNGs differed.
//
// 🔴 EVERY EQUALITY HAS ITS CONTROL. "Identical" proves nothing unless this harness can be shown to
// SEE a typography change on the same element — so each case also renders the same colour with an
// authored size/weight, and that one must differ. For the header title the control is quantified
// too: the ink a body-size title puts on the page must be well below the large bold default's.
//
// RED CONTROLS (each makes the named assertion fail):
//  - header title: in Paywalls/Components/HeaderSection.swift revert the title's
//        .applyTextStyle(ts, defaults: TextStyleDefaults(font: .title.bold(), size: 28, ...))
//    to `.applyTextStyle(ts)` → `testAColourOnlyHeaderTitleKeepsTheLargeBoldDefault` fails on
//    XCTAssertEqual(colourOnly, unstyled) and on the ink-count equality.
//  - guarantee title: in PaywallRenderer.swift revert `Text(loc("guarantee.title", title))
//    .applyTextStyle(ts, defaults: ...)` to `.applyTextStyle(ts)` →
//    `testAColourOnlyGuaranteeTitleKeepsItsDefault` fails on XCTAssertEqual.
//  - feature row: in Paywalls/Components/FeatureList.swift revert `Text(text).applyTextStyle(ts,
//    defaults: ...)` to `Text(text).applyTextStyle(ts)` → `testAColourOnlyFeatureRowKeepsItsDefault`
//    fails on XCTAssertEqual.
//  - CTA label: in Paywalls/Components/CTAButton.swift revert the button label's
//    `.applyTextStyle(ts, defaults: ...)` to `.applyTextStyle(ts)` →
//    `testAColourOnlyCTALabelKeepsItsDefault` fails on XCTAssertEqual.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PartialTextStyleRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    /// The first render in a process warms fonts, the window and the first layout pass, and is not
    /// pixel-comparable with later ones (see `SocialProofRenderTests.setUp`). Thrown away.
    override func setUp() async throws {
        try await super.setUp()
        _ = try? renderPNG(try config(sections: #"{ "type": "header", "config": { "title": "Warm up" } }"#))
    }

    private func config(sections: String) throws -> PaywallConfig {
        let json = """
        {
          "id": "render_partial_text_style",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [ \(sections) ]
          }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    /// `"style": { "elements": { "<key>": { "text_style": <ts> } } }`, or nothing when `ts` is nil.
    private func styleJSON(_ key: String, _ ts: String?) -> String {
        guard let ts else { return "" }
        return #", "style": { "elements": { "\#(key)": { "text_style": \#(ts) } } }"#
    }

    private func renderImage(_ config: PaywallConfig) throws -> UIImage {
        let view = PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)

        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .clear
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

    private func renderPNG(_ config: PaywallConfig) throws -> Data {
        try XCTUnwrap(try renderImage(config).pngData())
    }

    /// Pixels close to #111827 — the title's ink on a white page. A bigger, bolder title puts
    /// more of them down; that is the quantity a size/weight regression moves.
    private func darkInk(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4)
        where px[i] < 60 && px[i + 1] < 60 && px[i + 2] < 80 && px[i + 3] > 200 { n += 1 }
        return n
    }

    // MARK: - header title (the reported defect)

    private func header(_ ts: String?) throws -> PaywallConfig {
        try config(sections: """
        { "type": "header", "config": { "title": "Steady progress every single day" }\(styleJSON("title", ts)) }
        """)
    }

    func testAColourOnlyHeaderTitleKeepsTheLargeBoldDefault() throws {
        let unstyledImage = try renderImage(try header(nil))
        let colourOnlyImage = try renderImage(try header(#"{ "color": "#111827" }"#))
        // The control: same colour, the body-size regular typography the defect produced.
        let bodySizeImage = try renderImage(try header(#"{ "color": "#111827", "font_size": 16, "font_weight": 400 }"#))

        let unstyledInk = try darkInk(unstyledImage)
        let colourOnlyInk = try darkInk(colourOnlyImage)
        let bodySizeInk = try darkInk(bodySizeImage)
        NSLog("[partial-text-style header] unstyled=\(unstyledInk) colourOnly=\(colourOnlyInk) bodySize=\(bodySizeInk)")

        // Harness control first: it must SEE a size/weight difference on this element.
        XCTAssertNotEqual(
            unstyledImage.pngData(), bodySizeImage.pngData(),
            "THE CONTROL FAILED: a body-size title renders the same as the large bold default, so this "
            + "harness cannot see typography and the equality below would prove nothing")
        XCTAssertLessThan(
            Double(bodySizeInk), Double(unstyledInk) * 0.8,
            "THE CONTROL FAILED: a 16pt regular title should put far less ink down than the 28pt bold default")

        // The fix: a colour-only style is the unstyled title, pixel for pixel.
        XCTAssertEqual(
            colourOnlyImage.pngData(), unstyledImage.pngData(),
            "a colour-only text_style changed the header title's typography (#1800) — it must keep "
            + "the large bold centred default and change only the colour")
        XCTAssertEqual(colourOnlyInk, unstyledInk,
                       "the colour-only title's ink differs from the default title's (#1800)")
    }

    // MARK: - guarantee title (`.subheadline` semibold)

    private func guarantee(_ ts: String?) throws -> PaywallConfig {
        try config(sections: """
        { "type": "guarantee", "config": { "title": "Thirty day guarantee" }\(styleJSON("title", ts)) }
        """)
    }

    func testAColourOnlyGuaranteeTitleKeepsItsDefault() throws {
        let unstyled = try renderPNG(try guarantee(nil))
        let colourOnly = try renderPNG(try guarantee(#"{ "color": "#111827" }"#))
        let reweighted = try renderPNG(try guarantee(#"{ "color": "#111827", "font_size": 15, "font_weight": 400 }"#))

        XCTAssertNotEqual(unstyled, reweighted,
                          "THE CONTROL FAILED: a regular-weight guarantee title renders the same as the semibold default")
        XCTAssertEqual(colourOnly, unstyled,
                       "a colour-only text_style changed the guarantee title's typography (#1800)")
    }

    // MARK: - feature row (`.body`)

    private func features(_ ts: String?) throws -> PaywallConfig {
        try config(sections: """
        { "type": "features", "config": { "features": ["Track every session"] }\(styleJSON("item_text", ts)) }
        """)
    }

    func testAColourOnlyFeatureRowKeepsItsDefault() throws {
        let unstyled = try renderPNG(try features(nil))
        let colourOnly = try renderPNG(try features(#"{ "color": "#111827" }"#))
        let resized = try renderPNG(try features(#"{ "color": "#111827", "font_size": 13 }"#))

        XCTAssertNotEqual(unstyled, resized,
                          "THE CONTROL FAILED: a 13pt feature row renders the same as the body default")
        XCTAssertEqual(colourOnly, unstyled,
                       "a colour-only text_style changed the feature row's typography (#1800)")
    }

    // MARK: - CTA label (17pt semibold, white on the accent)

    private func cta(_ ts: String?) throws -> PaywallConfig {
        try config(sections: """
        { "type": "cta", "config": { "cta": { "text": "Continue" } }\(styleJSON("button", ts)) }
        """)
    }

    func testAColourOnlyCTALabelKeepsItsDefault() throws {
        let unstyled = try renderPNG(try cta(nil))
        let colourOnly = try renderPNG(try cta(#"{ "color": "#FFFFFF" }"#))
        let resized = try renderPNG(try cta(#"{ "color": "#FFFFFF", "font_size": 12 }"#))

        XCTAssertNotEqual(unstyled, resized,
                          "THE CONTROL FAILED: a 12pt CTA label renders the same as the 17pt semibold default")
        XCTAssertEqual(colourOnly, unstyled,
                       "a colour-only text_style changed the CTA label's typography (#1800)")
    }
}
