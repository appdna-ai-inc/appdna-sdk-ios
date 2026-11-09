// SurfaceInkLegacyStepTests.swift
//
// A legacy (no `content_blocks`) step's secondary text takes its ink from the step behind it, not the phone's appearance.

import XCTest
@testable import AppDNASDK

@MainActor
final class SurfaceInkLegacyStepTests: SurfaceInkTestCase {
    private func legacyFlow(background: String) throws -> OnboardingFlowConfig {
        let json = #"{"id":"ink_probe","name":"Ink probe","version":1,"steps":[{"id":"s_w","type":"welcome","config":{"title":"Hello","subtitle":"Legacy subtitle","background":"#
            + background + #"}},{"id":"s_end","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    func testAWhiteLegacyStepInADarkAppearanceIsDark() throws {
        let counts = try render(legacyFlow(background: Self.white), elements: ["Legacy subtitle"], appearance: .dark)
        for (name, c) in counts { XCTAssertGreaterThan(c.dark, ink, "\(name) on white in dark mode: \(c)") }
    }

    func testADarkLegacyStepInALightAppearanceIsLight() throws {
        let counts = try render(legacyFlow(background: Self.navy), elements: ["Legacy subtitle"], appearance: .light)
        for (name, c) in counts { XCTAssertGreaterThan(c.light, ink, "\(name) on navy in light mode: \(c)") }
    }
}
