import Lottie
import SwiftUI
import XCTest
@testable import AppDNASDK

/**
 #982 — THE ANIMATION DRAWS, proven in pixels.

 The engines being linked is a BUILD fact and this issue is a PIXEL one: `LottieBlockView` shipped
 a placeholder for as long as the block type existed, and a placeholder is a perfectly good view —
 it renders, it lays out, it passes a blank check. Nothing short of reading the frame can tell a
 real renderer from a modelled one, which is exactly why the stub survived every gate.

 So this renders the REAL `LottieBlockView` over a real `.json` in a real key window — the same
 harness `SurfaceSnapshotTests` uses, and the one that caught the invisible selected plan in #966
 and the unsubstituted price in #923 — and reads the pixels back.

 🔴 THE CONTROL IS THE WHOLE TEST. "The frame has dark pixels" would pass for the placeholder too:
 it drew a play glyph and two lines of text. So the assertions are DIFFERENCES — a block with a
 URL against the same block with none — which no placeholder can satisfy, because the placeholder
 drew its box whether the URL was there or not.
 */
final class LottieRendersTests: XCTestCase {

    private let size = CGSize(width: 200, height: 200)

    private func probeURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "LottieProbe", withExtension: "json"),
            "LottieProbe.json is not in the test bundle — Package.swift must `.copy` it",
        )
    }

    private func block(url: String?) -> LottieBlock {
        LottieBlock(
            lottie_url: url,
            autoplay: true,
            loop: true,
            speed: 1,
            width: Double(size.width),
            height: Double(size.height),
            alignment: "center",
            play_on_scroll: nil,
            play_on_tap: nil
        )
    }

    /// Renders a view in a real key window and returns its pixels. `ImageRenderer` draws a
    /// `ScrollView`'s content as empty and `drawHierarchy` draws SwiftUI blank, so
    /// `layer.render(in:)` on a hosted view is the path that works (see `SurfaceSnapshotTests`).
    private func pixels(_ view: some View) throws -> [UInt8] {
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .white

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Let Lottie load the file and lay its layers out.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var buffer = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: cg.width, height: cg.height)))
        window.isHidden = true
        return buffer
    }

    /**
     One frame of an already-hosted view, so successive calls see the animation ADVANCE.

     🔴 THE **PRESENTATION** LAYER, not the model layer. `layer.render(in:)` draws the layer's
     MODEL state — where Core Animation says the layer will end up — so two renders during a
     running animation are byte-identical however long you wait. The first version of this test
     used the model layer and reported "differing bytes = 0" against a view that was demonstrably
     animating, which is a false negative manufactured entirely by the harness.
    */
    private func snapshot(_ host: UIViewController) -> [UInt8] {
        let layer = host.view.layer.presentation() ?? host.view.layer
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in layer.render(in: ctx.cgContext) }
        guard let cg = image.cgImage else { return [] }
        var buffer = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let context = CGContext(
            data: &buffer, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: cg.width, height: cg.height)))
        return buffer
    }

    /// Pixels that are neither the white background nor fully transparent.
    private func inkCount(_ buffer: [UInt8]) -> Int {
        var ink = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let (r, g, b, a) = (buffer[i], buffer[i + 1], buffer[i + 2], buffer[i + 3])
            guard a > 0 else { continue }
            if r < 200 || g < 200 || b < 200 { ink += 1 }
        }
        return ink
    }

    func testTheAnimationDrawsAndAnEmptyBlockDrawsNothing() throws {
        let url = try probeURL()

        let withAnimation = try inkCount(pixels(LottieBlockView(block: block(url: url.absoluteString))))
        let withoutURL = try inkCount(pixels(LottieBlockView(block: block(url: nil))))

        print("[lottie-render] withAnimation=\(withAnimation) withoutURL=\(withoutURL)")

        /*
         🔴 The control first. A URL-less block must draw NOTHING — which is also the assertion
         that fails against the placeholder, because the placeholder drew its purple box, its play
         glyph and the words "Lottie Animation" with no URL at all.
        */
        XCTAssertEqual(
            withoutURL, 0,
            "a Lottie block with no URL put ink on the page — that is the placeholder, or something like it",
        )
        XCTAssertGreaterThan(
            withAnimation, 0,
            "the engine drew nothing for a valid .json — it is linked but not rendering",
        )
    }

    /// The frame CHANGES over time, which is the difference between an animation and a still.
    func testTheAnimationIsAnimating() throws {
        let url = try probeURL()
        let view = LottieBlockView(block: block(url: url.absoluteString))

        /*
         🔴 ONE hosted view, rendered twice — not `pixels()` twice. Each `pixels()` call builds a
         fresh `UIHostingController` and window, so the animation starts again from frame 0 and the
         two frames are identical BY CONSTRUCTION. The first version of this test did exactly that
         and reported "differing bytes = 0" against a correctly animating view: a false negative
         produced entirely by the harness.
        */
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .white
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let first = snapshot(host)
        // Long enough for the 30-frame, 1-second probe to have moved its square a long way.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let second = snapshot(host)
        window.isHidden = true

        let differing = zip(first, second).filter { $0 != $1 }.count
        print("[lottie-render] differing bytes between two renders=\(differing)")
        XCTAssertGreaterThan(
            differing, 0,
            "two renders 0.4s apart are identical — the animation is a still frame, not playing",
        )
    }
}
