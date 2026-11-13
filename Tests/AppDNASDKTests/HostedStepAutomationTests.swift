// HostedStepAutomationTests.swift
//
// #1780: the render tests that read a hosted view's accessibility tree saw an EMPTY tree when another
// process on the same simulator turned the simulator-wide accessibility automation switch off in the
// middle of a test. `HostedStep` now re-asserts the switch before every read and waits, bounded, for
// the tree to come back.
//
// The red control turns the switch off the way that other process does, and checks first that this
// really empties the tree (the symptom), then that `HostedStep` still reads it (the fix).
//
// 🔴 Opt-in: the switch is SIMULATOR-WIDE, so flipping it would disturb whatever else runs on a shared
// simulator — which is the defect this file is about. It runs only when the runner sets
// `APPDNA_A11Y_FLIP_CONTROL=1` (pass `TEST_RUNNER_APPDNA_A11Y_FLIP_CONTROL=1` to xcodebuild), on a
// simulator nothing else is using.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class HostedStepAutomationTests: XCTestCase {

    private struct Synthetic: View {
        var body: some View {
            VStack {
                Text("A synthetic heading")
                Button("Continue") {}
            }
        }
    }

    override func tearDown() {
        A11yAutomation.ensure()
        super.tearDown()
    }

    func testTheTreeIsReadAfterAnotherProcessTurnsAutomationOff() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPDNA_A11Y_FLIP_CONTROL"] == "1",
                          "flips the simulator-wide accessibility switch; run on a private simulator only")
        let hosted = HostedStep(Synthetic())
        defer { hosted.close() }
        XCTAssertTrue(hosted.wait { hosted.has(label: "Continue") }, "baseline: the tree is published; \(hosted.labels())")

        // Another process on the simulator turns the switch off.
        A11yAutomation.setForTesting(false)
        hosted.spin(0.5)

        // Control: the symptom reproduces — read raw, the tree is empty of labels.
        let raw = hosted.rawElements().compactMap(\.accessibilityLabel)
        XCTAssertEqual(raw, [], "control: with the switch off the tree publishes no label (the #1780 symptom)")

        // The fix: HostedStep turns it back on and reads the tree.
        XCTAssertTrue(hosted.has(label: "Continue"), "HostedStep reads the tree again; \(hosted.labels())\(hosted.treeDiagnosis())")
        XCTAssertGreaterThan(A11yAutomation.timesFoundOff, 0, "the read saw the switch off and counted it")
    }
}
