import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 A survey's unstyled text takes its ink from the survey's authored background, not from the phone's appearance —
 RENDERED through the real `SurveyContainerView` in a key window whose appearance is dark, on a white survey.
 Before the fix the default text colour followed the phone, so in dark mode the question and the "Yes" label were
 drawn white on white (the "No" label, hard-wired to `.primary`, stayed dark).

 Oracle: the same survey with `text_color` #1a1a1a authored — the ink the unauthored survey must reach. The harness
 control: the unauthored survey in a LIGHT window draws that same ink, so a matching count is not an empty frame.
 RED CONTROL: in `SurveyContainerView.textColor`, fall back on `colorScheme == .dark ? "#FFFFFF" : "#1a1a1a"` again —
 `testAWhiteSurveyInADarkPhoneDrawsDarkText` fails. Android `SurveySurfaceInkRenderTest` is the same check.
*/
@MainActor
final class SurfaceInkSurveyTests: XCTestCase {
    private let size = CGSize(width: 393, height: 700)

    private func darkInk(textColor: String?, phoneDark: Bool) throws -> Int {
        let tc = textColor.map { ", \"text_color\": \"\($0)\"" } ?? ""
        let json = """
        { "id": "s", "name": "s", "survey_type": "custom",
          "questions": [ { "id": "q1", "type": "yes_no", "text": "Is this question readable", "required": true } ],
          "appearance": { "presentation": "fullscreen", "show_progress": false,
                          "theme": { "background_color": "#FFFFFF"\(tc) } } }
        """
        let config = try JSONDecoder().decode(SurveyConfig.self, from: Data(json.utf8))
        // White behind the survey too: a dark window leaves black wherever the survey does not paint, and that is not ink.
        let host = UIHostingController(rootView: SurveyContainerView(config: config, completion: { _ in })
            .frame(width: size.width, height: size.height).background(Color.white))
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = phoneDark ? .dark : .light
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

    func testAWhiteSurveyInADarkPhoneDrawsDarkText() throws {
        let unauthored = try darkInk(textColor: nil, phoneDark: true)
        let oracle = try darkInk(textColor: "#1a1a1a", phoneDark: true)
        let lightPhone = try darkInk(textColor: nil, phoneDark: false)
        print("[surface-ink] ios survey white-in-dark=\(unauthored) oracle=\(oracle) light-phone=\(lightPhone)")
        XCTAssertGreaterThan(oracle, 300, "harness: the authored dark text is visible")
        XCTAssertGreaterThanOrEqual(lightPhone, oracle * 95 / 100, "harness: a light phone draws the same dark text")
        XCTAssertGreaterThanOrEqual(unauthored, oracle * 95 / 100, "the unauthored text on a white survey is dark in a dark phone")
    }
}
