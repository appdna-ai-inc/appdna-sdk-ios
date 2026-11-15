// JustifiedTextTests.swift
//
// Justify: SwiftUI's Text cannot, so heading and rich text set to `justify` draw through UIKit. These read
// back what UIKit is handed, so a justified block that silently lost its bold, its colour run or its link —
// or was not justified at all — fails here rather than looking plausible on a device.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

final class JustifiedTextTests: XCTestCase {

    private let base = UIFont.systemFont(ofSize: 17)

    func testItIsJustified() {
        let out = JustifiedText.styled(NSAttributedString(string: "Some words to fill a line"), font: base, color: .black)
        let para = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para?.alignment, .justified)
        XCTAssertEqual(out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .black,
                       "a run with no colour takes the block's")
    }

    func testBoldColourRunAndLinkSurviveTheTripToUIKit() throws {
        let md = MarkdownText.attributed("A **bold** word, a [cycle](color:EE6885) and [a link](https://example.com)",
                                         linkColor: .blue, textColor: nil, underlineMarkers: true)
        let ns = JustifiedText.nsAttributed(md, base: base)
        let text = ns.string as NSString

        let bold = text.range(of: "bold")
        let boldFont = try XCTUnwrap(ns.attribute(.font, at: bold.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold), "**bold** lost its weight")

        let run = text.range(of: "cycle")
        let runColor = try XCTUnwrap(ns.attribute(.foregroundColor, at: run.location, effectiveRange: nil) as? UIColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        runColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int((r * 255).rounded()), 0xEE); XCTAssertEqual(Int((g * 255).rounded()), 0x68)
        XCTAssertNil(ns.attribute(.link, at: run.location, effectiveRange: nil), "a colour run is not a link")

        let link = text.range(of: "a link")
        XCTAssertEqual((ns.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com")

        // 🔴 Negative control: a plain word carries none of the three.
        let plain = text.range(of: "word")
        XCTAssertNil(ns.attribute(.link, at: plain.location, effectiveRange: nil))
        XCTAssertNil(ns.attribute(.foregroundColor, at: plain.location, effectiveRange: nil))
        XCTAssertNil(ns.attribute(.font, at: plain.location, effectiveRange: nil))
    }

    func testOnlyJustifyTakesTheUIKitPath() {
        XCTAssertTrue(JustifiedText.isJustify("justify"))
        for other in [nil, "left", "center", "right", "leading", "trailing"] { XCTAssertFalse(JustifiedText.isJustify(other)) }
    }
}
