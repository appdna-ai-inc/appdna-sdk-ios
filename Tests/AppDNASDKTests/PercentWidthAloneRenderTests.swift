// PercentWidthAloneRenderTests.swift
//
// A block with a percentage `element_width` is that fraction of the width it is OFFERED, even when it is the
// only block in its zone. The renderer used to measure its own stack, which is as wide as its widest block, so a
// 60% button alone in the pinned zone was 60% of itself: each pass measured it narrower until it was not drawn.
// The real OnboardingFlowHost, in a real key window; the button is read through the accessibility tree. The
// control is the same button beside a full-width heading, which always measured the full zone.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class PercentWidthAloneRenderTests: XCTestCase {
    final class Counter { var count = 0 }

    private func flow(_ blocks: String) throws -> OnboardingFlowConfig {
        let json = #"{"id":"pct_probe","name":"Percent probe","version":1,"settings":{"placement_rules":2},"steps":[{"id":"s1","type":"custom","config":{"content_blocks":["#
            + blocks + #"]}},{"id":"s2","type":"welcome","config":{"title":"End"}}]}"#
        return try JSONDecoder().decode(OnboardingFlowConfig.self, from: Data(json.utf8))
    }

    /// The width of the button labelled `label`, once two reads 100 ms apart agree (at most 3 s).
    /// With `tap`, the button is then activated as VoiceOver activates it, and `completed` counts the steps it completed.
    private func buttonWidth(_ flow: OnboardingFlowConfig, _ label: String, tap: Bool = false, completed: Counter? = nil) -> CGFloat? {
        _ = A11yAutomation.enabled
        let host = UIHostingController(rootView: OnboardingFlowHost(
            flow: flow, delegate: nil, eventTracker: nil, onStepViewed: { _, _ in },
            onStepCompleted: { _, _, _ in completed?.count += 1 }, onStepSkipped: { _, _ in },
            onFlowCompleted: { _ in }, onFlowDismissed: { _, _ in }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        var last: CGFloat?
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let e = A11yTree.read([host.view]).first { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) }
            let w = e.map { window.convert($0.accessibilityFrame, from: nil).width }
            if let w, let l = last, abs(w - l) < 0.5 {
                if tap, let e { _ = e.accessibilityActivate(); RunLoop.current.run(until: Date().addingTimeInterval(0.6)) }
                return w
            }
            last = w
        }
        return last
    }

    private let button = #"{"id":"go","type":"button","text":"Go on","action":"next","zone":"bottom","element_width":"60%"}"#
    private let heading = #"{"id":"h","type":"heading","text":"A heading long enough to span the whole pinned zone of the step","zone":"bottom"}"#

    func testASixtyPercentButtonAloneInThePinnedZoneIsSixtyPercentOfIt() throws {
        let beside = try XCTUnwrap(buttonWidth(try flow("\(heading),\(button)"), "Go on"), "control: the button beside a heading was read")
        XCTAssertGreaterThan(beside, 150, "control: beside a full-width heading the button is 60% of the zone (\(beside))")
        let completed = Counter()
        let alone = buttonWidth(try flow(button), "Go on", tap: true, completed: completed) ?? 0
        XCTAssertEqual(completed.count, 1, "the button alone in the pinned zone is drawn AND works: a tap completes the step")
        XCTAssertEqual(alone, beside, accuracy: 1, "alone in the pinned zone the button is the same 60% of the zone as beside a heading, not a fraction of itself (alone \(alone), beside \(beside))")
    }
}
