// TextStyleMergeTests.swift
//
// A PARTIAL `text_style` CHANGES ONLY THE FIELDS IT SETS.
//
// The server's contrast pass writes `text_style: {"color": "#111827"}` onto generated paywalls. iOS
// treated any text_style as a whole typography and resolved every unset font field to system 16pt
// regular, so a header title lost its large bold default the moment it gained a colour. Android
// merges a partial style over the element's base `TextStyle`, field by field
// (`StyleEngine.applyTextStyle(base, config)`). These tests drive `StyleEngine.resolveTypography`,
// the function `View.applyTextStyle(_:defaults:colorOverride:)` resolves through.
//
// RED CONTROL: in `StyleEngine.resolveTypography` (Core/StyleEngine.swift) change
//     let size = style?.font_size ?? defaults.size
// to
//     let size = style?.font_size ?? 16
// and `testAColourOnlyStyleKeepsTheElementsSizeWeightAndFamily` + `testAWeightOnlyStyleKeepsTheElementsSize`
// fail on the size. Change `weight: style?.font_weight ?? defaults.weight` to `?? 400` and
// `testASizeOnlyStyleKeepsTheElementsWeight` fails on the weight.
import XCTest
import SwiftUI
@testable import AppDNASDK

final class TextStyleMergeTests: XCTestCase {

    private func style(_ json: String) throws -> TextStyleConfig {
        try JSONDecoder().decode(TextStyleConfig.self, from: Data(json.utf8))
    }

    /// A synthetic element default: a large bold centred title in a named family.
    private let titleDefault = TextStyleDefaults(
        font: .title.bold(), size: 28, weight: 700, family: "Synthetic Serif", alignment: "center")

    func testAColourOnlyStyleKeepsTheElementsSizeWeightAndFamily() throws {
        let t = StyleEngine.resolveTypography(try style(##"{ "color": "#111827" }"##), defaults: titleDefault)
        XCTAssertEqual(t.size, 28, "a colour-only style replaced the element's size")
        XCTAssertEqual(t.weight, 700, "a colour-only style replaced the element's weight")
        XCTAssertEqual(t.family, "Synthetic Serif", "a colour-only style replaced the element's family")
        XCTAssertEqual(t.alignment, "center", "a colour-only style replaced the element's alignment")
        XCTAssertTrue(t.keepsDefaultFont,
                      "a style that sets no font field must draw the element's own Font unchanged")
        XCTAssertEqual(t.lineSpacing, 0)
    }

    func testASizeOnlyStyleKeepsTheElementsWeight() throws {
        let t = StyleEngine.resolveTypography(try style(##"{ "font_size": 20 }"##), defaults: titleDefault)
        XCTAssertEqual(t.size, 20, "the authored size must win")
        XCTAssertEqual(t.weight, 700, "a size-only style replaced the element's weight")
        XCTAssertEqual(t.family, "Synthetic Serif")
        XCTAssertEqual(t.alignment, "center")
        XCTAssertFalse(t.keepsDefaultFont, "a style that sets a font field must resolve a new font")
    }

    func testAWeightOnlyStyleKeepsTheElementsSize() throws {
        let t = StyleEngine.resolveTypography(try style(##"{ "font_weight": 400 }"##), defaults: titleDefault)
        XCTAssertEqual(t.size, 28, "a weight-only style replaced the element's size")
        XCTAssertEqual(t.weight, 400, "the authored weight must win")
        XCTAssertFalse(t.keepsDefaultFont)
    }

    func testAFamilyOnlyStyleKeepsTheElementsSizeAndWeight() throws {
        let t = StyleEngine.resolveTypography(try style(##"{ "font_family": "Synthetic Sans" }"##), defaults: titleDefault)
        XCTAssertEqual(t.family, "Synthetic Sans")
        XCTAssertEqual(t.size, 28)
        XCTAssertEqual(t.weight, 700)
        XCTAssertFalse(t.keepsDefaultFont)
    }

    /// A full style still overrides every field — nothing the author set is lost to the merge.
    func testAFullStyleOverridesEveryField() throws {
        let full = try style(#"""
        { "font_family": "Synthetic Sans", "font_size": 13, "font_weight": 300, "color": "#123456",
          "alignment": "right", "line_height": 1.5, "letter_spacing": 1, "opacity": 0.9,
          "text_transform": "uppercase" }
        """#)
        let t = StyleEngine.resolveTypography(full, defaults: titleDefault)
        XCTAssertEqual(t, ResolvedTextTypography(
            family: "Synthetic Sans", size: 13, weight: 300, alignment: "right",
            lineSpacing: 6.5, keepsDefaultFont: false))
    }

    /// `line_height` is a multiplier of the RESOLVED size: authored without a size, it scales the
    /// element's own size (Android: `line_height * (config.font_size ?: base.fontSize)`).
    func testALineHeightWithoutASizeScalesTheElementsSize() throws {
        let t = StyleEngine.resolveTypography(try style(##"{ "line_height": 1.5 }"##), defaults: titleDefault)
        XCTAssertEqual(t.lineSpacing, 14, accuracy: 0.0001)
        XCTAssertTrue(t.keepsDefaultFont)
    }

    /// The legacy overload (`applyTextStyle(_:)`, used by onboarding and surveys) must resolve
    /// exactly what it always did: system 16pt regular, leading.
    func testTheLegacyDefaultsResolveWhatThePlainOverloadAlwaysDrew() throws {
        let colourOnly = StyleEngine.resolveTypography(try style(##"{ "color": "#111827" }"##), defaults: .legacy)
        XCTAssertEqual(colourOnly, ResolvedTextTypography(
            family: nil, size: 16, weight: 400, alignment: nil, lineSpacing: 0, keepsDefaultFont: true))
        XCTAssertNil(TextStyleDefaults.legacy.font,
                     "the legacy default must fall through to FontResolver(nil, 16, 400), not a named Font")
        let lh = StyleEngine.resolveTypography(try style(##"{ "line_height": 2 }"##), defaults: .legacy)
        XCTAssertEqual(lh.lineSpacing, 16, accuracy: 0.0001, "legacy line spacing is (lh - 1) * 16")
    }

    func testNoStyleIsTheElementDefault() {
        let t = StyleEngine.resolveTypography(nil, defaults: titleDefault)
        XCTAssertEqual(t, ResolvedTextTypography(
            family: "Synthetic Serif", size: 28, weight: 700, alignment: "center",
            lineSpacing: 0, keepsDefaultFont: true))
    }

    /// The CSS-number twin of `resolvePaywallFontWeight`, which the CTA and countdown defaults use.
    func testPaywallFontWeightValueMatchesTheFontWeightSpellings() {
        XCTAssertEqual(paywallFontWeightValue("regular", default: 600), 400)
        XCTAssertEqual(paywallFontWeightValue("Normal", default: 600), 400)
        XCTAssertEqual(paywallFontWeightValue("medium", default: 600), 500)
        XCTAssertEqual(paywallFontWeightValue("semibold", default: 400), 600)
        XCTAssertEqual(paywallFontWeightValue("bold", default: 400), 700)
        XCTAssertEqual(paywallFontWeightValue(nil, default: 600), 600)
        XCTAssertEqual(paywallFontWeightValue("unknown", default: 700), 700)
    }
}
