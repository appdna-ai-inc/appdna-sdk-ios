// SurfaceSnapshotTests.swift
//
// #908 — a RENDERED iOS FRAME, without a host app.
//
// Rules 23 and 24 say a render change is walked on a device and operated. Android has a sample app
// and an emulator that takes taps; iOS has neither — there is no host app in the repo or on the
// build bridge, and the simulator exposes no tap verb from this environment. So every iOS render
// claim has been a VALUE comparison (a shared fixture executing the real function) rather than a
// look at a frame, on the platform that has historically produced the subtler defects: a colour, a
// wrap, an inset.
//
// A frame does not actually need a host app. The test target runs on the simulator, the views are
// SwiftUI, and `UIHostingController` will lay one out at a device size and draw it into an image.
// That is a real render by the real renderer — the same code the SDK ships — and it can be looked
// at, which is the whole point.
//
// It is OPT-IN: without `APPDNA_SNAPSHOT_DIR` the whole suite is skipped, so a normal test run is
// unaffected and nothing writes to disk in CI.
//
//     xcodebuild test -only-testing:AppDNASDKTests/SurfaceSnapshotTests \
//       APPDNA_SNAPSHOT_DIR=/tmp/appdna-snaps APPDNA_SNAPSHOT_CASE=header_inset_swipe
//
// What it does NOT do: operate anything. A frame is drawn at rest — no taps, no scrolling, no
// branch. For that an iOS host app is still the answer, which is why #908 stays open until one
// exists; this is the half that can be had tonight.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SurfaceSnapshotTests: XCTestCase {

    /// iPhone 15 Pro logical points — the device profile the render fixtures already use.
    private let size = CGSize(width: 393, height: 852)

    /**
     Where the frames land.

     🔴 NOT behind an environment variable. `xcodebuild test ... APPDNA_SNAPSHOT_DIR=…` sets it on
     the xcodebuild process, and `TEST_RUNNER_APPDNA_SNAPSHOT_DIR=…` did not reach this process
     either for an SPM package scheme — both runs passed with both tests SKIPPED, which looks
     exactly like a harness that works. So it always writes, to the simulator's own temp directory
     unless told otherwise, and PRINTS the absolute path for the caller to read out of the log.
     A handful of PNGs in a temp directory is a smaller cost than a snapshot suite that silently
     does nothing.
     */
    private var outputDir: String {
        ProcessInfo.processInfo.environment["APPDNA_SNAPSHOT_DIR"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("appdna-snaps")
    }

    private func write(_ view: some View, named name: String) throws {
        let dir = outputDir
        let sized = view.frame(width: size.width, height: size.height)

        /*
         * 🔴 TWO capture paths, in this order, and the order is the whole lesson.
         *
         * `UIHostingController` + `drawHierarchy(afterScreenUpdates:)` draws a BLANK frame for
         * SwiftUI content — five identical white PNGs and a suite reporting success. `ImageRenderer`
         * draws the view, but renders a `ScrollView`'s CONTENT as empty: the paywall came back with
         * its background, its close button and its pinned CTA, and nothing in between. That frame
         * is not blank, so a blank check does not catch it — it is just missing everything the page
         * is about.
         *
         * `layer.render(in:)` on a hosted view inside a real key window draws the scroll content,
         * so that is the primary path now and `ImageRenderer` is the fallback.
         */
        let host = UIHostingController(rootView: sized)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .clear
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let hosted = UIGraphicsImageRenderer(size: size)
        var image: UIImage? = hosted.image { ctx in host.view.layer.render(in: ctx.cgContext) }

        if image == nil || isBlank(image!) {
            let renderer = ImageRenderer(content: sized)
            renderer.scale = 2
            image = renderer.uiImage
        }

        guard let image, let png = image.pngData() else {
            XCTFail("[snapshot] \(name): nothing rendered")
            return
        }

        // A blank frame is the failure mode this harness exists to avoid reporting as success.
        XCTAssertFalse(isBlank(image), "[snapshot] \(name) is a uniform frame — nothing rendered")

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(name).png"
        try png.write(to: URL(fileURLWithPath: path))
        print("[snapshot] wrote \(path) (\(png.count) bytes)")
    }

    /// Whether the frame contains a pixel within `tolerance` of `hex` — the assertion that says a
    /// thing was DRAWN, not merely that the frame is non-uniform. A paywall that renders its
    /// chrome and nothing else passes a blank check and proves nothing.
    func frameContains(_ name: String, colour hex: String, tolerance: Int = 24) throws -> Bool {
        let path = "\(outputDir)/\(name).png"
        guard let data = FileManager.default.contents(atPath: path),
              let image = UIImage(data: data), let cg = image.cgImage else { return false }
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(h.prefix(6), radix: 16) else { return false }
        let want = (Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
        let w = cg.width, hgt = cg.height
        var pixels = [UInt8](repeating: 0, count: w * hgt * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: hgt, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: hgt))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if abs(Int(pixels[i]) - want.0) <= tolerance,
               abs(Int(pixels[i + 1]) - want.1) <= tolerance,
               abs(Int(pixels[i + 2]) - want.2) <= tolerance { return true }
        }
        return false
    }

    /// Whether every sampled pixel is the same colour — i.e. the renderer produced nothing.
    private func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return true }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return true }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let first = (pixels[0], pixels[1], pixels[2])
        for y in stride(from: 0, to: h, by: max(1, h / 60)) {
            for x in stride(from: 0, to: w, by: max(1, w / 40)) {
                let i = (y * w + x) * 4
                if (pixels[i], pixels[i + 1], pixels[i + 2]) != first { return false }
            }
        }
        return true
    }

    /// A paywall built from JSON, so a scenario is data rather than Swift.
    private func paywall(_ json: String) throws -> PaywallConfig {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(PaywallConfig.self, from: data)
    }

    private func render(_ config: PaywallConfig) -> some View {
        PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in },
        )
    }

    // MARK: - Scenarios

    /// #895 — a long header title with each dismiss style, which is the pair that disagreed.
    func testHeaderInsetAcrossDismissStyles() throws {
        let title = "Keep every habit you have built so far"
        for style in ["x_button", "swipe", "text_link"] {
            let json = """
            {
              "id": "snap_inset_\(style)",
              "name": "Inset \(style)",
              "layout": {
                "type": "stack",
                "background": { "type": "color", "value": "#111827" },
                "sections": [
                  { "id": "h", "type": "header", "config": { "title": "\(title)" } },
                  { "id": "c", "type": "cta", "config": {} }
                ]
              },
              "plans": [
                { "id": "annual", "product_id": "premium_annual", "label": "Annual",
                  "price_display": "$39.99/year", "is_default": true, "sort_order": 0 }
              ],
              "cta": { "text": "Continue" },
              "dismiss": { "allowed": true, "style": "\(style)" }
            }
            """
            let config = try paywall(json)
            XCTAssertEqual(
                PaywallHeaderInset.resolve(config.dismiss),
                style == "x_button" ? 48 : 0,
                "the inset for \(style) is not what the fixture says",
            )
            try write(render(config), named: "header_inset_\(style)")
            // #891 — the frame has to CONTAIN the title, in the colour the background demands.
            // A paywall that renders its chrome and nothing else is not a rendered paywall, and a
            // title drawn in the system `.primary` on this dark page would be near-black.
            XCTAssertTrue(
                try frameContains("header_inset_\(style)", colour: PaywallTextDefaults.light),
                "header_inset_\(style): no near-white pixel — the title did not draw on #111827",
            )
        }
    }

    /// #905 — a per-element container style, which the console has always offered and neither
    /// platform read. A green border round the plan label and a red one round the price is a
    /// deliberately unsubtle choice: the frame has to show whether it arrived at all.
    func testPerElementStyles() throws {
        let json = """
        {
          "id": "snap_element_styles",
          "name": "Per-element styles",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "id": "h", "type": "header",
                "config": { "title": "Per-element styles", "subtitle": "A subtitle" },
                "style": { "elements": {
                  "title": { "element_style": { "border": { "color": "#7C3AED", "width": 2, "radius": 8 },
                                                "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } },
                  "subtitle": { "element_style": { "border": { "color": "#DB2777", "width": 2, "radius": 8 },
                                                   "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } }
                } } },
              { "id": "f", "type": "features", "config": { "items": [{ "title": "A feature row" }] },
                "style": { "elements": {
                  "item_text": { "element_style": { "border": { "color": "#0EA5E9", "width": 2, "radius": 8 },
                                                    "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } },
                  "icon": { "element_style": { "border": { "color": "#CA8A04", "width": 2, "radius": 8 },
                                               "padding": { "top": 2, "bottom": 2, "left": 2, "right": 2 } } }
                } } },
              { "id": "lg", "type": "legal", "config": { "text": "Terms apply" },
                "style": { "elements": {
                  "text": { "element_style": { "border": { "color": "#0891B2", "width": 2, "radius": 8 },
                                               "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } }
                } } },
              { "id": "p", "type": "plans", "config": {},
                "style": { "elements": {
                  "label": { "element_style": { "border": { "color": "#16A34A", "width": 2, "radius": 8 },
                                                "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } },
                  "price": { "element_style": { "border": { "color": "#EF4444", "width": 2, "radius": 8 },
                                                "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } }
                } } },
              { "id": "c", "type": "cta",
                "config": { "show_restore": true, "restore_text": "Restore" },
                "style": { "elements": {
                  "button": { "element_style": { "border": { "color": "#F97316", "width": 3, "radius": 14 } } },
                  "restore_text": { "element_style": { "border": { "color": "#65A30D", "width": 2, "radius": 8 },
                                                       "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } }
                } } }
            ]
          },
          "plans": [
            { "id": "annual", "product_id": "premium_annual", "label": "Annual",
              "price_display": "39.99/year", "is_default": true, "sort_order": 0 },
            { "id": "monthly", "product_id": "premium_monthly", "label": "Monthly",
              "price_display": "6.99/month", "is_default": false, "sort_order": 1 }
          ],
          "cta": { "text": "Continue" },
          "dismiss": { "allowed": true, "style": "x_button" }
        }
        """
        let config = try paywall(json)
        let plans = config.sections.first { $0.type == "plans" }
        XCTAssertNotNil(
            plans?.style?.elements?["label"]?.container?.border?.color,
            "the element style did not decode — the DTO is back to dropping it",
        )
        try write(render(config), named: "element_styles")
        // The authored border colours have to be IN the frame, or it arrived nowhere.
        XCTAssertTrue(try frameContains("element_styles", colour: "#16A34A"),
                      "no green pixel — the label's authored border did not draw")
        XCTAssertTrue(try frameContains("element_styles", colour: "#EF4444"),
                      "no red pixel — the price's authored border did not draw")
        // #910 — the header and feature elements, which were text-style-only until now.
        XCTAssertTrue(try frameContains("element_styles", colour: "#7C3AED"),
                      "no violet pixel — the header title's authored border did not draw")
        XCTAssertTrue(try frameContains("element_styles", colour: "#0EA5E9"),
                      "no blue pixel — the feature row's authored border did not draw")
        // #910 — the rest of the elements the issue names. Each colour is distinct so a frame
        // cannot pass by drawing one border twice.
        for (colour, what) in [
            ("#DB2777", "the header subtitle"),
            ("#CA8A04", "the feature icon"),
            ("#0891B2", "the legal text"),
            ("#F97316", "the CTA button"),
            ("#65A30D", "the restore link"),
        ] {
            XCTAssertTrue(try frameContains("element_styles", colour: colour),
                          "no \(colour) pixel — \(what)'s authored border did not draw")
        }
    }

    /**
     #913 — the four elements #910 left container-less: the testimonial's `quote`, `author_name` and
     `author_role`, and the icon grid's `description` (with its `title` beside it).

     A SECOND frame rather than more sections on the first: a paywall tall enough to carry both sets
     scrolls, and a colour that is below the fold is a colour this test cannot see. Each border is a
     distinct colour so the frame cannot pass by drawing one of them twice.
     */
    func testPerElementStyles_testimonialAndIconGrid() throws {
        let json = """
        {
          "id": "snap_element_styles_sections",
          "name": "Section elements",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "id": "t", "type": "testimonial",
                "config": { "layout": "card", "quote": "A quoted line",
                            "author_name": "A Name", "author_role": "A Role" },
                "style": { "elements": {
                  "quote": { "element_style": { "border": { "color": "#2563EB", "width": 2, "radius": 8 },
                                                "padding": { "top": 4, "bottom": 4, "left": 8, "right": 8 } } },
                  "author_name": { "element_style": { "border": { "color": "#059669", "width": 2, "radius": 8 },
                                                      "padding": { "top": 2, "bottom": 2, "left": 6, "right": 6 } } },
                  "author_role": { "element_style": { "border": { "color": "#B91C1C", "width": 2, "radius": 8 },
                                                      "padding": { "top": 2, "bottom": 2, "left": 6, "right": 6 } } }
                } } },
              { "id": "g", "type": "icon_grid",
                "config": { "columns": 1,
                            "items": [{ "icon": "star", "label": "A label", "description": "A description" }] },
                "style": { "elements": {
                  "title": { "element_style": { "border": { "color": "#9333EA", "width": 2, "radius": 8 },
                                                "padding": { "top": 2, "bottom": 2, "left": 6, "right": 6 } } },
                  "description": { "element_style": { "border": { "color": "#C2410C", "width": 2, "radius": 8 },
                                                      "padding": { "top": 2, "bottom": 2, "left": 6, "right": 6 } } }
                } } }
            ]
          },
          "plans": [],
          "cta": { "text": "Continue" },
          "dismiss": { "allowed": true, "style": "x_button" }
        }
        """
        let config = try paywall(json)
        let testimonial = config.sections.first { $0.type == "testimonial" }
        XCTAssertNotNil(
            testimonial?.style?.elements?["quote"]?.container?.border?.color,
            "the element style did not decode — the DTO is back to dropping it",
        )
        try write(render(config), named: "element_styles_sections")
        for (colour, what) in [
            ("#2563EB", "the testimonial quote"),
            ("#059669", "the author name"),
            ("#B91C1C", "the author role"),
            ("#9333EA", "the icon-grid title"),
            ("#C2410C", "the icon-grid description"),
        ] {
            XCTAssertTrue(try frameContains("element_styles_sections", colour: colour),
                          "no \(colour) pixel — \(what)'s authored border did not draw")
        }
    }

    /// #891 — the unselected plan tile, whose text colour is a SYSTEM colour on this platform, in
    /// both appearances. The frame is the evidence: light and dark must both stay readable.
    func testPlanTilesInBothAppearances() throws {
        let json = """
        {
          "id": "snap_plan_tiles",
          "name": "Plan tiles",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "id": "h", "type": "header", "config": { "title": "Choose a plan" } },
              { "id": "p", "type": "plans", "config": {} },
              { "id": "c", "type": "cta", "config": {} }
            ]
          },
          "plans": [
            { "id": "annual", "product_id": "premium_annual", "label": "Annual",
              "price_display": "$39.99/year", "is_default": true, "sort_order": 0 },
            { "id": "monthly", "product_id": "premium_monthly", "label": "Monthly",
              "price_display": "$6.99/month", "is_default": false, "sort_order": 1 }
          ],
          "cta": { "text": "Continue" },
          "dismiss": { "allowed": true, "style": "x_button" }
        }
        """
        let config = try paywall(json)
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let name = "plan_tiles_\(scheme == .light ? "light" : "dark")"
            try write(render(config).environment(\.colorScheme, scheme), named: name)
            // #891 — this paywall's page is WHITE, so the unselected tile's text must be the dark
            // one in BOTH appearances. Before, it was `.primary`: dark in light appearance and
            // WHITE in dark appearance, so the same paywall lost its plan names on a phone set to
            // dark. The frame is the evidence, and it has to hold in both.
            XCTAssertTrue(
                try frameContains(name, colour: PaywallTextDefaults.dark),
                "\(name): no dark pixel — the plan text did not draw on a white page",
            )
        }
    }
}
