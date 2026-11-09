import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/// "Advance by itself after", through the real decoder and the real flow host in a key window. The
/// shared fixture pins the policy; this pins that the host consults it, in the shapes a console save
/// publishes: the timer at the step root, inside `layout` only, and beside tap-anywhere.
@MainActor
final class StepAutoAdvanceHostTests: XCTestCase {
    private func step(_ fields: String) -> String {
        #"{"id":"s","type":"splash","content_blocks":[{"id":"h1","type":"heading","text":"Splash screen"}],\#(fields)}"#
    }

    private func flow(_ first: String) throws -> OnboardingFlowConfig {
        let json = #"{"id":"f","name":"f","version":1,"steps":[\#(first),{"id":"next","type":"content","content_blocks":[{"id":"h2","type":"heading","text":"Second screen"}]}],"settings":{}}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    private func assertAdvances(_ first: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var seen: [String] = []
        let hosted = HostedStep(AnyView(OnboardingFlowHost(
            flow: try flow(first), delegate: nil, eventTracker: nil,
            onStepViewed: { id, _ in seen.append(id) },
            onStepCompleted: { _, _, _ in }, onStepSkipped: { _, _ in },
            onFlowCompleted: { _ in }, onFlowDismissed: { _, _ in }
        )))
        defer { hosted.close() }
        XCTAssertTrue(hosted.wait(8) { seen.contains("next") }, "the next step must be viewed with no input; saw \(seen)", file: file, line: line)
        XCTAssertEqual(seen.first, "s", file: file, line: line)
    }

    func testATimerAtTheStepRootAdvances() throws {
        try assertAdvances(step(#""auto_advance_seconds":1"#))
    }

    func testATimerOnlyInLayoutAdvances() throws {
        try assertAdvances(step(#""layout":{"auto_advance_seconds":1}"#))
    }

    func testATimerBesideTapAnywhereAdvances() throws {
        try assertAdvances(step(#""auto_advance_seconds":1,"layout":{"tap_anywhere_advances":true,"auto_advance_seconds":1}"#))
    }
}
