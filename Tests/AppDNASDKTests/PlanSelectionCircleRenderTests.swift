// PlanSelectionCircleRenderTests.swift
//
// RENDERED through the real `PaywallRenderer`, read back as pixels: every card plan layout draws the selection
// circle. `mini_cards`, `single_hero` and `carousel_cards` stack their content down the middle and overlay
// `PlanSelectionCircle` at the top trailing corner; `grid`, `horizontal_scroll` and the vertical stack draw it through
// `PlanCard`. Android `PlanSelectionCircleDrawnTest` is the same check. A selected card's outline is the same magenta
// and is excluded by the interior count, so an outline alone counts close to nothing.
import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PlanSelectionCircleRenderTests: XCTestCase {

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

    private func plansPaywall(_ style: String, selectedText: String? = nil) -> String {
        let text = selectedText.map { ", \"selected_text_color\": \"\($0)\"" } ?? ""
        return """
        {
          "id": "render_circle_\(style)",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "id": "p", "type": "plans", "config": { "plan_display_style": "\(style)", "selected_border_color": "#FF00FF"\(text),
                "plans": [
                  { "id": "plan_a", "product_id": "app.synthetic.annual", "label": "Plan", "price_display": "$1", "is_default": true }
                ] } }
            ]
          },
          "cta": { "text": "Continue", "style": { "bg_color": "#111111", "text_color": "#FFFFFF" } }
        }
        """
    }

    /// Magenta pixels inside each row's magenta extent, leaving out the border columns and the full-width border
    /// rows — so a card's coloured outline alone counts (nearly) nothing and a filled circle inside it counts a lot.
    private func interiorMagenta(_ cg: CGImage) -> Int {
        let (b, w, h) = rgba(cg)
        var interior = 0
        for y in 0..<h {
            var xs: [Int] = []
            for x in 0..<w {
                let i = (y * w + x) * 4
                if magenta(Int(b[i]), Int(b[i + 1]), Int(b[i + 2])) { xs.append(x) }
            }
            guard xs.count >= 2 else { continue }
            let left = xs.first! + 12, right = xs.last! - 12
            guard right > left else { continue }
            let inside = xs.filter { $0 >= left && $0 <= right }.count
            if inside * 2 < right - left { interior += inside }
        }
        return interior
    }

    /// The layouts that draw through `PlanCard`: a filled circle inside the selected card's outline.
    func testThePlanCardLayoutsDrawTheSelectionCircle() throws {
        for style in ["vertical_stack", "grid", "horizontal_scroll"] {
            let n = interiorMagenta(try render(plansPaywall(style)))
            print("[plan-circle] ios \(style)=\(n)")
            XCTAssertGreaterThan(n, 50, "\(style) drew no selection circle (\(n))")
        }
    }

    /// The layouts with their own cards. Their text never takes `selected_text_color`, so with it set to green the
    /// only green on the page is the circle `PlanSelectionCircle` draws in it. Without the circle the count is 0.
    func testTheCustomCardLayoutsDrawTheSelectionCircle() throws {
        let green = { (r: Int, g: Int, b: Int) in r < 90 && g > 150 && b < 90 }
        for style in ["mini_cards", "carousel_cards", "single_hero"] {
            let n = count(try render(plansPaywall(style, selectedText: "#00C000")), topFraction: 1.0, green)
            print("[plan-circle] ios \(style) circle-green=\(n)")
            XCTAssertGreaterThan(n, 150, "\(style) drew no selection circle (\(n) green pixels)")
        }
    }
}
