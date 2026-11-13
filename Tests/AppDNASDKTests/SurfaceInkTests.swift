// SurfaceInkTests.swift
//
// Default ink and system controls resolve against the surface they are drawn on, not the phone's appearance.
// The flow host is rendered in a real key window with a forced appearance, then its pixels are counted inside each
// labelled element's accessibility frame. Authored colours always win.

import XCTest
import SwiftUI
@testable import AppDNASDK

@MainActor
class SurfaceInkTestCase: XCTestCase {
    struct Counts { var light = 0, dark = 0, red = 0, inkOnWhite = 0, inkOnDark = 0 }

    /// Each element's frame from the most recent `render`.
    var lastFrames: [String: CGRect] = [:]
    /// The window of the most recent `render`, kept to read a control's traits.
    var lastWindow: UIWindow?

    static let white = ##"{"type":"color","color":"#FFFFFF"}"##
    static let navy = ##"{"type":"color","color":"#0F172A"}"##

    func flow(background: String, blocksJSON: String) throws -> OnboardingFlowConfig {
        // The bottom zone, as `UnstyledInkTests` does: the middle zone is a scroll view this render path does not draw.
        let bottomZone = blocksJSON.replacingOccurrences(of: #"{"id":"b_"#, with: #"{"zone":"bottom","id":"b_"#)
        let json = #"{"id":"ink_probe","name":"Ink probe","version":1,"steps":[{"id":"s_ink","type":"custom","config":{"background":"#
            + background + #","content_blocks":["# + bottomZone
            + #"]}},{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    func render(_ flow: OnboardingFlowConfig, elements: [String], appearance: UIUserInterfaceStyle) throws -> [String: Counts] {
        _ = A11yAutomation.enabled
        let size = CGSize(width: 393, height: 852)
        let host = UIHostingController(rootView: AnyView(OnboardingFlowHost(
            flow: flow, delegate: nil, eventTracker: nil,
            onStepViewed: { _, _ in }, onStepCompleted: { _, _, _ in }, onStepSkipped: { _, _ in },
            onFlowCompleted: { _ in }, onFlowDismissed: { _, _ in }
        )))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = appearance
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        var frames: [String: CGRect] = [:]
        // #1780: read through `A11yTree`, which re-asserts the simulator-wide accessibility switch and waits for
        // every element when another process has turned it off.
        let tree = A11yTree.read([host.view]) { els in Set(elements).isSubset(of: Set(els.compactMap(\.accessibilityLabel))) }
        for o in tree { if let l = o.accessibilityLabel, elements.contains(l), frames[l] == nil { frames[l] = o.accessibilityFrame } }
        XCTAssertEqual(Set(frames.keys), Set(elements), "control: the harness finds every element's frame\(A11yTree.diagnosis(tree))")
        lastFrames = frames
        lastWindow = window

        let image = UIGraphicsImageRenderer(size: size).image { ctx in host.view.layer.render(in: ctx.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / size.width
        var buffer = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: cg.width, height: cg.height)))

        var out: [String: Counts] = [:]
        for (name, f) in frames {
            var c = Counts()
            let x0 = max(0, Int(f.minX * scale)), x1 = min(cg.width, Int(f.maxX * scale))
            let y0 = max(0, Int(f.minY * scale)), y1 = min(cg.height, Int(f.maxY * scale))
            if x0 < x1, y0 < y1 {
                for y in y0..<y1 {
                    let row = y * cg.width * 4
                    for x in x0..<x1 {
                        let i = row + x * 4
                        let r = Double(buffer[i]), g = Double(buffer[i + 1]), b = Double(buffer[i + 2])
                        let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                        if lum < 0.7 { c.inkOnWhite += 1 }
                        if lum > 0.35 { c.inkOnDark += 1 }
                        if lum > 0.75 { c.light += 1 }
                        if lum < 0.45 { c.dark += 1 }
                        if r > 200, g < 80, b < 80 { c.red += 1 }
                    }
                }
            }
            out[name] = c
        }
        return out
    }

    let ink = 40
    /// How long the step gets to finish appearing before its frame is read.
    var settle: TimeInterval = 1.0
}

final class SurfaceInkOptionsTests: SurfaceInkTestCase {
    private let labels = ["Option alpha", "Option beta"]

    private func select(_ style: String, extra: String = "") -> String {
        #"{"id":"b_sel","type":"input_select","field_id":"pick","field_options":[{"id":"a","value":"a","label":"Option alpha"},{"id":"b","value":"b","label":"Option beta"}],"field_config":{"display_style":""#
            + style + #"""# + extra + "}}"
    }

    func testOptionStylesAreDarkOnAWhiteStepInADarkAppearance() throws {
        for style in ["list", "stacked", "grid"] {
            let counts = try render(flow(background: Self.white, blocksJSON: select(style)), elements: labels, appearance: .dark)
            for (name, c) in counts { XCTAssertGreaterThan(c.dark, ink, "\(style) \(name) on white in dark mode: \(c)") }
        }
    }

    func testOptionStylesAreLightOnADarkStepInALightAppearance() throws {
        for style in ["list", "stacked", "grid"] {
            let counts = try render(flow(background: Self.navy, blocksJSON: select(style)), elements: labels, appearance: .light)
            for (name, c) in counts { XCTAssertGreaterThan(c.light, ink, "\(style) \(name) on navy in light mode: \(c)") }
        }
    }

    func testSegmentedLabelsAreDarkOnAWhiteStepInADarkAppearance() throws {
        let block = #"{"id":"b_seg","type":"input_segmented","field_id":"pick","field_options":[{"id":"a","value":"a","label":"Option alpha"},{"id":"b","value":"b","label":"Option beta"}]}"#
        let counts = try render(flow(background: Self.white, blocksJSON: block), elements: labels, appearance: .dark)
        for (name, c) in counts { XCTAssertGreaterThan(c.dark, ink, "segmented \(name) on white in dark mode: \(c)") }
    }

    func testAnAuthoredLabelColourStillWins() throws {
        let block = select("list", extra: ##","text_color":"#FF0000""##)
        let counts = try render(flow(background: Self.white, blocksJSON: block), elements: labels, appearance: .dark)
        for (name, c) in counts { XCTAssertGreaterThan(c.red, ink, "authored red \(name): \(c)") }
    }

    func testAnOptionWithItsOwnLightFillKeepsDarkInkOnADarkStep() throws {
        let block = select("stacked", extra: ##","bg_color":"#FFFFFF""##)
        let counts = try render(flow(background: Self.navy, blocksJSON: block), elements: labels, appearance: .light)
        for (name, c) in counts { XCTAssertGreaterThan(c.dark, ink, "\(name) on an authored light fill: \(c)") }
    }
}
