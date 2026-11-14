// PaywallAccentRenderTests.swift
//
// RENDERED through the real `PaywallRenderer`, read back as pixels: the social-proof trial badge takes the paywall's
// accent (the CTA's authored colour), and an authored `badge_color` wins over it. Android `PaywallAccentRenderTest`
// is the same check; `dto_parsing/paywall_trial_badge_color` pins the colour chain on both.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PaywallAccentRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    private func render(_ json: String) throws -> CGImage {
        let config = try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
        let view = PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .white
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func rgba(_ cg: CGImage) -> (bytes: [UInt8], w: Int, h: Int) {
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (bytes, w, h)
    }

    /// Pixels matching `match` in the top `fraction` of the frame (the CTA is pinned below it).
    private func count(_ cg: CGImage, topFraction fraction: Double, _ match: (Int, Int, Int) -> Bool) -> Int {
        let (b, w, h) = rgba(cg)
        var n = 0
        for y in 0..<Int(Double(h) * fraction) {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if match(Int(b[i]), Int(b[i + 1]), Int(b[i + 2])) { n += 1 }
            }
        }
        return n
    }

    private let magenta = { (r: Int, g: Int, b: Int) in r > 180 && g < 110 && b > 180 }
    private let green = { (r: Int, g: Int, b: Int) in r < 90 && g > 150 && b < 90 }

    private func badgePaywall(badgeColor: String?) -> String {
        let colour = badgeColor.map { ", \"badge_color\": \"\($0)\"" } ?? ""
        return """
        {
          "id": "render_trial_badge",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "id": "h", "type": "header", "config": { "title": "Go Premium" } },
              { "id": "sp", "type": "social_proof", "config": { "sub_type": "trial_badge", "text": "WWWWWWWW WWWW"\(colour) } }
            ]
          },
          "cta": { "text": "Continue", "style": { "bg_color": "#FF00FF", "text_color": "#FFFFFF" } }
        }
        """
    }

    func testTheTrialBadgeTakesTheCtaColour() throws {
        let frame = try render(badgePaywall(badgeColor: nil))
        let m = count(frame, topFraction: 0.55, magenta)
        print("[paywall-accent] ios cta-colour badge magenta=\(m)")
        XCTAssertGreaterThan(m, 100, "the trial badge is not drawn in the CTA's colour")
    }

    func testAnAuthoredBadgeColourWinsOverTheCtaColour() throws {
        let frame = try render(badgePaywall(badgeColor: "#00C000"))
        let g = count(frame, topFraction: 0.55, green)
        let m = count(frame, topFraction: 0.55, magenta)
        print("[paywall-accent] ios badge_color green=\(g) magenta=\(m)")
        XCTAssertGreaterThan(g, 100, "the trial badge is not drawn in its authored badge_color")
        XCTAssertLessThan(m, 20, "the trial badge is still drawn in the CTA's colour")
    }

}
