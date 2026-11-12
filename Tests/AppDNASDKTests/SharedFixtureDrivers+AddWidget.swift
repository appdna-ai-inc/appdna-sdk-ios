// SharedFixtureDrivers+AddWidget.swift
//
// iOS driver for `add_widget_attempt`: an `add_widget` button on an onboarding step, the how-to sheet,
// detection by widget-id set difference, and the one advance that carries `widget_status`.
//
// REAL: `WidgetAddAttempt` (the production state machine the step router drives), fed through its
// seams — the extension probe answers `setup.widget_env.ios.has_extension`, and the configurations
// source serves `configurations_before` until the `user_adds_widget` stimulus, `configurations_after`
// from then on, or fails every read when `query_fails`.
// REAL: the gate is `RequiredFieldGate.evaluate` over the step's blocks — the gate the router hands
// the attempt — with the step's (empty) inputs.
// REAL: the how-to's Done and Close go through `BlockSheetView.handle`, the sheet's own button routing.
// REAL: the advance builds its payload with `StepAdvancePayload.build` (the router's
// `advanceCollectingStepData` assembly) and routes it through `OnboardingAdvance.apply`, so
// `next_step_rules` read `widget_status` exactly as on a device.
//
// PLUMBING: a swipe is the system dismissing the sheet, so `close:swipe` clears the sheet and calls
// `sheetDidDismiss()` the way SwiftUI's `.sheet(item:onDismiss:)` does; after any other stimulus that
// took the sheet down, the runner calls `sheetDidDismiss()` as SwiftUI would.
//
// Events: the widget_* subsequence of what the real `EventTracker` saw is compared with the fixture.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// The configurations source the fixture describes.
    final class FixtureWidgetSource: WidgetConfigurationsSource {
        var current: Set<WidgetInstance>
        let after: Set<WidgetInstance>
        let fails: Bool
        private(set) var reads = 0

        init(before: Set<WidgetInstance>, after: Set<WidgetInstance>, fails: Bool) {
            self.current = before
            self.after = after
            self.fails = fails
        }

        func userAddsWidget() { current = after }

        func read(_ completion: @escaping (Set<WidgetInstance>?) -> Void) {
            reads += 1
            completion(fails ? nil : current)
        }
    }

    static func widgetInstances(_ json: AnyJSON?) -> Set<WidgetInstance> {
        Set((json?.arrayValue ?? []).compactMap { entry -> WidgetInstance? in
            guard let o = entry.objectValue, let id = o["id"]?.stringValue else { return nil }
            return WidgetInstance(id: id, kind: o["kind"]?.stringValue ?? "", family: o["family"]?.stringValue ?? "")
        })
    }

    @MainActor
    func runAddWidgetAttempt(_ f: Fixture, _ h: Harness) {
        guard let flow = onboardingFlow(f) else {
            return XCTFail("[\(f.id)] setup.config does not decode as an OnboardingFlowConfig with steps")
        }
        let action = f.action.raw
        let stepId = action["step_id"]?.stringValue ?? ""
        guard let currentIndex = flow.steps.firstIndex(where: { $0.id == stepId }) else {
            return XCTFail("[\(f.id)] no step '\(stepId)'")
        }
        let step = flow.steps[currentIndex]
        let blocks = step.config.content_blocks ?? []
        let buttonId = action["button_id"]?.stringValue ?? ""
        guard let button = OnboardingStepPipeline.allStepBlocks(blocks).first(where: { $0.id == buttonId }) else {
            return XCTFail("[\(f.id)] no button '\(buttonId)' on step '\(stepId)'")
        }
        guard let env = f.setup.raw["widget_env"]?.objectValue?["ios"]?.objectValue else {
            return XCTFail("[\(f.id)] setup.widget_env.ios is required for an iOS add_widget_attempt")
        }
        guard let stimuli = action["events"]?.objectValue?["ios"]?.arrayValue?.compactMap(\.stringValue) else {
            return XCTFail("[\(f.id)] action.events.ios is required")
        }

        let source = FixtureWidgetSource(
            before: Self.widgetInstances(env["configurations_before"]),
            after: Self.widgetInstances(env["configurations_after"]),
            fails: env["query_fails"]?.boolValue ?? false
        )
        let hasExtension = env["has_extension"]?.boolValue ?? false
        let attempt = WidgetAddAttempt(platform: .init(hasWidgetExtension: { hasExtension }, configurations: source))

        let inputValues: [String: Any] = [:]
        var status: WidgetStatus?
        var advances = 0
        var gateRefusals = 0
        attempt.configure(presentation: 0, hooks: .init(
            flowId: flow.id,
            stepId: step.id,
            gate: { RequiredFieldGate.evaluate(blocks: blocks, inputValues: inputValues, rawResolvedIds: []).canAdvance },
            onGateRefused: { gateRefusals += 1 },
            track: { name, props in h.tracker.track(event: name, properties: props) },
            advance: { s in
                advances += 1
                status = s
                var responses = self.sessionResponses(f)
                responses[step.id] = StepAdvancePayload.build(
                    inputValues: inputValues, toggleValues: [:], extra: [WidgetStatus.answerKey: s.rawValue]
                ) ?? [:]
                self.applyAdvance(f, h, flow: flow, currentIndex: currentIndex,
                                  responses: responses, result: .proceed, hookRan: false, pressedButtonId: button.id)
            }
        ))

        // The sheet the attempt presented, driven through its own button routing.
        func sheetButton(_ actionName: String) {
            guard let sheet = attempt.sheet else {
                return XCTFail("[\(f.id)] '\(actionName)' with no how-to presented")
            }
            BlockSheetView(blocks: sheet.blocks, loc: nil,
                           onDone: { attempt.doneTapped() }, onClose: { attempt.closeTapped() })
                .handle(actionName)
        }

        for stimulus in stimuli {
            let hadSheet = attempt.sheet != nil
            switch stimulus {
            case "tap": attempt.tap(button)
            case "user_adds_widget": source.userAddsWidget()
            case "active": attempt.appDidBecomeActive()
            case "done_cta": sheetButton("next")
            case "close:dismiss": sheetButton("dismiss")
            case "close:swipe":
                guard hadSheet else { XCTFail("[\(f.id)] close:swipe with no how-to presented"); continue }
                attempt.sheet = nil
                attempt.sheetDidDismiss()
                continue
            case "destroy": attempt.discard()
            default:
                XCTFail("[\(f.id)] unknown iOS add_widget stimulus '\(stimulus)'")
            }
            // SwiftUI's onDismiss, after a close the SDK made itself.
            if hadSheet && attempt.sheet == nil { attempt.sheetDidDismiss() }
        }

        XCTAssertLessThanOrEqual(advances, 1, "[\(f.id)] one advance per attempt at most")
        h.events = h.events.filter { $0.event_name.hasPrefix("widget_") }
        h.state["widget_status"] = status?.rawValue ?? NSNull()
        if advances == 0 {
            h.state["current_step_index"] = currentIndex
            h.state["current_step_id"] = step.id
        }
        h.state["gate_refusals"] = gateRefusals
    }
}
