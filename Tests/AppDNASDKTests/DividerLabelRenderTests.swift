// DividerLabelRenderTests.swift — #976
//
// DOES THE DIVIDER'S LABEL DRAW ITS AUTHORED BACKGROUND?
//
// 🔴 Why pixels. `label_bg_color` is DECODED by both SDKs and was drawn by one: Android gave the
// divider's label a rounded chip (`PaywallActivity.kt`), iOS hard-coded `.background(Color.clear)`.
// One authored document rendered as a chip on Android and as bare text on iOS — the divergence
// class ADR-001 exists to prevent — and no gate could see it, because both platforms "read" the
// key. Only what ends up on screen settles it.
//
// The harness is `SurfaceSnapshotTests`': a real `PaywallRenderer` in a real key window,
// `layer.render(in:)`, PNG out, then the pixels counted. Not the accessibility tree — SwiftUI
// builds that lazily and a hostless test never triggers it.
//
// 🔴 EVERY ASSERTION HAS ITS CONTROL. "The colour is present" proves nothing unless the same
// harness can be shown NOT finding it when it is not authored, so each case renders a pair.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class DividerLabelRenderTests: XCTestCase {

    private let size = CGSize(width: 393, height: 852)
    /// Nothing else on the page is this colour, so one pixel of it is the authored chip.
    private let chip = "#FF00AA"

    /*
     The first render in a process is not representative — whatever `layer.render(in:)` warms
     (fonts, the window, SwiftUI's first layout pass) makes render #1 differ from render #2 of the
     same view. One throwaway render happens before any measurement.
     */
    override func setUp() async throws {
        try await super.setUp()
        _ = try? renderPNG(config(labelBgColor: nil))
    }

    /// A paywall whose only content section is a divider carrying a label.
    private func config(labelBgColor: String?) -> PaywallConfig {
        let bg = labelBgColor.map { "\"label_bg_color\": \"\($0)\"," } ?? ""
        let json = """
        {
          "id": "render_divider_label",
          "layout": {
            "type": "stack",
            "background": { "type": "color", "value": "#FFFFFF" },
            "sections": [
              { "type": "divider", "config": { \(bg) "label_text": "OR", "label_color": "#111111", "label_font_size": 14 } },
              { "type": "cta", "config": { "cta": { "text": "Continue" } } }
            ]
          }
        }
        """
        // The fixture is this test's own; a decode failure is a test defect, not a product one.
        return try! JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    private func renderPNG(_ config: PaywallConfig) throws -> UIImage {
        let view = PaywallRenderer(
            config: config,
            onPlanSelected: { _, _ in },
            onRestore: {},
            onDismiss: { _ in }
        ).frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .clear
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        return image
    }

    /// How many pixels are within `tolerance` of `hex`.
    private func count(_ image: UIImage, colour hex: String, tolerance: Int = 24) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let want = hex.dropFirst()
        let r = Int(want.prefix(2), radix: 16) ?? 0
        let g = Int(want.dropFirst(2).prefix(2), radix: 16) ?? 0
        let b = Int(want.dropFirst(4).prefix(2), radix: 16) ?? 0
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if abs(Int(pixels[i]) - r) <= tolerance,
               abs(Int(pixels[i + 1]) - g) <= tolerance,
               abs(Int(pixels[i + 2]) - b) <= tolerance { n += 1 }
        }
        return n
    }

    func testAnAuthoredLabelBackgroundIsDrawn() throws {
        let without = try renderPNG(config(labelBgColor: nil))
        let with = try renderPNG(config(labelBgColor: chip))

        let absent = count(without, colour: chip)
        let present = count(with, colour: chip)

        // The control: the harness must NOT find the colour when nothing authored it. Without this
        // the assertion below could pass against a page that happened to contain it.
        XCTAssertEqual(absent, 0, "the chip colour must not appear when `label_bg_color` is unset")
        XCTAssertGreaterThan(
            present, 100,
            "an authored `label_bg_color` must draw behind the divider's label — iOS hard-coded "
            + "`.background(Color.clear)` while Android drew the chip (#976)"
        )
    }
}
