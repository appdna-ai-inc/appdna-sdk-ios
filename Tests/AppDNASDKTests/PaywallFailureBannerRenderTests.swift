import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/*
 DOES THE RENDERER DRAW THE FAILURE BANNER WHEN THE FAILURE ARRIVES?

 The device walk on an iPhone 17 Pro simulator showed `purchase_failed` recorded and the CTA
 re-enabled — so `handlePostPurchaseFailure` ran and `.paywallPurchaseEnded` was delivered — and NO
 banner, for a paywall whose published `on_failure` is `retry` with authored text. The shared fixture
 `paywall_failure_empty_text_falls_back` already proves the manager POSTS `.paywallPurchaseFailure`
 with that payload. This is the other half: a real `PaywallRenderer` in a real key window is sent the
 notification in exactly the manager's shape, and the pixels are read.

 The control is in the same test: the same renderer BEFORE the notification must contain no banner
 red, so a pass cannot come from a red that was always there.
*/
@MainActor
final class PaywallFailureBannerRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)

    private func config() throws -> PaywallConfig {
        let json = """
        {
          "id": "render_failure_banner",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "header", "config": { "title": "Choose a plan" } },
              { "type": "plans", "config": { "plan_display_style": "vertical_stack", "plans": [
                { "product_id": "plan_a", "label": "Alpha", "price_display": "$1.11", "is_default": true },
                { "product_id": "plan_b", "label": "Bravo", "price_display": "$2.22", "is_default": false }
              ] } },
              { "type": "cta", "config": { "cta": { "text": "Continue" } } }
            ]
          },
          "post_purchase": { "on_failure": { "action": "retry", "message": "Card declined.", "retry_text": "Try again" } }
        }
        """
        return try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    /// The banner's fill (`Color.red.opacity(0.9)` over white) and, below it, the first band of other
    /// strong colour — the CTA. Rows are POINTS (the image is rendered at the screen scale).
    private struct RedRegion { let count: Int; let minY: CGFloat; let maxY: CGFloat; let ctaTop: CGFloat? }

    private func redRegion(_ image: UIImage) throws -> RedRegion {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        // The buffer stays pinned for the context's whole life — `&bytes` alone is valid only for
        // the duration of the initializer call, and the draw then writes through a dangling pointer.
        let drawn: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn, "could not read the rendered pixels")
        // Drawing a CGImage into a bitmap context stores its rows top-down (the context's flipped
        // origin and the image's cancel) — the first version of this test flipped them again and read
        // a banner at the BOTTOM of the screen as one near the top.
        func pixel(_ x: Int, _ yTop: Int) -> (Int, Int, Int) {
            let i = (yTop * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 200 && p.1 < 110 && p.2 < 110 }
        func isStrong(_ p: (Int, Int, Int)) -> Bool { max(p.0, p.1, p.2) - min(p.0, p.1, p.2) > 80 && !isRed(p) }
        var count = 0, minY = Int.max, maxY = Int.min
        for y in 0..<h {
            for x in stride(from: 0, to: w, by: 1) where isRed(pixel(x, y)) {
                count += 1
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let scale = image.scale
        guard count > 0 else { return RedRegion(count: 0, minY: 0, maxY: 0, ctaTop: nil) }
        // The CTA: the first row below the banner where a quarter of the row is strong, non-red colour.
        var ctaTop: CGFloat?
        for y in (maxY + 1)..<h {
            let strong = stride(from: 0, to: w, by: 4).filter { isStrong(pixel($0, y)) }.count
            if strong > w / 16 { ctaTop = CGFloat(y) / scale; break }
        }
        return RedRegion(count: count, minY: CGFloat(minY) / scale, maxY: CGFloat(maxY) / scale, ctaTop: ctaTop)
    }

    private func snapshot(_ host: UIHostingController<some View>) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
    }

    func testAPostedFailureDrawsTheBannerAboveTheCta() throws {
        let view = PaywallRenderer(
            config: try config(),
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let before = try redRegion(snapshot(host))
        XCTAssertEqual(before.count, 0, "THE CONTROL: the page has banner red before any failure")

        // Exactly what `PaywallManager.handlePostPurchaseFailure` posts for `retry`.
        NotificationCenter.default.post(name: .paywallPurchaseFailure, object: nil, userInfo: [
            "message": "Card declined.",
            "retry_text": "Try again",
            "allow_dismiss": true,
            "action": "retry",
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let afterImage = snapshot(host)
        // The frame itself, for the closing evidence (written to the Mac's /tmp from the simulator).
        try? afterImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/fb1105-after.png"))
        let after = try redRegion(afterImage)
        NSLog("[#1105] red pixels before=\(before.count) after=\(after.count) banner=\(after.minY)...\(after.maxY)pt cta top=\(after.ctaTop.map { "\($0)" } ?? "none")pt of \(size.height)pt")
        XCTAssertGreaterThan(after.count, 5_000, "no failure banner was drawn after `.paywallPurchaseFailure`")
        let ctaTop = try XCTUnwrap(after.ctaTop, "no CTA was found below the banner — the banner is not above it")
        let gap = ctaTop - after.maxY
        XCTAssertTrue((8...32).contains(gap),
                      "the banner should sit ~16pt above the pinned CTA group; the gap is \(gap)pt "
                        + "(banner bottom \(after.maxY)pt, CTA top \(ctaTop)pt)")
    }
}
