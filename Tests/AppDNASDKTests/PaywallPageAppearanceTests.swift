// PaywallPageAppearanceTests.swift
//
// A PAYWALL FOLLOWS ITS DOCUMENT, NOT THE PHONE — and is on the screen on a light page.
//
// Two different defects need two different measurements, and each is blind to the other:
//
//   1. APPEARANCE DRIFT. `.primary` and `.secondary` are SYSTEM colours — black in light
//      appearance, white in dark. A paywall forces no colour scheme, so a document that sets a
//      dark page and is opened on a light-appearance phone asked for black text on a dark
//      background. Android hard-codes white instead; iOS reached for these 63 times. Measured by
//      rendering the same document twice and counting pixels that CHANGE.
//
//   2. LIGHT-PAGE INK. A hard-coded `"#FFFFFF"` does not change with the phone, so it scores ZERO
//      drift while being invisible on a white page. The toggle's label was exactly that, and the
//      drift metric could not see it. Measured by counting near-achromatic pixels darker than a
//      white page — the metric Android's sweep uses.
//
// 🔴 The first version of this file counted near-white and near-black pixels and was wrong for
// every mid-tone: the legal section draws `#9CA3AF`, which is neither, so it reported `0` and
// looked like the worst defect in the file while the text was on the screen the whole time.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PaywallPageAppearanceTests: XCTestCase {

    private let size = CGSize(width: 393, height: 320)

    private func paywall(page: String, sections: String) throws -> PaywallConfig {
        let json = """
        {
          "id": "pw_probe", "name": "Probe",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "\(page)" },
            "sections": [\(sections)]
          },
          "plans": [
            { "id": "p1", "product_id": "a.month", "label": "Monthly", "price_display": "$9.99",
              "period": "month", "is_default": true },
            { "id": "p2", "product_id": "a.year", "label": "Annual", "price_display": "$49.99",
              "period": "year" }
          ]
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    private func render(_ config: PaywallConfig, appearance: UIUserInterfaceStyle) throws -> UIImage {
        let view = PaywallRenderer(
            config: config, onPlanSelected: { _, _ in }, onRestore: {}, onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = appearance
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.overrideUserInterfaceStyle = appearance
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return UIGraphicsImageRenderer(size: size).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    /**
     🔴 THE MEASUREMENT IS A DIFFERENCE BETWEEN THE TWO APPEARANCES, NOT A COLOUR BAND.

     The first version of this probe counted near-white and near-black pixels, and it was wrong for
     every mid-tone: the legal section draws `#9CA3AF`, which is neither, so it reported `0` and
     looked like the worst defect in the file when the text was on the screen the whole time.

     The question is simpler than "what colour is it". A paywall's page colour is in the DOCUMENT,
     so the same document must draw the same pixels whatever the phone is set to. Render it twice,
     once in each appearance, and count the pixels that differ. Zero means the section follows the
     document. Anything else means it follows the phone — which is `.primary` and `.secondary`,
     and is the follows-the-phone defect wherever it still lives.
     */
    private func appearanceDrift(_ page: String, _ sectionJSON: String) throws -> Int {
        let light = try pixels(try render(try paywall(page: page, sections: sectionJSON), appearance: .light))
        let dark = try pixels(try render(try paywall(page: page, sections: sectionJSON), appearance: .dark))
        var n = 0
        for i in stride(from: 0, to: min(light.count, dark.count), by: 4) {
            if abs(Int(light[i]) - Int(dark[i])) > 8
                || abs(Int(light[i + 1]) - Int(dark[i + 1])) > 8
                || abs(Int(light[i + 2]) - Int(dark[i + 2])) > 8 { n += 1 }
        }
        return n
    }

    private let sections: [(String, String)] = [
        ("header", #"{ "type": "header", "id": "s", "config": { "title": "Go Premium", "subtitle": "Everything, unlocked" } }"#),
        ("features", #"{ "type": "features", "id": "s", "config": { "features": ["First benefit", "Second benefit", "Third benefit"] } }"#),
        ("plans", #"{ "type": "plans", "id": "s", "config": { "plan_display_style": "vertical_stack", "show_plan_features": true } }"#),
        ("legal", #"{ "type": "legal", "id": "s", "config": { "legal_text": "Payment is charged on confirmation.", "text": "Payment is charged on confirmation." } }"#),
        ("social_proof", #"{ "type": "social_proof", "id": "s", "config": { "rating": 4.8, "review_count": 1240, "testimonial": "A short quote." } }"#),
        ("card", #"{ "type": "card", "id": "s", "config": { "title": "Card title", "subtitle": "Its subtitle", "text": "A short body." } }"#),
        ("testimonial", #"{ "type": "testimonial", "id": "s", "config": { "quote": "It changed how we work.", "author_name": "A. Reader", "author_role": "Designer" } }"#),
        ("guarantee", #"{ "type": "guarantee", "id": "s", "config": { "guarantee_text": "30-day money back" } }"#),
        ("countdown", #"{ "type": "countdown", "id": "s", "config": { "countdown_seconds": 3725, "title": "Offer ends in" } }"#),
        ("divider", #"{ "type": "divider", "id": "s", "config": { "label_text": "or", "style": "solid" } }"#),
        ("timeline", #"{ "type": "timeline", "id": "s", "config": { "items": [{ "title": "Today", "subtitle": "Full access" }, { "title": "Day 7", "subtitle": "Billing starts" }] } }"#),
        ("icon_grid", #"{ "type": "icon_grid", "id": "s", "config": { "items": [{ "icon": "star", "title": "First", "subtitle": "One" }, { "icon": "bolt", "title": "Second", "subtitle": "Two" }] } }"#),
        ("reviews_carousel", #"{ "type": "reviews_carousel", "id": "s", "config": { "auto_scroll": false, "reviews": [{ "id": "r1", "text": "A quote", "author": "A" }, { "id": "r2", "text": "Another", "author": "B" }] } }"#),
        ("toggle", #"{ "type": "toggle", "id": "s", "config": { "label_text": "Remind me", "label": "Remind me" } }"#),
        ("cta", #"{ "type": "cta", "id": "s", "config": { "cta_text": "Continue", "show_restore": true, "restore_text": "Restore" } }"#),
    ]

    /// Near-achromatic pixels darker than a white page — the ink a section puts on a light paywall.
    private func lightPageInk(_ sectionJSON: String) throws -> Int {
        let bytes = try pixels(try render(try paywall(page: "#FFFFFF", sections: sectionJSON), appearance: .light))
        var n = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where Int(bytes[i + 3]) != 0 {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            if abs(r - g) <= 10 && abs(g - b) <= 12 && abs(r - b) <= 14 && r <= 225 { n += 1 }
        }
        return n
    }

    /**
     🔴 EVERY SECTION DRAWS THE SAME PIXELS IN BOTH APPEARANCES.

     Before the sweep the drift ranged from 697 (a floor every section shared) to 14,364. The
     expected value is exactly ZERO: a published document is a published document, and two users
     looking at the same paywall should not see two different screens because of a setting on
     their phone.

     `toggle` is the one exception and it is named rather than hidden: a SwiftUI `Toggle` is a
     PLATFORM control and its track follows the platform, which is correct. Its LABEL is the part
     this issue is about, and the label is asserted by the ink test below — it defaulted to the
     literal `"#FFFFFF"`, which this metric cannot see at all.
     */
    func testNoSectionChangesWithThePhonesAppearance() throws {
        var drifted: [String] = []
        for (name, json) in sections where name != "toggle" {
            for page in ["#FFFFFF", "#0B1220"] {
                let drift = try appearanceDrift(page, json)
                if drift > 0 { drifted.append("\(name) on \(page): \(drift) px") }
            }
        }
        XCTAssertEqual(
            drifted, [],
            "these sections draw different pixels depending on the phone's appearance, which means "
            + "they resolve a colour from the SYSTEM instead of from the document",
        )
    }

    /**
     🔴 THE TOGGLE'S LABEL, ISOLATED.

     The blanket ink test below is too coarse for it: a toggle section draws a platform switch and
     a `#9CA3AF` description, both of which clear the floor whether or not the label is there. So
     the label is measured the way a pager dot was measured — by DIFFERENCE. Two documents
     identical but for the label; the ink between them is the label and nothing else.

     Its default was the literal `"#FFFFFF"`, which is stable across appearances and invisible on
     a white page — the one defect on this surface that the drift metric cannot see at all.
     */
    func testTheToggleLabelIsOnTheScreenOnAWhitePage() throws {
        let withLabel = #"{ "type": "toggle", "id": "s", "config": { "label": "Remind me before the trial ends" } }"#
        let without = #"{ "type": "toggle", "id": "s", "config": { } }"#

        let a = try lightPageInk(withLabel)
        let b = try lightPageInk(without)
        XCTAssertGreaterThanOrEqual(
            a - b, 300,
            "a toggle with a label drew \(a) page-derived pixels and one without drew \(b): a "
            + "difference of \(a - b). The label is white on a white page, so the author's own "
            + "words are not on the screen",
        )
    }

    /**
     🔴 AND EVERY SECTION IS ON THE SCREEN ON A LIGHT PAGE.

     The companion metric, and the one that catches what drift cannot: a fixed `"#FFFFFF"` is
     stable across appearances and invisible on white. The toggle's label was exactly that.

     `divider` is excluded: it is a hairline and a short label, and its ink is genuinely small.
     */
    func testEverySectionPutsInkOnAWhitePage() throws {
        var blank: [String] = []
        for (name, json) in sections where name != "divider" {
            let ink = try lightPageInk(json)
            if ink < 300 { blank.append("\(name): \(ink) px") }
        }
        XCTAssertEqual(
            blank, [],
            "these sections put almost no page-derived ink on a #FFFFFF page — an author who "
            + "chooses a light background and sets no colours cannot see them",
        )
    }
}
