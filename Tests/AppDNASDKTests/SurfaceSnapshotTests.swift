// SurfaceSnapshotTests.swift
//
// A RENDERED iOS FRAME, without a host app.
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
// branch. For that an iOS host app is still the answer, which is what the host app's UI tests
// cover; this is the half that needs no host.
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

    /**
     How many pixels in the frame are DARK (`r`, `g`, `b` all below 120) — the same measure
     Android's light-page corpus is counted with, so the two platforms can be compared by number
     rather than by eye.

     🔴 It exists because the frames themselves do not survive. `write` puts them in the
     SIMULATOR's temp directory, which is cleaned after the run, and `APPDNA_SNAPSHOT_DIR` does not
     reach this process for an SPM package scheme (see `outputDir`). A count printed into the test
     log outlives the file, so "what did it draw" is answerable afterwards instead of only during.
     */
    func darkPixelCount(_ name: String) throws -> Int {
        let path = "\(outputDir)/\(name).png"
        guard let data = FileManager.default.contents(atPath: path),
              let image = UIImage(data: data), let cg = image.cgImage else { return -1 }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] < 120, pixels[i + 1] < 120, pixels[i + 2] < 120 { dark += 1 }
        }
        return dark
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

    /**
     A PARTICLE EFFECT AUTHORED `on_purchase` DRAWS.

     Both overlays used to gate twice: the parent decided when to show the overlay, and the overlay
     then re-checked the authored trigger and refused anything that was not `on_appear`. So the
     paywall armed its celebration after a purchase and `ConfettiOverlay.onAppear` declined to start
     it — `startAnimation()` had exactly one live caller and it never fired. Three of the four
     triggers the console offers, and the docs describe, had never done anything.

     🔴 THE PROOF COULD NOT BE A DEVICE WALK, so it is a render (Rule 25). The moment this effect
     exists for is a completed purchase, the simulator serves no StoreKit catalogue under
     `xcodebuild test` and there is no device proof of a real purchase yet. What a
     render CAN do is put the overlay on a key window with the authored trigger and read the pixels
     back — which is the whole assertion, because the trigger is the only thing that changed.

     The authored colour is a single flat `#00FF00`, which nothing else on the frame can produce,
     and `intensity: heavy` asks for 120 of them. `duration_ms` is deliberately long: the particles
     animate to `opacity: 0` at the bottom of the screen, so a short effect could legitimately be
     finished by the time the frame is taken and the test would be measuring the end of the
     animation rather than the gate.
     */
    func testAParticleEffectAuthoredOnPurchaseDraws() throws {
        /*
         🔴 A STATIC CAPTURE CANNOT SEE CONFETTI, and the first version of this test proved it by
         failing on all four triggers — `on_appear` included, which has worked since the overlay
         shipped. `write` renders `host.view.layer`, which holds MODEL values, and `startAnimation`
         sets the model to the animation's END in the same turn it creates the particles: y is
         `screenHeight + 50` and opacity is 0. The initial values are no better — y is -20, above
         the frame. Confetti is only on screen mid-flight, so only an in-flight frame can show it.

         `layer.presentation()` is that frame: the layer tree with the values CoreAnimation is
         drawing right now. Same renderer, same view, one rung lower.
        */
        func inFlightFrame(of view: some View, named name: String) throws {
            let sized = view.frame(width: size.width, height: size.height)
            let host = UIHostingController(rootView: sized)
            host.view.bounds = CGRect(origin: .zero, size: size)
            host.view.backgroundColor = .clear
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // Long enough for `onAppear` to have run and the animation to be a fifth of a second
            // in; short enough that a 20-second effect is nowhere near its end.
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))

            let layer = host.view.layer.presentation() ?? host.view.layer
            let image = UIGraphicsImageRenderer(size: size).image { ctx in layer.render(in: ctx.cgContext) }
            guard let png = image.pngData() else { XCTFail("[snapshot] \(name): nothing rendered"); return }
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
            print("[snapshot] wrote \(outputDir)/\(name).png (\(png.count) bytes)")
        }

        func overlay(trigger: String) -> some View {
            ZStack {
                Color.black
                ConfettiOverlay(effect: ParticleEffect(
                    type: "confetti",
                    trigger: trigger,
                    duration_ms: 20000,
                    intensity: "heavy",
                    colors: ["#00FF00"],
                ))
            }
        }

        // 🔴 The control FIRST, and it is inside the same test on purpose: a harness that cannot
        // see green at all would pass every assertion below for the worst possible reason.
        // The control goes through the SAME capture: a harness that cannot see green at all would
        // pass every assertion below for the worst possible reason.
        try inFlightFrame(
            of: ZStack { Color.black; Text("control").foregroundColor(.white) },
            named: "confetti_control_none",
        )
        XCTAssertFalse(
            try frameContains("confetti_control_none", colour: "#00FF00"),
            "the control frame already contains the authored colour — this harness cannot tell",
        )

        for trigger in ["on_appear", "on_purchase", "on_step_complete", "on_flow_complete"] {
            let name = "confetti_\(trigger)"
            try inFlightFrame(of: overlay(trigger: trigger), named: name)
            XCTAssertTrue(
                try frameContains(name, colour: "#00FF00", tolerance: 60),
                "a particle effect authored \(trigger) drew nothing — the overlay re-gated its trigger",
            )
        }
    }


    /// A long header title with each dismiss style, which is the pair that disagreed.
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
            // The frame has to CONTAIN the title, in the colour the background demands.
            // A paywall that renders its chrome and nothing else is not a rendered paywall, and a
            // title drawn in the system `.primary` on this dark page would be near-black.
            XCTAssertTrue(
                try frameContains("header_inset_\(style)", colour: PaywallTextDefaults.light),
                "header_inset_\(style): no near-white pixel — the title did not draw on #111827",
            )
        }
    }

    /// A per-element container style, which the console has always offered and neither
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
        // The header and feature elements, which were text-style-only until now.
        XCTAssertTrue(try frameContains("element_styles", colour: "#7C3AED"),
                      "no violet pixel — the header title's authored border did not draw")
        XCTAssertTrue(try frameContains("element_styles", colour: "#0EA5E9"),
                      "no blue pixel — the feature row's authored border did not draw")
        // The rest of the elements the issue names. Each colour is distinct so a frame
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
     The four elements left container-less: the testimonial's `quote`, `author_name` and
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

    /// The unselected plan tile, whose text colour is a SYSTEM colour on this platform, in
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
            // This paywall's page is WHITE, so the unselected tile's text must be the dark
            // one in BOTH appearances. Before, it was `.primary`: dark in light appearance and
            // WHITE in dark appearance, so the same paywall lost its plan names on a phone set to
            // dark. The frame is the evidence, and it has to hold in both.
            XCTAssertTrue(
                try frameContains(name, colour: PaywallTextDefaults.dark),
                "\(name): no dark pixel — the plan text did not draw on a white page",
            )
        }
    }

    /*
     * EVERY plan display style the Console offers, RENDERED on a white page.
     *
     * 🔴 This instrument did not exist on iOS. `grep -c plan_display_style` over both iOS snapshot
     * suites returned 0, so the harness that found a three-defect cluster on Android — a selected
     * card whose 16%-white fill vanished, and the name and price with it — had no iOS counterpart.
     * An argued equivalent proof stood in for it; this replaces the
     * argument with pixels.
     *
     * The list is the CONSOLE's picker, read off `SectionContentEditor.tsx`, not iOS's `switch`.
     * Reading the switch would only assert that iOS agrees with itself: a style an author can pick
     * and iOS falls through on is exactly a defect found before, and it draws the vertical stack
     * rather than nothing, so the frame alone cannot report it. What this asserts is the weaker and
     * still useful claim — whatever each style draws, it is VISIBLE on a white page.
     *
     * `carousel_cards` is in the list because Android grew its own arm (full-width pages plus a
     * page-dot indicator) where it used to share `horizontal_scroll`'s peeking pager, and the two
     * Console choices have to look different on both platforms.
     */
    func testEveryPlanDisplayStyleDrawsOnAWhitePage() throws {
        let styles = [
            "vertical_stack", "grid", "horizontal_scroll", "radio_list", "pill_selector",
            "segmented_toggle", "tab_groups", "comparison_table", "single_hero",
            "product_as_cta", "carousel_cards", "timeline_reveal", "accordion",
        ]
        /*
         * 🔴 THE CONTROL, AND WITHOUT IT THIS SUITE PROVES NOTHING. `render` draws the WHOLE
         * paywall, so the frame carries the close button and the pinned CTA whatever the plans do —
         * and the close button is dark on a white page. `frameContains(dark)` would therefore pass
         * for a plans section that drew absolutely nothing, which is the shape of the false green
         * an earlier accessibility-tree read produced.
         *
         * So the same paywall is rendered with an EMPTY plans array first, and every style has to
         * put meaningfully more dark ink on the page than that baseline does.
         */
        let emptyJSON = """
        {
          "id": "snap_plan_style_control",
          "name": "Plan style control",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "id": "p", "type": "plans", "config": { "plan_display_style": "vertical_stack" } }
            ]
          },
          "plans": [],
          "cta": { "text": "Continue" },
          "dismiss": { "allowed": true, "style": "x_button" }
        }
        """
        try write(render(try paywall(emptyJSON)).environment(\.colorScheme, .light), named: "plan_style_control_light")
        let chromeOnly = try darkPixelCount("plan_style_control_light")
        print("[plan-style] CONTROL (no plans) dark=\(chromeOnly)")
        XCTAssertGreaterThan(chromeOnly, 0, "the control frame drew nothing at all — the harness is broken, not the renderer")

        var measured: [String: Int] = [:]

        for style in styles {
            let json = """
            {
              "id": "snap_plan_style_\(style)",
              "name": "Plan style",
              "layout": {
                "type": "stack",
                "background": { "type": "color", "value": "#FFFFFF" },
                "sections": [
                  { "id": "p", "type": "plans",
                    "config": { "plan_display_style": "\(style)", "show_plan_subtitles": true } }
                ]
              },
              "plans": [
                { "id": "p_month", "product_id": "premium_monthly", "label": "Monthly",
                  "price_display": "$9.99", "period": "month", "description": "Billed monthly",
                  "is_default": true, "sort_order": 0 },
                { "id": "p_year", "product_id": "premium_annual", "label": "Annual",
                  "price_display": "$49.99", "period": "year", "description": "Billed yearly",
                  "badge": "Save 58%", "is_default": false, "sort_order": 1 }
              ],
              "cta": { "text": "Continue" },
              "dismiss": { "allowed": true, "style": "x_button" }
            }
            """
            let config = try paywall(json)
            let name = "plan_style_\(style)_light"
            try write(render(config).environment(\.colorScheme, .light), named: name)
            // The number, into the log, because the PNG does not survive the run.
            let dark = try darkPixelCount(name)
            print("[plan-style] \(style) dark=\(dark)")
            /*
             * Against the chrome-only baseline, not against zero. `product_as_cta` is included
             * here even though it is excluded from the ink assertion below: its rows are
             * accent-filled with white content, so it adds no DARK ink of its own — which
             * is why it gets the weaker `>=` and the comment that says so out loud.
             */
            if style == "product_as_cta" {
                XCTAssertGreaterThanOrEqual(
                    dark, chromeOnly,
                    "product_as_cta: fewer dark pixels than the chrome alone — something stopped drawing",
                )
            } else {
                XCTAssertGreaterThan(
                    dark, chromeOnly,
                    "plan_display_style \(style): no more dark ink than an EMPTY plans section — "
                        + "the plan content did not draw, and the close button is what passed the colour check",
                )
                // The colour check as well as the count: the ink has to be the READABLE dark, not
                // merely some dark pixel that happens to be under 120 on all three channels.
                XCTAssertTrue(
                    try frameContains(name, colour: PaywallTextDefaults.dark),
                    "plan_display_style \(style): no readable-dark pixel on a WHITE page",
                )
            }
            measured[style] = dark
        }

        /*
         * `carousel_cards` AND `horizontal_scroll` ARE TWO CONSOLE CHOICES AND MUST NOT
         * DRAW THE SAME THING. Android rendered them with one arm until this issue, so an author
         * who picked the second silently got the first.
         *
         * The discriminating claim, which a count CAN make: `horizontal_scroll` peeks the next
         * plan, so both plans put ink on the page; `carousel_cards` pages, so only one does. Fewer
         * dark pixels is therefore the expected direction, and equality would mean the styles had
         * collapsed back together.
         *
         * 🔴 A dark-pixel count is position-independent, so it canNOT prove two layouts are the
         * same — `grid`, `horizontal_scroll` and `vertical_stack` all measure 14658 here while
         * dispatching to three different views, because they draw the same glyphs in different
         * places. It is used only in the direction it is sound in: a DIFFERENCE is evidence.
         */
        if let carousel = measured["carousel_cards"], let scroll = measured["horizontal_scroll"] {
            XCTAssertLessThan(
                carousel, scroll,
                "carousel_cards drew as much ink as horizontal_scroll — it is paging one plan at a "
                    + "time, so it should draw less than the style that peeks the next one",
            )
        } else {
            XCTFail("both styles must have been measured — the sweep list changed without this check")
        }
    }

    /**
     A CTA THAT CANNOT BUY MUST LOOK LIKE IT CANNOT BUY.

     `CTAButton` — the button a `cta` SECTION renders — was `.disabled(isPurchasing)` and nothing
     else. So a paywall whose plans are empty or unresolvable drew a full-strength "Subscribe"
     that accepted the tap and did nothing: `handleCTATap` returns on its first `guard`. Android
     has always disabled AND dimmed it (`enabled = !isPurchasing && selectedPlanId != null`,
     `alpha 0.5`), and iOS's own root-`cta` fallback already carried `|| selectedPlanId == nil` —
     so the two iOS renderers of the same control disagreed with each other as well as with
     Android.

     🔴 TWO RENDERS, ONE VARIABLE CHANGED, which is the only honest way to say "it is dimmer".
     The same document twice: once with a plan, once with none. A single frame cannot tell a
     dimmed fill from an authored one.

     🔴 AND THE FIRST ASSERTION IS THE CONTROL. "The authored colour is absent" passes against a
     harness that renders nothing at all (the store-price tests paid for that lesson twice), so the WITH-a-plan
     frame has to show the authored colour before the WITHOUT frame is allowed to mean anything.
     */
    func testACTAThatCannotBuyIsDimmed() throws {
        // A deliberately unmistakable fill: nothing else on the page is near it, so its presence
        // or absence is the button and not the chrome.
        let fill = "#1E90FF"
        func document(plans: String) -> String {
            """
            {"id":"pw_1075","name":"Dim","cta":{"text":"Subscribe","style":{"bg_color":"\(fill)"}},
             "plans":[\(plans)],
             "layout":{"type":"stack","sections":[
               {"id":"s1","type":"header","config":{"title":"Unlock"}},
               {"id":"s2","type":"cta","config":{}}
             ]}}
            """
        }
        let withPlan = """
            {"id":"p1","product_id":"app.premium.monthly","label":"Monthly",
             "price_display":"A-11.11","is_default":true}
            """

        try write(render(try paywall(document(plans: withPlan))), named: "cta_with_plan")
        try write(render(try paywall(document(plans: ""))), named: "cta_no_plan")

        XCTAssertTrue(
            try frameContains("cta_with_plan", colour: fill),
            "the control failed: the authored CTA fill was not drawn even WITH a plan, so this "
                + "harness cannot see the button and nothing below means anything",
        )
        XCTAssertFalse(
            try frameContains("cta_no_plan", colour: fill, tolerance: 8),
            "with no plan to buy the CTA must be dimmed — it still drew its authored fill at full "
                + "strength, which is a button that refuses the tap while looking available",
        )
    }

}
