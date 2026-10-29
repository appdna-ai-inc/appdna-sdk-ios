// UnstyledInkChromeAndInputsTests.swift
//
// The rest of an onboarding step's unstyled ink follows the step behind it, as text and labels do:
// the typed text, placeholder and cursor of an unstyled text input, and the step chrome (the close ✕
// and the Skip link). Dark on a light step, whatever the device's appearance; light on a dark,
// gradient or image step. Authored colours win. The Kotlin twin is `UnstyledInkChromeAndInputsTest`.
//
// The flow host is rendered in a real key window with a forced appearance. The input's colours are
// read back from its UIKit field, resolved in the field's own traits. The chrome is measured in pixels
// (`layer.render(in:)`) inside each control's accessibility frame. The controls are a white step in a
// light appearance and an authored text colour.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class UnstyledInkChromeAndInputsTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private static let white = ##"{"type":"color","color":"#FFFFFF"}"##
    private static let navy = ##"{"type":"color","color":"#0F172A"}"##
    private static let gradient = ##"{"type":"gradient","gradient":{"type":"linear","angle":180,"stops":[{"color":"#1E1B4B","position":0},{"color":"#312E81","position":1}]}}"##

    private func flow(_ step: String) throws -> OnboardingFlowConfig {
        let json = #"{"id":"ink_probe","name":"Ink probe","version":1,"settings":{"dismiss_allowed":true},"steps":["# + step
            + #",{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    private func inputStep(_ background: String, authored: Bool = false) -> String {
        let style = authored ? ##","field_style":{"text_color":"#FF0000"}"## : ""
        return #"{"id":"s_in","type":"custom","config":{"background":"# + background
            + #","content_blocks":[{"id":"b_in","type":"input_text","zone":"bottom","field_id":"name","field_placeholder":"Type here""# + style + "}]}}"
    }

    private func skipStep(_ background: String) -> String {
        #"{"id":"s_w","type":"welcome","config":{"title":"Hello","skip_enabled":true,"background":"# + background + "}}"
    }

    private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        init(_ flow: OnboardingFlowConfig, appearance: UIUserInterfaceStyle) {
            _ = A11yAutomation.enabled
            host = UIHostingController(rootView: AnyView(OnboardingFlowHost(
                flow: flow, delegate: nil, eventTracker: nil,
                onStepViewed: { _, _ in }, onStepCompleted: { _, _, _ in }, onStepSkipped: { _, _ in },
                onFlowCompleted: { _ in }, onFlowDismissed: { _, _ in }
            )))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.overrideUserInterfaceStyle = appearance
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }
        func close() { window.isHidden = true }

        func field() -> UITextField? {
            func find(_ v: UIView) -> UITextField? {
                if let tf = v as? UITextField { return tf }
                for s in v.subviews { if let f = find(s) { return f } }
                return nil
            }
            return find(host.view)
        }

        /// Accessibility elements as (label, frame, isButton).
        func elements() -> [(String, CGRect, Bool)] {
            var out: [(String, CGRect, Bool)] = []
            func walk(_ o: NSObject, _ depth: Int) {
                guard depth < 60 else { return }
                if let l = o.accessibilityLabel { out.append((l, o.accessibilityFrame, o.accessibilityTraits.contains(.button))) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } } }
                for e in o.accessibilityElements ?? [] { if let e = e as? NSObject { walk(e, depth + 1) } }
                if let v = o as? UIView { for s in v.subviews { walk(s, depth + 1) } }
            }
            walk(host.view, 0)
            return out
        }

        /// Light and dark pixel counts inside `frame`.
        func ink(in frame: CGRect) throws -> (light: Int, dark: Int) {
            let size = window.bounds.size
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
            var light = 0, dark = 0
            let x0 = max(0, Int(frame.minX * scale)), x1 = min(cg.width, Int(frame.maxX * scale))
            let y0 = max(0, Int(frame.minY * scale)), y1 = min(cg.height, Int(frame.maxY * scale))
            guard x0 < x1, y0 < y1 else { return (0, 0) }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * cg.width * 4 + x * 4
                    let lum = (0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])) / 255
                    if lum > 0.6 { light += 1 }
                    if lum < 0.6 { dark += 1 }
                }
            }
            return (light, dark)
        }
    }

    private func luminance(_ c: UIColor?) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// The typed text's colour and the cursor's, resolved in the field's traits, after typing.
    private func typedColours(_ background: String, appearance: UIUserInterfaceStyle, authored: Bool = false) throws -> (text: UIColor?, tint: UIColor?) {
        let hosted = Hosted(try flow(inputStep(background, authored: authored)), appearance: appearance)
        defer { hosted.close() }
        guard let tf = hosted.field() else { XCTFail("no text field"); return (nil, nil) }
        _ = tf.becomeFirstResponder()
        tf.text = "WWWWWW"
        for target in tf.allTargets {
            for action in tf.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                _ = (target as NSObject).perform(Selector(action), with: tf)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return ((tf.textColor ?? .label).resolvedColor(with: tf.traitCollection), tf.tintColor.resolvedColor(with: tf.traitCollection))
    }

    // MARK: - Typed text and cursor

    func testTypedTextIsLightOnADarkStep() throws {
        let c = try typedColours(Self.navy, appearance: .light)
        XCTAssertGreaterThan(luminance(c.text), 0.9, "typed text on navy (luminance \(luminance(c.text)))")
        XCTAssertGreaterThan(luminance(c.tint), 0.9, "the cursor on navy (luminance \(luminance(c.tint)))")
    }

    func testTypedTextIsLightOnAGradientStep() throws {
        XCTAssertGreaterThan(luminance(try typedColours(Self.gradient, appearance: .light).text), 0.9)
    }

    func testTypedTextStaysDarkOnAWhiteStepInADarkAppearance() throws {
        let c = try typedColours(Self.white, appearance: .dark)
        XCTAssertLessThan(luminance(c.text), 0.35, "typed text on white in a dark appearance (luminance \(luminance(c.text)))")
    }

    func testTypedTextIsDarkOnAWhiteStepInALightAppearanceAsBefore() throws {
        XCTAssertLessThan(luminance(try typedColours(Self.white, appearance: .light).text), 0.35)
    }

    func testAnAuthoredTextColourStillWins() throws {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try typedColours(Self.navy, appearance: .light, authored: true).text?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.02)
        XCTAssertEqual(g, 0, accuracy: 0.02)
    }

    // MARK: - Chrome

    /// The close ✕: the button in the top-right corner of the nav bar.
    private func closeInk(_ background: String, appearance: UIUserInterfaceStyle) throws -> (light: Int, dark: Int) {
        let hosted = Hosted(try flow(inputStep(background)), appearance: appearance)
        defer { hosted.close() }
        let close = hosted.elements().first { $0.2 && $0.1.minY < 140 && $0.1.midX > 300 }
        let frame = try XCTUnwrap(close?.1, "control: the harness finds the close button; elements: \(hosted.elements().map(\.0))")
        return try hosted.ink(in: frame)
    }

    private func skipInk(_ background: String, appearance: UIUserInterfaceStyle) throws -> (light: Int, dark: Int) {
        let hosted = Hosted(try flow(skipStep(background)), appearance: appearance)
        defer { hosted.close() }
        let skip = hosted.elements().first { $0.0 == "Skip" }
        let frame = try XCTUnwrap(skip?.1, "control: the harness finds Skip; elements: \(hosted.elements().map(\.0))")
        return try hosted.ink(in: frame)
    }

    func testTheCloseGlyphIsLightOnADarkStep() throws {
        let ink = try closeInk(Self.navy, appearance: .light)
        XCTAssertGreaterThan(ink.light, 20, "the ✕ on navy (\(ink.light) light pixels)")
    }

    func testTheCloseGlyphIsDarkOnAWhiteStepAsBefore() throws {
        let ink = try closeInk(Self.white, appearance: .light)
        XCTAssertGreaterThan(ink.dark, 20, "the ✕ on white (\(ink.dark) dark pixels)")
    }

    func testSkipIsLightOnADarkStep() throws {
        let ink = try skipInk(Self.navy, appearance: .light)
        XCTAssertGreaterThan(ink.light, 20, "Skip on navy (\(ink.light) light pixels)")
    }

    func testSkipIsDarkOnAWhiteStepAsBefore() throws {
        let ink = try skipInk(Self.white, appearance: .light)
        XCTAssertGreaterThan(ink.dark, 20, "Skip on white (\(ink.dark) dark pixels)")
    }
}
