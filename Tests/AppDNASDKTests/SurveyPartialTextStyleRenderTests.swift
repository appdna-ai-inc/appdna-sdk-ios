import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 #1805, the survey half — RENDERED through the real `SurveyContainerView`. A `question_text_style` that
 sets only a colour must leave the question drawn as an unstyled one is drawn.

 What it measured on iOS before the fix: the question TITLE is masked (each question view gives its title
 its own `.font(.headline)`, which beats the outer style font), but the OPTION LABELS carry no font of their
 own, so they inherited the legacy overload's 16pt and shrank from the 17pt body whenever a style set only a
 colour. The same mechanism also hid the theme's `question_font_size` behind 16pt.

 Oracle: no style at all (theme text colour #111111, same ink). Control: `font_size: 16` with the same colour
 must draw different ink, so the harness can see a one-point change on these labels.
 RED CONTROL: in `SurveyContainerView.styledQuestion`, replace the merged call with the legacy
 `view.applyTextStyle(style, colorOverride: override)` — colour-only then draws 16pt, equals the control,
 and `testAColourOnlyQuestionStyleKeepsTheUnstyledSize` fails.
*/
@MainActor
final class SurveyPartialTextStyleRenderTests: XCTestCase {
    private let size = CGSize(width: 393, height: 700)

    private func darkInk(_ style: String?) throws -> Int {
        let st = style.map { ##", "question_text_style": \##($0)"## } ?? ""
        let json = ##"""
        { "id": "s", "name": "s", "survey_type": "custom",
          "questions": [ { "id": "q1", "type": "single_choice", "text": "Which goal fits best",
                           "options": [ { "id": "a", "text": "Seven days in a row" },
                                        { "id": "b", "text": "Thirty lessons done" },
                                        { "id": "c", "text": "One streak kept" } ] } ],
          "appearance": { "presentation": "fullscreen",
                          "theme": { "background_color": "#FFFFFF", "text_color": "#111111" }\##(st) } }
        """##
        let config = try JSONDecoder().decode(SurveyConfig.self, from: Data(json.utf8))
        let host = UIHostingController(rootView: SurveyContainerView(config: config, completion: { _ in })
            .frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light))
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var count = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] < 80 && px[i + 1] < 80 && px[i + 2] < 80 && px[i + 3] > 200 {
            count += 1
        }
        return count
    }

    func testAColourOnlyQuestionStyleKeepsTheUnstyledSize() throws {
        _ = try darkInk(nil) // warm-up render
        let unstyled = try darkInk(nil)
        let colourOnly = try darkInk(##"{ "color": "#111111" }"##)
        let legacy16 = try darkInk(##"{ "color": "#111111", "font_size": 16 }"##)
        NSLog("[1805-survey] unstyled=\(unstyled) colourOnly=\(colourOnly) legacy16=\(legacy16)")
        XCTAssertGreaterThan(unstyled, 500, "harness control: the question and its options are drawn")
        XCTAssertNotEqual(unstyled, legacy16, "harness control: a one-point size change must be visible")
        XCTAssertEqual(colourOnly, unstyled, "a colour-only question style must keep the unstyled typography")
    }
}
