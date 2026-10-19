import RiveRuntime
import SwiftUI
import XCTest
@testable import AppDNASDK

/**
 #990 — THE RIVE ENGINE DRAWS, proven in pixels.

 Rive was the last renderer with no offline proof. Both SDKs fetch a `.riv` over the network and
 there is no bundled-asset rung on that path, so there was nothing to render in a test and the only
 statement anyone could make was that the runtime LINKS — which is exactly the statement that was
 true of `LottieBlockView` for as long as it shipped a placeholder (#982).

 🔴 WHAT MADE IT POSSIBLE: `RiveViewModel(webURL:)` hands the string to the runtime's loader, and a
 `file://` URL is a URL. So a fixture in the test bundle renders through the REAL production path —
 `RiveBlockView` → `RiveModelBox` → `RiveViewModel` → the runtime's own view — with nothing stubbed
 and no production change. That is the whole reason this test exists rather than a note saying it
 cannot.

 🔴 THE CONTROL IS THE TEST. "The frame has ink" would pass for a placeholder, for a background, or
 for a layout bug that draws the wrong view. So the assertions are DIFFERENCES: the same block with
 a loadable URL against one with an unloadable URL. A placeholder draws its box either way; a real
 renderer draws only when the file loads.

 The fixture is `teststatemachine.riv` from the rive-ios package's own examples, MIT, 399 bytes —
 see `RiveStateMachineProbe.riv.LICENSE`. It carries a state machine, which is what lets the second
 test say something about `rive_state_machine` rather than only about loading.
 */
final class RiveRendersTests: XCTestCase {

    private let size = CGSize(width: 220, height: 220)

    private func probeURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: "RiveStateMachineProbe", withExtension: "riv"),
            "RiveStateMachineProbe.riv is not in the test bundle — Package.swift must `.copy` it",
        )
    }

    private func block(url: String, stateMachine: String? = nil) -> RiveBlock {
        RiveBlock(
            rive_url: url,
            artboard: nil,
            state_machine: stateMachine,
            autoplay: true,
            height: Double(size.height),
            alignment: "center",
            inputs: nil,
            trigger_on_step_complete: nil
        )
    }

    /// Renders a view in a real key window and returns its pixels. `ImageRenderer` draws a
    /// `ScrollView`'s content as empty and `drawHierarchy` draws SwiftUI blank, so
    /// `layer.render(in:)` on a hosted view is the path that works (see `SurfaceSnapshotTests`).
    private func pixels(_ view: some View, settle: TimeInterval = 2.0) throws -> [UInt8] {
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .white

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Rive reports its load asynchronously — the view model publishes, THEN the view appears.
        // Two seconds is generous for a 399-byte local file and cheap for a test that runs once.
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

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

    /*
     🔴 DIAGNOSTIC FIRST, because "nothing was drawn" has two very different causes and the pixel
     test cannot tell them apart: the FILE did not load, or the harness cannot SEE what Rive drew.
     Rive renders through its own view, and `layer.render(in:)` does not capture a Metal-backed
     layer — so a zero-ink frame may be a perfectly working renderer photographed with the lens cap
     on. This asks the model directly.
    */
    func testTheFixtureLOADS_whateverTheHarnessCanSee() throws {
        let url = try probeURL()
        let model = RiveViewModel(webURL: url.absoluteString, stateMachineName: nil, autoPlay: true, artboardName: nil)
        let deadline = Date().addingTimeInterval(5)
        while model.riveModel?.artboard == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        print("[rive-load] artboard=\(String(describing: model.riveModel?.artboard?.name())) "
              + "stateMachine=\(String(describing: model.riveModel?.stateMachine?.name()))")
        XCTAssertNotNil(
            model.riveModel?.artboard,
            "RiveViewModel could not load a local file:// URL — the runtime's loader is HTTP-only, "
            + "so an offline render proof needs a bundled-asset path in the SDK rather than a URL",
        )
    }

    func testTheAnimationDrawsAndAnUnloadableOneDrawsNothing() throws {
        let url = try probeURL()

        let drawn = try inkCount(pixels(RiveBlockView(block: block(url: url.absoluteString))))
        // A well-formed URL that cannot resolve: the model is built, the fetch fails, and the
        // block must collapse rather than draw a frame of its own.
        let missing = try inkCount(pixels(RiveBlockView(block: block(url: "file:///nonexistent/absent.riv"))))

        print("[rive-render] drawn=\(drawn) missing=\(missing)")

        /*
         🔴 The control first, and it is the assertion a placeholder cannot pass: for as long as
         this block shipped a stub it drew a blue box reading "Rive Animation" whether the URL
         loaded or not.
        */
        XCTAssertEqual(
            missing, 0,
            "a Rive block whose file cannot load put ink on the page — that is a placeholder, or a "
            + "frame drawn before the load was known to have failed",
        )
        XCTAssertGreaterThan(
            drawn, 0,
            "the engine drew nothing for a valid .riv — RiveRuntime is linked but not rendering",
        )
    }

    /**
     #976 documented `rive_state_machine` as "the state machine to run; naming one that does not
     exist falls back to the file's own default rather than drawing nothing". That sentence is a
     claim about behaviour, so it gets a test.
     */
    func testANamedStateMachineStillRenders() throws {
        let url = try probeURL()

        let withNamed = try inkCount(pixels(
            RiveBlockView(block: block(url: url.absoluteString, stateMachine: "State Machine 1"))
        ))
        let withNonsense = try inkCount(pixels(
            RiveBlockView(block: block(url: url.absoluteString, stateMachine: "no-such-machine"))
        ))

        print("[rive-render] withNamed=\(withNamed) withNonsense=\(withNonsense)")

        XCTAssertGreaterThan(withNamed, 0, "a block naming a state machine drew nothing")
        XCTAssertGreaterThan(
            withNonsense, 0,
            "naming a state machine that does not exist drew NOTHING — the docs say it falls back "
            + "to the file's default, so either the renderer or the sentence is wrong",
        )
    }
}
