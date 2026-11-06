import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK
import SnapshotTesting

/*
 RENDERED: a colour more specific than a Typography style must reach the text it styles.
 - a SELECTED plan's `selectedTextColor` under a `plan_name` style that sets only a size;
 - a plan's own `price_color` under a `price` style;
 - a survey theme's `text_color` under a `question_text_style` that sets only a size.
 Each was chained AFTER `applyTextStyle`, whose colour (`.primary` when the style sets none) sits closest to the
 text and won. THE CONTROLS: the same colour authored in the style itself draws the pixels; a dark one does not.
 Captured through SnapshotTesting's `.image`, like the goldens.
*/
@MainActor
final class StyledTextOverrideRenderTests: XCTestCase {
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

    private let red = { (r: UInt8, g: UInt8, b: UInt8) in r > 200 && g < 60 && b < 60 }
    private let green = { (r: UInt8, g: UInt8, b: UInt8) in r < 60 && g > 180 && b < 60 }
    private let white = { (r: UInt8, g: UInt8, b: UInt8) in r > 225 && g > 225 && b > 225 }

    private func planCard(selectedText: String? = "#FF0000", priceColor: String? = nil, nameStyleColor: String? = nil, priceStyleColor: String? = nil) throws -> some View {
        let pc = priceColor.map { ##", "price_color": "\##($0)""## } ?? ""
        let plan = try JSONDecoder().decode(PaywallPlan.self, from: Data(##"{ "id": "p", "product_id": "p", "name": "WWWWWWWW", "price": "WWWWWW"\##(pc) }"##.utf8))
        let nc = nameStyleColor.map { ##", "color": "\##($0)""## } ?? ""
        let sc = priceStyleColor.map { ##", "color": "\##($0)""## } ?? ""
        let section = try JSONDecoder().decode(SectionStyleConfig.self, from: Data(##"{ "elements": { "plan_name": { "text_style": { "font_size": 22\##(nc) } }, "price": { "text_style": { "font_size": 22\##(sc) } } } }"##.utf8))
        var style = PlanCardStyle()
        style.selectedTextColor = selectedText
        style.selectedBgColor = "#FFFFFF"
        return PlanCard(plan: plan, isSelected: true, onSelect: {}, sectionStyle: section, cardStyle: style)
            .padding(16).frame(width: 390, height: 160).background(Color.white)
    }

    func testASelectedPlansTextColourBeatsAColourlessNameStyle() throws {
        let size = CGSize(width: 390, height: 160)
        let control = try count(planCard(selectedText: nil, nameStyleColor: "#FF0000", priceStyleColor: "#FF0000"), size: size, match: red)
        let none = try count(planCard(selectedText: nil), size: size, match: red)
        let styled = try count(planCard(selectedText: "#FF0000"), size: size, match: red)
        NSLog("[styled-override plan] control=\(control) none=\(none) styled=\(styled)")
        XCTAssertGreaterThan(control, none + 100, "harness control: a red style draws red")
        // Every text on the tile goes red, so more than the two styled texts alone (before the fix: 3069 vs 11760).
        XCTAssertGreaterThan(styled, control, "the selected text colour lost to a colourless name/price style")
    }

    func testAPlansOwnPriceColourBeatsThePriceStyle() throws {
        let size = CGSize(width: 390, height: 160)
        let control = try count(planCard(selectedText: nil, priceStyleColor: "#00CC00"), size: size, match: green)
        let none = try count(planCard(selectedText: nil, priceStyleColor: "#111111"), size: size, match: green)
        let styled = try count(planCard(selectedText: nil, priceColor: "#00CC00", priceStyleColor: "#111111"), size: size, match: green)
        NSLog("[styled-override price] control=\(control) none=\(none) styled=\(styled)")
        XCTAssertGreaterThan(control, none + 100, "harness control: a green price style draws green")
        XCTAssertGreaterThan(styled, none + 100, "the plan's own price_color lost to the price style")
    }

    private func survey(styleColor: String?) throws -> some View {
        let c = styleColor.map { ##", "color": "\##($0)""## } ?? ""
        let json = ##"""
        { "id": "s", "name": "s", "survey_type": "csat",
          "questions": [ { "id": "q1", "type": "csat", "text": "WWWWWWWW WWWW" } ],
          "appearance": { "presentation": "fullscreen", "theme": { "background_color": "#0F1117", "text_color": "#FFFFFF" },
                          "question_text_style": { "font_size": 26\##(c) } } }
        """##
        let config = try JSONDecoder().decode(SurveyConfig.self, from: Data(json.utf8))
        return SurveyContainerView(config: config, completion: { _ in })
    }

    func testASurveyThemesTextColourBeatsAColourlessQuestionStyle() throws {
        let size = CGSize(width: 393, height: 700)
        let control = try count(survey(styleColor: "#FFFFFF"), size: size, match: white)
        let dark = try count(survey(styleColor: "#111111"), size: size, match: white)
        let styled = try count(survey(styleColor: nil), size: size, match: white)
        NSLog("[styled-override survey] control=\(control) dark=\(dark) styled=\(styled)")
        XCTAssertGreaterThan(control, dark + 100, "harness control")
        XCTAssertGreaterThan(styled, dark + 100, "the theme text colour lost to a colourless question style")
    }
}
