import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 A survey question taller than the room it is given, RENDERED through the real `SurveyContainerView`.

 A bottom-sheet survey opens at the `.medium()` detent, about 420 points tall on a phone. A choice question with a long
 title and six options does not fit. Before the fix the question sat between two `Spacer()`s in a plain VStack: SwiftUI
 cut the title to one line with an ellipsis and drew the navigation half off the sheet (on the phone it also pushed
 the progress bar above the sheet), and nothing scrolled. With the fix a question that does not fit scrolls inside the sheet: the title wraps in full, and
 the progress bar and the navigation stay inside the frame.

 Each part is painted in its own colour so it can be counted alone: the title red (`question_text_style`), the
 progress bar green (accent), the Submit button blue (button colour). Oracle: the same survey rendered in a frame tall
 enough that nothing is squeezed. The compact render must draw as much of each part as the roomy one.

 The title is compared by its LINES and the rows they cover, not by an exact count of red pixels. The render is at
 scale 1, where most of a glyph's pixels are anti-aliased edges, so the count of fully red pixels depends on where the
 text lands within a pixel. Measured 2026-11-21 (iPhone 16 simulator, iOS 26.2), the roomy render alone, its frame
 moved by half a point at a time: red 2238 / 2115 / 2178 for frame heights 1400 / 1400.5 / 1401, always 3 lines over
 45 to 47 rows. The compact render drew 2115, the same 3 lines over the same 47 rows. A count within 3% of the roomy
 one therefore passed on one simulator and failed on another for a title drawn in full.

 Controls: the roomy render draws each colour (the harness can see them), and a one-line title draws less red than the
 two-line one in the same harness (the harness can see a truncation).

 RED CONTROL: in `SurveyContainerView.surveyBody`, put the question back between two `Spacer()`s with no
 `ViewThatFits`/`ScrollView`. Measured 2026-11-19 (iPhone 17 Pro simulator, iOS 26.2): roomy r=2178 g=1436 b=3734;
 old layout compact r=948 b=1661 (the title cut to one line, Submit half off the frame), so
 `testALongQuestionInACompactSheetKeepsItsTitleProgressAndNavigation` fails on the red and blue counts; with the fix the
 compact counts equal the roomy ones. Re-run 2026-11-21 against the line assertions (iPhone 16 simulator, iOS 26.2): the
 old layout drew the title as 1 line over 15 rows against the roomy 3 lines over 47 (r=995 against 2238) and Submit
 at b=1809 against 3742, so the line, row, ink and Submit assertions all fail.
*/
@MainActor
final class SurveyLongQuestionScrollRenderTests: XCTestCase {
    private let width: CGFloat = 393

    private let longTitle = "Which parts of the weekly lesson plan should we change for you next? (Select all that apply)"

