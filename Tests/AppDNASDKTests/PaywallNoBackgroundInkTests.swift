// PaywallNoBackgroundInkTests.swift
//
// A paywall with no authored background paints the system's page; its default ink reads that page, not an
// assumed one (#1681). Before, the ink read a page colour of nil, which answers white, on a white page.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PaywallNoBackgroundInkTests: XCTestCase {
    private let size = CGSize(width: 393, height: 320)

    private func paywall(background: String?) throws -> PaywallConfig {
        let bg = background.map { #""background": \#($0),"# } ?? ""
        let json = """
        { "id": "pw_ink", "name": "Ink",
          "layout": { "type": "stack", \(bg)
            "sections": [ { "id": "h", "type": "header", "data": { "title": "WWWWWWWWWWW" } } ] } }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    /// Dark-ink and light-ink pixel counts in the rendered paywall.
    private func counts(_ config: PaywallConfig, appearance: UIUserInterfaceStyle) throws -> (dark: Int, light: Int) {
        let view = PaywallRenderer(config: config, onPlanSelected: { _, _ in }, onRestore: {}, onDismiss: { _ in })
            .frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = appearance
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.overrideUserInterfaceStyle = appearance
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        _ = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var dark = 0, light = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let lum = (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
            if lum < 0.45 { dark += 1 }
            if lum > 0.75 { light += 1 }
        }
        return (dark, light)
    }

    func testNoBackgroundOnALightPhoneDrawsDarkInk() throws {
        let c = try counts(paywall(background: nil), appearance: .light)
        NSLog("[paywall-no-bg] light phone: dark=\(c.dark) light=\(c.light)")
        XCTAssertGreaterThan(c.dark, 800, "the header is the page's colour")
    }

    func testNoBackgroundOnADarkPhoneDrawsLightInk() throws {
        let c = try counts(paywall(background: nil), appearance: .dark)
        NSLog("[paywall-no-bg] dark phone: dark=\(c.dark) light=\(c.light)")
        XCTAssertGreaterThan(c.light, 800, "the header is the page's colour")
    }

    func testAColourWithNoValueDrawsDarkInkOnTheWhiteItPaints() throws {
        let c = try counts(paywall(background: #"{"type":"color"}"#), appearance: .light)
        NSLog("[paywall-color-no-value] dark=\(c.dark) light=\(c.light)")
        XCTAssertGreaterThan(c.dark, 800, "the header is the page's colour")
    }

    func testAnAuthoredDarkPageKeepsItsLightInk() throws {
        let c = try counts(paywall(background: ##"{"type":"color","value":"#111827"}"##), appearance: .light)
        NSLog("[paywall-authored-dark] dark=\(c.dark) light=\(c.light)")
        XCTAssertGreaterThan(c.light, 800, "an authored dark page lost its ink")
    }
}
