// PasswordFieldDefaultColorsTests.swift
//
// An `input_password` block with no field style is visible on the step it sits on: dark text on a
// light step, white text on a dark, gradient or image step, whatever the device's appearance. The
// light-or-dark call is the one the Google logo makes, from what the flow host draws behind the
// block (`GoogleMapsAttribution.backdrop(ofStep:type:)` and `backdrop(ofBlock:behind:)`).
//
// The flow host is rendered in a real key window with a forced appearance, a password is typed into
// the step's UIKit text field, and the colour the field draws its text in is read back, resolved in
// the field's own traits. The control in each case is an authored text colour, which the harness
// must read back unchanged.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PasswordFieldDefaultColorsTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private static let white = ##"{"type":"color","color":"#FFFFFF"}"##
    private static let navy = ##"{"type":"color","color":"#0F172A"}"##
    private static let gradient = ##"{"type":"gradient","gradient":{"type":"linear","angle":180,"stops":[{"color":"#1E1B4B","position":0},{"color":"#312E81","position":1}]}}"##

    private func flow(background: String?, fieldStyle: String? = nil) throws -> OnboardingFlowConfig {
        let style = fieldStyle.map { #","field_style":"# + $0 } ?? ""
        let bg = background.map { #","background":"# + $0 } ?? ""
        let step = #"{"id":"s_pw","type":"custom","config":{"content_blocks":[{"id":"b_pw","type":"input_password","field_id":"pw""#
            + style + #"}]"# + bg + "}}"
        let json = #"{"id":"password_colour_probe","name":"Password colour probe","version":1,"steps":["# + step
            + #",{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    /// The text colour the step's password field draws with, resolved in its own traits, after typing.
    private func typedTextColor(_ flow: OnboardingFlowConfig, appearance: UIUserInterfaceStyle) -> UIColor? {
        _ = A11yAutomation.enabled
        let host = UIHostingController(rootView: AnyView(OnboardingFlowHost(
            flow: flow,
            delegate: nil,
            eventTracker: nil,
            onStepViewed: { _, _ in },
            onStepCompleted: { _, _, _ in },
            onStepSkipped: { _, _ in },
            onFlowCompleted: { _ in },
            onFlowDismissed: { _, _ in }
        )))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.overrideUserInterfaceStyle = appearance
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        spin(0.5)

        func find(_ v: UIView) -> UITextField? {
            if let tf = v as? UITextField { return tf }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let tf = find(host.view) else { XCTFail("no text field"); return nil }
        XCTAssertTrue(tf.isSecureTextEntry, "the field found is the password field")
        _ = tf.becomeFirstResponder()
        tf.text = "hunter22"
        tf.sendActions(for: .editingChanged)
        spin(0.3)
        return (tf.textColor ?? .label).resolvedColor(with: tf.traitCollection)
    }

    private func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func luminance(_ c: UIColor?) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Light step

    func testOnAWhiteStepTheTypedTextIsDarkInALightAppearance() throws {
        let color = typedTextColor(try flow(background: Self.white), appearance: .light)
        XCTAssertLessThan(luminance(color), 0.35, "dark text on a white step")
    }

    func testOnAWhiteStepTheTypedTextIsDarkInADarkAppearanceToo() throws {
        let color = typedTextColor(try flow(background: Self.white), appearance: .dark)
        XCTAssertLessThan(luminance(color), 0.35,
                          "a dark appearance must not draw white text on a white step (got luminance \(luminance(color)))")

        // Control: the harness reads an authored text colour back as authored, in the same appearance.
        let authored = typedTextColor(try flow(background: Self.white, fieldStyle: ##"{"text_color":"#FF0000"}"##), appearance: .dark)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        authored?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.02, "control: the authored red is read back")
        XCTAssertEqual(g, 0, accuracy: 0.02)
    }

    // MARK: - Dark and busy steps

    func testOnADarkStepTheTypedTextIsWhiteInALightAppearance() throws {
        let color = typedTextColor(try flow(background: Self.navy), appearance: .light)
        XCTAssertGreaterThan(luminance(color), 0.9,
                             "white text on a navy step (got luminance \(luminance(color)))")
    }

    func testOnAGradientStepTheTypedTextIsWhiteInALightAppearance() throws {
        let color = typedTextColor(try flow(background: Self.gradient), appearance: .light)
        XCTAssertGreaterThan(luminance(color), 0.9,
                             "white text on a gradient step (got luminance \(luminance(color)))")
    }

    // MARK: - The palette, as the Kotlin twin picks it

    func testThePaletteFollowsTheLogoVariantsLightOrDarkCall() {
        XCTAssertEqual(UnstyledPasswordField.palette(behind: .plain(hex: "#FFFFFF"), darkAppearance: true), UnstyledPasswordField.light)
        XCTAssertEqual(UnstyledPasswordField.palette(behind: .plain(hex: "#0F172A"), darkAppearance: false), UnstyledPasswordField.dark)
        XCTAssertEqual(UnstyledPasswordField.palette(behind: .busy, darkAppearance: false), UnstyledPasswordField.dark)
        XCTAssertEqual(UnstyledPasswordField.palette(behind: .plain(hex: nil), darkAppearance: false), UnstyledPasswordField.light)
        XCTAssertEqual(UnstyledPasswordField.palette(behind: .plain(hex: nil), darkAppearance: true), UnstyledPasswordField.dark)
    }
}
