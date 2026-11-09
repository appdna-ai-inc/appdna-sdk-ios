// SurfaceInkLegacyStepTests.swift
//
// A legacy (no `content_blocks`) step's secondary text takes its ink from the step behind it, not the phone's appearance.

import XCTest
@testable import AppDNASDK

@MainActor
final class SurfaceInkLegacyStepTests: SurfaceInkTestCase {
    override func setUp() { super.setUp(); settle = 3 }

    private func legacyFlow(background: String) throws -> OnboardingFlowConfig {
        let json = #"{"id":"ink_probe","name":"Ink probe","version":1,"steps":[{"id":"s_w","type":"welcome","config":{"title":"Hello","subtitle":"Legacy subtitle","background":"#
            + background + #"}},{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    func testAWhiteLegacyStepInADarkAppearanceIsDark() throws {
        let counts = try render(legacyFlow(background: Self.white), elements: ["Legacy subtitle"], appearance: .dark)
        for (name, c) in counts { XCTAssertGreaterThan(c.inkOnWhite, ink, "\(name) on white in dark mode: \(c)") }
    }

    func testADarkLegacyStepInALightAppearanceIsLight() throws {
        let counts = try render(legacyFlow(background: Self.navy), elements: ["Legacy subtitle"], appearance: .light)
        for (name, c) in counts { XCTAssertGreaterThan(c.inkOnDark, ink, "\(name) on navy in light mode: \(c)") }
    }

    /// A system control: legacy form steps still use a segmented `Picker`, UIKit-backed. Its pixels do not reach this
    /// render path, so read the trait the control itself resolves against.
    private func segmentStyle(background: String, appearance: UIUserInterfaceStyle) throws -> UIUserInterfaceStyle? {
        let json = #"{"id":"ink_probe","name":"Ink probe","version":1,"steps":[{"id":"s_f","type":"form","config":{"background":"#
            + background + #","fields":[{"id":"f1","type":"segmented","label":"Pick","options":[{"id":"a","label":"Option alpha"},{"id":"b","label":"Option beta"}]}]}},{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        let flow = try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
        _ = try render(flow, elements: ["Option beta"], appearance: appearance)
        return findSegment(in: lastWindow)?.traitCollection.userInterfaceStyle
    }

    private func findSegment(in view: UIView?) -> UISegmentedControl? {
        guard let view else { return nil }
        if let s = view as? UISegmentedControl { return s }
        for sub in view.subviews { if let s = findSegment(in: sub) { return s } }
        return nil
    }

    func testASystemControlResolvesAgainstTheStepNotThePhone() throws {
        XCTAssertEqual(try segmentStyle(background: Self.white, appearance: .dark), .light, "a white step in a dark phone")
        XCTAssertEqual(try segmentStyle(background: Self.navy, appearance: .light), .dark, "a dark step in a light phone")
    }
}
