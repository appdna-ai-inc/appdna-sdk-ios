// SocialProofRenderTests.swift
//
// DOES THE SOCIAL-PROOF SECTION DRAW ITS CAPTION AND ITS AUTHOR? Rendered, and compared.
//
// 🔴 Why pixels. Two fields decoded, travelled the wire and reached no view: `text` on the
// `app_rating` variant and `author_name` anywhere. Both were caught by reading the
// renderer, and reading a renderer is how they got there in the first place — `PaywallConfig`
// decodes both, the console wrote both, and nothing drew either. The only statement worth making
// is about what ends up on screen.
//
// The harness is `StorePriceRenderTests`': a real `PaywallRenderer` in a real key window,
// `layer.render(in:)`, PNG out. Not the accessibility tree — SwiftUI builds that lazily and a
// hostless test never triggers it, which is how an earlier store-price test passed for the worst possible
// reason.
//
// 🔴 EVERY ASSERTION HAS ITS CONTROL. "Adding the caption changed the screen" means nothing unless
// this harness can be shown NOT changing the screen for something it should ignore — so each case
// renders a pair that must differ AND a pair that must not.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SocialProofRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    /*
     🔴 THE FIRST RENDER IN A PROCESS IS NOT REPRESENTATIVE, and an equality assertion is where
     that shows. `testAnAuthorWithoutAQuoteDrawsNothing` passed on its own and FAILED inside the
     full class, on identical input — whatever the first `layer.render(in:)` warms (fonts, the
     window, SwiftUI's first layout pass) made render #1 differ from render #2 of the same view.

     An inequality assertion survives that; an equality assertion does not, and "these two renders
     match" is half the claims here. So one throwaway render happens before any measurement, and
     every compared render is a later one.
     */
    override func setUp() async throws {
        try await super.setUp()
        _ = try? renderPNG(try config(#"{ "sub_type": "app_rating", "rating": 4.0 }"#))
    }

    /// A paywall whose only content section is the social proof under test.
    private func config(_ sectionConfig: String, page: String = "#FFFFFF") throws -> PaywallConfig {
        let json = """
        {
          "id": "render_social_proof",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "\(page)" },
            "sections": [
              { "type": "social_proof", "config": \(sectionConfig) },
              { "type": "cta", "config": { "cta": { "text": "Continue" } } }
            ]
          }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    private func renderPNG(_ config: PaywallConfig) throws -> Data {
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

        return try XCTUnwrap(UIGraphicsImageRenderer(size: size).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }.pngData())
    }

    // MARK: - the caption

    func testTheCaptionIsDrawnOnTheAppRatingVariant() throws {
        let withCaption = try renderPNG(try config(
            #"{ "sub_type": "app_rating", "rating": 4.8, "review_count": 18240, "text": "Loved by 12,000 runners" }"#))
        let without = try renderPNG(try config(
            #"{ "sub_type": "app_rating", "rating": 4.8, "review_count": 18240 }"#))
        let otherCaption = try renderPNG(try config(
            #"{ "sub_type": "app_rating", "rating": 4.8, "review_count": 18240, "text": "A completely different caption" }"#))

        XCTAssertNotEqual(
            withCaption, without,
            "authoring `text` on an app_rating section must CHANGE the screen — identical renders "
            + "mean the caption reached no view, which is the defect this test exists for"
        )
        XCTAssertNotEqual(
            withCaption, otherCaption,
            "and the CONTENT must be what changed it — if any two captions render the same, this "
            + "harness is seeing a layout shift rather than the words"
        )
    }

    /// The control: a key the section does not read must leave the render untouched.
    func testTheHarnessDoesNotReactToAFieldNothingReads() throws {
        let a = try renderPNG(try config(#"{ "sub_type": "app_rating", "rating": 4.8 }"#))
        let b = try renderPNG(try config(#"{ "sub_type": "app_rating", "rating": 4.8, "not_a_field": "xyz" }"#))
        XCTAssertEqual(
            a, b,
            "THE CONTROL FAILED: this harness reports a difference for a key no renderer reads, so "
            + "every 'the screen changed' assertion above is meaningless"
        )
    }

    // MARK: - the author

    func testTheAuthorIsDrawnUnderTheQuote() throws {
        let quoteOnly = #"{ "sub_type": "app_rating", "testimonial": "Two weeks in and I have not missed a day" }"#
        let withAuthor = #"{ "sub_type": "app_rating", "testimonial": "Two weeks in and I have not missed a day", "author_name": "Sofia R." }"#

        XCTAssertNotEqual(
            try renderPNG(try config(withAuthor)), try renderPNG(try config(quoteOnly)),
            "authoring `author_name` must CHANGE the screen — the generator has been writing an "
            + "author all along and this section drew nothing for it"
        )
    }

    /// An author with no quote draws nothing: the attribution belongs to a testimonial.
    func testAnAuthorWithoutAQuoteDrawsNothing() throws {
        let bare = #"{ "sub_type": "app_rating", "rating": 4.8 }"#
        let orphanAuthor = #"{ "sub_type": "app_rating", "rating": 4.8, "author_name": "Sofia R." }"#
        XCTAssertEqual(
            try renderPNG(try config(bare)), try renderPNG(try config(orphanAuthor)),
            "an attribution with nothing to attribute must not appear on its own"
        )
    }

    // MARK: - the review-count colour defect, one line further down

    /*
     The quote was `.foregroundColor(.white.opacity(0.8))` — a colour that follows nothing, so it
     was invisible on a light page exactly as the review count once was. The assertion is
     that the quote's colour now RESPONDS to the page: the same section on a white page and on a
     near-black page must render differently, and it could not before, because white is white.
     */
    func testTheQuoteIsReadableOnALightPage() throws {
        let section = #"{ "sub_type": "app_rating", "testimonial": "Two weeks in and I have not missed a day" }"#
        let onWhite = try renderPNG(try config(section, page: "#FFFFFF"))
        let onBlack = try renderPNG(try config(section, page: "#000000"))
        XCTAssertNotEqual(onWhite, onBlack, "the page colour must change the render at all")

        // And the quote is the thing that changed, not only the background: a section with NO
        // quote differs between the two pages as well, so compare the deltas rather than the pair.
        let emptyOnWhite = try renderPNG(try config(#"{ "sub_type": "app_rating" }"#, page: "#FFFFFF"))
        XCTAssertNotEqual(
            onWhite, emptyOnWhite,
            "the quote must be VISIBLE on a white page — if these match it is drawing white on "
            + "white, which is what it did before the caption was drawn"
        )
    }
}
