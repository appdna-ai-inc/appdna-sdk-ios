// QuestionReselectTests.swift
//
// A question step the user already answered shows the answer again when they come back to it with
// Back: the chosen option (or options) is selected and Continue is enabled.
//
// The step is built the way the flow host builds it on Back — the step router, handed the step's
// stored answer — and rendered in a real key window. Continue is activated through the
// accessibility tree. (The option cards sit in the step's scroll view, which a package test does not
// publish to the tree, so the selection is read through what Continue hands on.)
//
// © 2026 AppDNA AI, Inc.

import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

@MainActor
final class QuestionReselectTests: XCTestCase {

    override func tearDown() {
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    /// The step as the flow host builds it when the user comes back to it: its stored answer is
    /// handed in as `savedResponses` (`responses[step.id]`).
    private func router(mode: String, saved: [String: Any]?, onNext: @escaping ([String: Any]?) -> Void) throws -> OnboardingStepRouter {
        let json = #"{"id":"q","type":"question","config":{"title":"Question","selection_mode":""# + mode
            + #"","options":[{"id":"red","label":"Red"},{"id":"green","label":"Green"},{"id":"blue","label":"Blue"}]}}"#
        let step = try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
        return OnboardingStepRouter(step: step, onNext: onNext, onSkip: {}, savedResponses: saved)
    }

    private func continueButton(_ step: HostedStep) -> NSObject? {
        step.elements().first { $0.accessibilityLabel == "Continue" && $0.accessibilityTraits.contains(.button) }
    }

    /// Continue hands on the step's selection only when the view holds one: it is disabled with
    /// nothing selected. So what Continue hands on is what the view shows as selected.
    private func continuePayload(mode: String, saved: [String: Any]?) throws -> (enabled: Bool, payload: [String: Any]?) {
        var payloads: [[String: Any]?] = []
        let step = HostedStep(try router(mode: mode, saved: saved, onNext: { payloads.append($0) }))
        defer { step.close() }
        guard let button = continueButton(step) else {
            XCTFail("control: the harness sees Continue; labels: \(step.labels())")
            return (false, nil)
        }
        let enabled = !button.accessibilityTraits.contains(.notEnabled)
        _ = button.accessibilityActivate()
        step.spin(0.3)
        return (enabled, payloads.first ?? nil)
    }

    func testASingleSelectAnswerIsSelectedAgainWhenTheUserComesBack() throws {
        let r = try continuePayload(mode: "single", saved: ["selected": ["green"], "selection_mode": "single"])
        XCTAssertTrue(r.enabled, "Continue is enabled, as when the user left")
        XCTAssertEqual(r.payload?["selected"] as? [String], ["green"], "the stored pick is the step's selection again")
    }

    func testAMultiSelectAnswerIsSelectedAgainWhenTheUserComesBack() throws {
        let r = try continuePayload(mode: "multi", saved: ["selected": ["red", "blue"], "selection_mode": "multi"])
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(Set(r.payload?["selected"] as? [String] ?? []), ["red", "blue"])
    }

    func testAQuestionNeverAnsweredStartsWithNothingSelected() throws {
        let r = try continuePayload(mode: "single", saved: nil)
        XCTAssertFalse(r.enabled, "control: with nothing selected Continue is disabled")
        XCTAssertNil(r.payload)
    }

    func testRestoredSelectionKeepsOnlyOfferedIdsAndOneForSingleSelect() throws {
        let single = try JSONDecoder().decode(StepConfig.self, from: Data(#"{"selection_mode":"single","options":[{"id":"a"},{"id":"b"}]}"#.utf8))
        let multi = try JSONDecoder().decode(StepConfig.self, from: Data(#"{"selection_mode":"multi","options":[{"id":"a"},{"id":"b"}]}"#.utf8))
        XCTAssertEqual(QuestionStepView.restoredSelection(["selected": ["b", "a"]], config: single), ["b"])
        XCTAssertEqual(QuestionStepView.restoredSelection(["selected": ["b", "gone", "a", "b"]], config: multi), ["b", "a"])
        XCTAssertEqual(QuestionStepView.restoredSelection(["selected": "a"], config: single), ["a"])
        XCTAssertEqual(QuestionStepView.restoredSelection(nil, config: multi), [])
    }
}