    private func surveyJSON(title: String, optionCount: Int) -> String {
        let options = (1...optionCount).map { #"{ "id": "o\#($0)", "text": "Option number \#($0)" }"# }.joined(separator: ", ")
        return ##"""
        { "id": "s", "name": "s", "survey_type": "custom",
          "questions": [ { "id": "q1", "type": "multi_choice", "required": false, "text": "\##(title)",
                           "options": [ \##(options) ] } ],
          "appearance": { "presentation": "bottom_sheet", "show_progress": true,
                          "question_text_style": { "color": "#FF0000" },
                          "theme": { "background_color": "#FFFFFF", "text_color": "#111111",
                                     "accent_color": "#00C000", "button_color": "#0000FF",
                                     "button_text_color": "#FFFFFF" } } }
        """##
    }

    /// `redLines` counts the runs of consecutive pixel rows that carry red ink: one run per line of the title.
    private struct Ink { let red: Int; let green: Int; let blue: Int; let redRows: Int; let redLines: Int }

    /// Renders the survey in `width × height` and counts each part's colour in the top `band` points.
    private func ink(title: String, optionCount: Int, height: CGFloat, band: CGFloat? = nil) throws -> Ink {
        let size = CGSize(width: width, height: height)
        let config = try JSONDecoder().decode(SurveyConfig.self, from: Data(surveyJSON(title: title, optionCount: optionCount).utf8))
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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let rows = min(cg.height, Int((band ?? height).rounded()))
        var red = 0, green = 0, blue = 0, redRows = 0, redLines = 0
        var previousRowHadRed = false
        for y in 0..<rows {
            let redBefore = red
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4
                let r = px[i], g = px[i + 1], b = px[i + 2], a = px[i + 3]
                guard a > 200 else { continue }
                if r > 190 && g < 70 && b < 70 { red += 1 }
                if g > 140 && r < 70 && b < 70 { green += 1 }
                if b > 190 && r < 70 && g < 70 { blue += 1 }
            }
            let rowHasRed = red > redBefore
            if rowHasRed { redRows += 1 }
            if rowHasRed && !previousRowHadRed { redLines += 1 }
            previousRowHadRed = rowHasRed
        }
        return Ink(red: red, green: green, blue: blue, redRows: redRows, redLines: redLines)
    }

    func testALongQuestionInACompactSheetKeepsItsTitleProgressAndNavigation() throws {
        _ = try ink(title: longTitle, optionCount: 6, height: 1400) // warm-up render
        let roomy = try ink(title: longTitle, optionCount: 6, height: 1400)
        let compact = try ink(title: longTitle, optionCount: 6, height: 420)
        NSLog("[long-question-scroll] roomy r=\(roomy.red) g=\(roomy.green) b=\(roomy.blue) compact r=\(compact.red) g=\(compact.green) b=\(compact.blue)")

        // Harness controls: every part is drawn and counted when there is room.
        XCTAssertGreaterThan(roomy.red, 300, "harness control: the red title is drawn")
        XCTAssertGreaterThan(roomy.green, 300, "harness control: the green progress bar is drawn")
        XCTAssertGreaterThan(roomy.blue, 1500, "harness control: the blue Submit button is drawn")

        XCTAssertGreaterThanOrEqual(roomy.redLines, 2, "harness control: the long title wraps, so a cut to one line is visible")

        // The question's title is drawn in full, not cut to one line: as many lines, over as many rows, as with room.
        XCTAssertEqual(compact.redLines, roomy.redLines, "the title must wrap in full in a compact sheet (lines of title text)")
        XCTAssertGreaterThanOrEqual(Double(compact.redRows), Double(roomy.redRows) * 0.9, "the title's lines must be drawn in full height")
        // Loose on purpose (see above): a line or a part of one missing is far more than sub-pixel placement moves.
        XCTAssertGreaterThanOrEqual(Double(compact.red), Double(roomy.red) * 0.85, "the title must not lose part of its text")
        // The progress bar stays inside the frame.
        XCTAssertGreaterThanOrEqual(Double(compact.green), Double(roomy.green) * 0.97, "the progress bar must stay inside a compact sheet")
        // The navigation stays on screen.
        XCTAssertGreaterThanOrEqual(Double(compact.blue), Double(roomy.blue) * 0.97, "Submit must stay on screen in a compact sheet")
    }

    func testTheHarnessCanSeeATruncatedTitle() throws {
        _ = try ink(title: longTitle, optionCount: 1, height: 1400) // warm-up render
        let twoLines = try ink(title: longTitle, optionCount: 1, height: 1400)
        let oneLine = try ink(title: "Which parts of the weekly lesson plan", optionCount: 1, height: 1400)
        XCTAssertLessThan(Double(oneLine.red), Double(twoLines.red) * 0.8, "harness control: a shorter title draws less red")
    }

    func testAShortQuestionStillSitsInTheMiddle() throws {
        // Two options in a tall frame: the question is centred between the progress bar and the navigation, as before.
        let height: CGFloat = 900
        let top = try ink(title: "Short question", optionCount: 2, height: height, band: height / 3)
        let all = try ink(title: "Short question", optionCount: 2, height: height)
        XCTAssertGreaterThan(all.red, 100, "harness control: the title is drawn")
        XCTAssertEqual(top.red, 0, "a short question is not pushed to the top of the sheet")
    }
}
