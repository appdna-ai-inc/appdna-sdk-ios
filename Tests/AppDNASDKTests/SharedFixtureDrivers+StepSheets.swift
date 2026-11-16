// SharedFixtureDrivers+StepSheets.swift
//
// iOS driver for `step_sheet_scenario` : a sheet inside an onboarding step.
//
// REAL: `StepSheetController` (the production state machine the step router drives), `StepSheets.seedDefaults`
// (the router's init), `StepSheets.gateBlocks` + `RequiredFieldGate.evaluate` (the router's `canAdvance`).
// REAL: the advance builds its payload with `StepAdvancePayload.build` and routes through
// `OnboardingAdvance.apply`, so the step's `next_step_rules` read a sheet consent exactly as on a device.
// PLUMBING: the step's dispatcher arms for `open_sheet` / `close_sheet` / `next` are the router's
// `handleBlockAction` cases; the sheet's buttons go through `onSheetAction` first, as
// `StepSheetOverlayView.onAction` does; a tick writes the step's map, as the agreement row's binding does.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    @MainActor
    func runStepSheetScenario(_ f: Fixture, _ h: Harness) {
        guard let flow = onboardingFlow(f) else {
            return XCTFail("[\(f.id)] setup.config does not decode as an OnboardingFlowConfig with steps")
        }
        let action = f.action.raw
        let stepId = action["step_id"]?.stringValue ?? ""
        guard let currentIndex = flow.steps.firstIndex(where: { $0.id == stepId }) else {
            return XCTFail("[\(f.id)] no step '\(stepId)'")
        }
        let step = flow.steps[currentIndex]
        let stepBlocks = step.config.content_blocks ?? []
        let sheets = step.config.sheets ?? []
        guard let script = action["sheet_script"]?.arrayValue?.compactMap(\.stringValue) else {
            return XCTFail("[\(f.id)] action.sheet_script is required")
        }

        h.state["current_step_id"] = step.id
        h.state["sheet_ids"] = sheets.map(\.id)
        for s in sheets {
            h.state["sheet.\(s.id)"] = [
                "height": s.height, "dismissible": s.dismissible, "scrim_color": s.scrim_color,
                "background_color": Self.orNull(s.background_color), "corner_radius": s.corner_radius,
                "drag_indicator": s.drag_indicator, "open_on_gate": s.open_on_gate, "block_count": s.content_blocks.count,
            ] as [String: Any]
        }
        for b in stepBlocks where b.action == StepSheets.openAction {
            h.state["button.\(b.id).sheet_id"] = Self.orNull(b.sheet_id)
        }

        var inputValues: [String: Any] = [:]
        StepSheets.seedDefaults(sheets, into: &inputValues)
        var toast: String?
        var refusedGestures = 0

        var dispatch: ((String, String?) -> Void)!
        let controller = StepSheetController(sheets: sheets, flowId: flow.id, stepId: step.id, effects: .init(
            track: { name, props in h.tracker.track(event: name, properties: props) },
            present: { _ in },
            rerun: { a, v in dispatch(a, v) },
            skip: { h.state["skipped"] = true }
        ))
        dispatch = { a, v in
            switch a {
            case StepSheets.openAction: controller.open(v, via: "button")
            case StepSheets.closeAction: _ = controller.onSheetAction(a, value: v)
            case "next", "continue":
                let verdict = RequiredFieldGate.evaluate(blocks: StepSheets.gateBlocks(stepBlocks, sheets), inputValues: inputValues, rawResolvedIds: [])
                if !verdict.canAdvance {
                    let outcome = controller.onGateRefused(action: a, value: v, stepBlocks: stepBlocks) { list in
                        RequiredFieldGate.evaluate(blocks: list, inputValues: inputValues, rawResolvedIds: []).canAdvance
                    }
                    if outcome == .showToast { toast = "Please fill in \(verdict.firstMissing ?? "required fields")" }
                } else {
                    var responses = self.sessionResponses(f)
                    responses[step.id] = StepAdvancePayload.build(inputValues: inputValues, toggleValues: [:], extra: [:]) ?? [:]
                    self.applyAdvance(f, h, flow: flow, currentIndex: currentIndex, responses: responses, result: .proceed, hookRan: false, pressedButtonId: nil)
                }
            default:
                XCTFail("[\(f.id)] step_sheet_scenario: no step arm for '\(a)'")
            }
        }
        func snapshot() -> [String: Any] {
            var out = inputValues
            out["open_sheet_id"] = Self.orNull(controller.openSheet?.id)
            out["current_step_id"] = h.state["current_step_id"] ?? NSNull()
            out["toast"] = Self.orNull(toast)
            out["refused_gestures"] = refusedGestures
            return out
        }

        for cmd in script {
            let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { XCTFail("[\(f.id)] bad command '\(cmd)'"); continue }
            let (verb, arg) = (parts[0], parts[1])
            switch verb {
            case "tap":
                guard let b = stepBlocks.first(where: { $0.id == arg }) else { XCTFail("[\(f.id)] no button '\(arg)' on the step"); continue }
                // The value ContentBlockRendererView's button forwards.
                let a = b.action ?? "next"
                dispatch(a, a == StepSheets.openAction ? b.sheet_id : b.action_value)
            case "sheet_tap":
                guard let open = controller.openSheet else { XCTFail("[\(f.id)] sheet_tap:\(arg) with no sheet open"); continue }
                guard let b = open.content_blocks.first(where: { $0.id == arg }) else { XCTFail("[\(f.id)] no button '\(arg)' in sheet"); continue }
                let a = b.action ?? "next"
                let v = a == StepSheets.openAction ? b.sheet_id : b.action_value
                if controller.onSheetAction(a, value: v) == .passToStep { dispatch(a, v) }
            case "tick":
                guard controller.openSheet != nil else { XCTFail("[\(f.id)] tick:\(arg) with no sheet open"); continue }
                inputValues[arg] = true
            case "dismiss":
                if !controller.onDismissGesture(via: arg) { refusedGestures += 1 }
            case "snapshot":
                h.state["snapshot.\(arg)"] = snapshot()
            default:
                XCTFail("[\(f.id)] unknown step_sheet_scenario command '\(cmd)'")
            }
        }
        h.state["open_sheet_id"] = Self.orNull(controller.openSheet?.id)
        h.state["toast"] = Self.orNull(toast)
        h.state["step_answers"] = inputValues
        h.events = h.events.filter { $0.event_name.hasPrefix("onboarding_sheet_") }
    }
}
