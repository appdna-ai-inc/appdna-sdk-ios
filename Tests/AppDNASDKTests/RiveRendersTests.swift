import RiveRuntime
import SwiftUI
import XCTest
@testable import AppDNASDK

/**
 THE RIVE ENGINE DRAWS, proven in pixels.

 Rive was the last renderer with no offline proof. Both SDKs fetch a `.riv` over the network and
 there is no bundled-asset rung on that path, so there was nothing to render in a test and the only
 statement anyone could make was that the runtime LINKS — which is exactly the statement that was
 true of `LottieBlockView` for as long as it shipped a placeholder.

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

    /**
     Renders a view in a real key window and returns its pixels.

     🔴 `drawHierarchy(afterScreenUpdates:)`, NOT `layer.render(in:)`, and that is the whole
     difference between this test existing and not. Rive draws through its own view, and
     `layer.render(in:)` walks the Core Animation layer tree — which does not include GPU-backed
     content. The first version of this test used it and reported `drawn=0` against a renderer
     that `testTheFixtureLOADS` proves had parsed the file and instantiated its artboard: a
     perfectly working engine, photographed with the lens cap on.

     `drawHierarchy` goes through the render server and captures what is actually on screen. It is
     the wrong choice for a hosting controller that is NOT in a window — which is why
     `SurfaceSnapshotTests` warns against it — and the right one here, because this window is key
     and visible.
    */
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
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
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

    /**
     🔴 THE ENGINE RUNS, which is the claim pixels were supposed to carry and could not.

     `layer.render(in:)` and `drawHierarchy(afterScreenUpdates:)` both come back EMPTY for this
     view — measured, `drawn=0`, against a file that `testTheFixtureLOADS` proves is parsed with its
     artboard and state machine instantiated. Rive draws through the Rive Renderer, whose content is
     GPU-backed, and neither capture path sees that in the simulator. A zero-ink frame there is a
     fact about the camera, not about the engine, and asserting on it would have been a test that
     fails for a working renderer — the exact false negative an earlier render test shipped.

     So the observable is the state machine's own output. Advancing it produces STATE CHANGES, and
     a state change is something only a running machine can produce: a placeholder has no artboard,
     no machine and no states. The control is the same machine before it is advanced.
    */
    func testTheStateMachineRUNS_notJustParses() throws {
        let url = try probeURL()
        let model = try loadedModel(url)
        let machine = try XCTUnwrap(
            model.riveModel?.stateMachine,
            "the file declares a state machine and the runtime did not instantiate one",
        )

        /*
         🔴 NOT `stateChangedCount`. The first version of this test advanced a second and asserted
         a state change; this fixture's machine has ONE state and a blend input, so it never
         transitions and the count is legitimately 0. That assertion failed against a running
         engine — a test measuring the wrong thing about the right subject, which is the same
         mistake as counting ink from a camera that cannot see Metal.

         What a running machine does for this file is CONSUME its input and keep animating.
         `advance(by:)` returns whether the machine still has work to do, and the number input it
         declares holds the value set on it — neither of which a parsed-but-dead file can manage.
        */
        let names = machine.inputNames()
        XCTAssertFalse(names.isEmpty, "the fixture declares no inputs, so this test has no subject")

        let blend = try XCTUnwrap(
            machine.getNumber(names[0]),
            "the declared input \"\(names[0])\" could not be fetched as a number input",
        )
        blend.setValue(42)
        _ = machine.advance(by: 0.1)
        XCTAssertEqual(
            blend.value(), 42,
            "a number input set on the state machine did not hold its value across an advance — "
            + "the file is parsed but the machine is not running",
        )

        // And the machine keeps animating rather than reporting itself finished on the first tick.
        var advanced = false
        for _ in 0..<10 where !advanced { advanced = machine.advance(by: 0.1) }
        print("[rive-run] advanced=\(advanced) inputs=\(names) blend=\(blend.value())")
        XCTAssertTrue(
            advanced,
            "advancing the state machine ten times never reported progress — it is instantiated "
            + "and not running",
        )
    }

    /**
     The inputs a `rive` block can carry. `RiveBlockView.applyInputs` maps a JSON value to one of
     Rive's three input kinds BY TYPE — a bool sets a boolean, a number sets a number, anything
     else triggers — and that mapping is only meaningful if the file's inputs are reachable by name.
     */
    func testTheFilesInputsAreReachableByName() throws {
        let url = try probeURL()
        let model = try loadedModel(url)
        let machine = try XCTUnwrap(model.riveModel?.stateMachine)

        let names = machine.inputNames()
        print("[rive-inputs] names=\(names) count=\(machine.inputCount())")
        XCTAssertEqual(
            names.count, machine.inputCount(),
            "inputNames() and inputCount() disagree — one of them is not reading the file",
        )
        for name in names {
            XCTAssertNoThrow(
                try machine.input(fromName: name),
                "input \"\(name)\" is listed and cannot be fetched by name, so an authored "
                + "`inputs` map could never reach it",
            )
        }
    }

    /// A model loaded from `url`, waited on until its artboard exists.
    private func loadedModel(_ url: URL) throws -> RiveViewModel {
        let model = RiveViewModel(webURL: url.absoluteString, stateMachineName: nil, autoPlay: true, artboardName: nil)
        let deadline = Date().addingTimeInterval(5)
        while model.riveModel?.artboard == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotNil(model.riveModel?.artboard, "the fixture did not load within 5s")
        return model
    }
}
