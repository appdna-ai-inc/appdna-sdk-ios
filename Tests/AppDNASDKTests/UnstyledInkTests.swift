// UnstyledInkTests.swift
//
// Unstyled text, headings and form-field labels are drawn in ink that shows on the step behind them:
// dark on a light step, whatever the device's appearance, and white on a dark, gradient or image step.
// The light-or-dark call is the one the Google logo makes (`GoogleMapsAttribution.needsLightInk`).
// Authored colours always win. The Kotlin twin is `UnstyledInkTest`.
//
// The flow host is rendered in a real key window with a forced appearance. Its layer is rendered to
// pixels (`layer.render(in:)`, the path that draws SwiftUI; see `SurfaceSnapshotTests`), and light,
// dark and red pixels are counted inside each element's own accessibility frame. The blocks sit in the
// step's pinned bottom zone: content inside the step's scroll view publishes no accessibility elements
// in a package test. The controls are a
// white step in a light appearance (dark ink, as before) and authored red on a dark step.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class UnstyledInkTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private static let white = ##"{"type":"color","color":"#FFFFFF"}"##
    private static let navy = ##"{"type":"color","color":"#0F172A"}"##
    private static let gradient = ##"{"type":"gradient","gradient":{"type":"linear","angle":180,"stops":[{"color":"#1E1B4B","position":0},{"color":"#312E81","position":1}]}}"##

    private let elements = ["Big heading", "Some body text here", "Your name label"]

    private func flow(background: String, authored: Bool) throws -> OnboardingFlowConfig {
        let red = authored ? ##","style":{"color":"#FF0000"}"## : ""
        let labelRed = authored ? ##","field_style":{"label_color":"#FF0000"}"## : ""
        let step = #"{"id":"s_ink","type":"custom","config":{"background":"# + background
            + #","content_blocks":[{"id":"b_h","type":"heading","level":1,"zone":"bottom","text":"Big heading""# + red
            + #"},{"id":"b_t","type":"text","zone":"bottom","text":"Some body text here""# + red
            + #"},{"id":"b_in","type":"input_text","zone":"bottom","field_id":"name","field_label":"Your name label""# + labelRed + "}]}}"
        let json = #"{"id":"ink_probe","name":"Ink probe","version":1,"steps":["# + step
            + #",{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    struct Counts { var light = 0, dark = 0, red = 0 }

    /// Each element's light, dark and red pixel counts, rendered in `appearance`.
    private func render(_ flow: OnboardingFlowConfig, appearance: UIUserInterfaceStyle) throws -> [String: Counts] {
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
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        // Each element's frame, from the accessibility tree.
        var frames: [String: CGRect] = [:]
        func walk(_ o: NSObject, _ depth: Int) {
            guard depth < 60 else { return }
            if let l = o.accessibilityLabel, elements.contains(l), frames[l] == nil { frames[l] = o.accessibilityFrame }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } } }
            for e in o.accessibilityElements ?? [] { if let e = e as? NSObject { walk(e, depth + 1) } }
            if let v = o as? UIView { for s in v.subviews { walk(s, depth + 1) } }
        }
        walk(host.view, 0)
        XCTAssertEqual(Set(frames.keys), Set(elements), "control: the harness finds every element's frame")

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in host.view.layer.render(in: ctx.cgContext) }
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
                        if lum > 0.75 { c.light += 1 }
                        if lum < 0.35 { c.dark += 1 }
                        if r > 200, g < 80, b < 80 { c.red += 1 }
                    }
                }
            }
            out[name] = c
        }
        return out
    }

    private let ink = 40

    func testOnAWhiteStepInALightAppearanceTheInkIsDarkAsBefore() throws {
        for (name, c) in try render(flow(background: Self.white, authored: false), appearance: .light) {
            XCTAssertGreaterThan(c.dark, ink, "\(name): dark ink on white (\(c.dark) dark pixels)")
        }
    }

    func testOnAWhiteStepInADarkAppearanceTheInkIsStillDark() throws {
        for (name, c) in try render(flow(background: Self.white, authored: false), appearance: .dark) {
            XCTAssertGreaterThan(c.dark, ink, "\(name): dark ink on white in a dark appearance (\(c.dark) dark pixels)")
        }
    }

    func testOnADarkStepTheInkIsLight() throws {
        for (name, c) in try render(flow(background: Self.navy, authored: false), appearance: .light) {
            XCTAssertGreaterThan(c.light, ink, "\(name): light ink on navy (\(c.light) light pixels)")
        }
    }

    func testOnAGradientStepTheInkIsLight() throws {
        for (name, c) in try render(flow(background: Self.gradient, authored: false), appearance: .light) {
            XCTAssertGreaterThan(c.light, ink, "\(name): light ink on the gradient (\(c.light) light pixels)")
        }
    }

    func testAuthoredColoursStillWinOnADarkStep() throws {
        for (name, c) in try render(flow(background: Self.navy, authored: true), appearance: .light) {
            XCTAssertGreaterThan(c.red, ink, "\(name): the authored red is drawn (\(c.red) red pixels)")
        }
    }
}
