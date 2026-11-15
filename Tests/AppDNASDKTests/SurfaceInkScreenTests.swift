// SurfaceInkScreenTests.swift
//
// A Screen's unstyled text takes its ink from the screen's authored background, and a section with its own fill from
// that fill — not from the phone's appearance. Rendered through the REAL `ScreenRenderer` in a key window whose
// appearance is the opposite of the authored surface, with a `cta_footer` disclaimer, which is drawn `.secondary`.
// Android `SurfaceInkScreenRenderTest` is the same check; `dto_parsing/screen_surface_ink` pins the rule on both.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class SurfaceInkScreenTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    override func setUp() {
        super.setUp()
        SectionRegistry.shared.registerBuiltInSections()
    }

    private func screen(background: String, sectionFill: String?) throws -> ScreenConfig {
        let style = sectionFill.map { ", \"style\": { \"background_color\": \"\($0)\" }" } ?? ""
        let json = """
        {
          "id": "scr_ink",
          "background": { "type": "color", "color": "\(background)" },
          "sections": [
            { "id": "s1", "type": "cta_footer"\(style),
              "data": { "disclaimer_text": "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW WWWWWWWWWWWWWWWW" } }
          ]
        }
        """
        return try JSONDecoder().decode(ScreenConfig.self, from: Data(json.utf8))
    }

    /// Pixels whose luminance is in `band`, with the phone in `phoneDark`.
    private func count(_ config: ScreenConfig, phoneDark: Bool, band: ClosedRange<Double>) throws -> Int {
        let holder = ScreenContextHolder(context: SectionContext(screenId: "scr_ink", onAction: { _ in }))
        let view = ScreenRenderer(config: config, context: holder).frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = phoneDark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var n = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let l = (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255
            if band.contains(l) { n += 1 }
        }
        return n
    }

    func testAWhiteScreenInADarkPhoneDrawsDarkText() throws {
        // `.secondary` resolved light is mid-grey on white (~0.54 on this scale); resolved dark it is ~0.93, close to the
        // white itself. The band holds the first and not the second.
        let n = try count(screen(background: "#FFFFFF", sectionFill: nil), phoneDark: true, band: 0.3...0.7)
        print("[surface-ink] ios screen white-in-dark=\(n)")
        XCTAssertGreaterThan(n, 200, "dark text on a white screen in a dark phone")
    }

    func testADarkScreenInALightPhoneDrawsLightText() throws {
        // The screen is #0B1220 (lum ~0.06): count only pixels well above it.
        let n = try count(screen(background: "#0B1220", sectionFill: nil), phoneDark: false, band: 0.4...1.0)
        print("[surface-ink] ios screen dark-in-light=\(n)")
        XCTAssertGreaterThan(n, 200, "light text on a dark screen in a light phone")
    }

    func testAWhiteSectionOnADarkScreenDrawsDarkText() throws {
        // Both the screen (~0.06) and the section (1.0) are outside the band: only dark text on the white section lands in it.
        let n = try count(screen(background: "#0B1220", sectionFill: "#FFFFFF"), phoneDark: true, band: 0.45...0.65)
        print("[surface-ink] ios screen white-section-on-dark=\(n)")
        XCTAssertGreaterThan(n, 200, "dark text in a white section on a dark screen")
    }
}
