// SharedFixtureDrivers+GoogleAttribution.swift
//
// iOS drivers for Google's attribution. Dispatched from `driveSpec497Maps`. Every value asserted is
// produced by REAL SDK code:
//
//   location_field_attribution  REAL: `LocationAnswer.carriesPlaceId`, the one rule both location
//                               views read to keep Google's logo beside a field.
//   onboarding_google_credit    REAL: the step decoded by the SDK's own `OnboardingStep` decoder (raw
//                               blocks captured and stamped as for a published flow), then
//                               `GoogleCredit.shows(step:override:…)` — the call `OnboardingStepRouter`
//                               makes in its body — and, for an option sheet,
//                               `GoogleCreditSheetContext.shows`, the call the sheet makes, handed
//                               the option's sheet blocks as the REAL pipeline resolved them.
//
// The dropdown's logo and the field's attribution through a tap are asserted by the
// `location_resolve_request` kind (`list_google_logo` / `field_google_attribution` observables).
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    // MARK: location_field_attribution

    func runLocationFieldAttribution(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue, !cases.isEmpty else {
            return XCTFail("[\(f.id)] location_field_attribution needs action.cases")
        }
        var results: [[String: Any]] = []
        for c in cases {
            guard let obj = c.objectValue, let name = obj["name"]?.stringValue, let answerJSON = obj["stored_answer"] else {
                return XCTFail("[\(f.id)] a case needs name + stored_answer")
            }
            let answer: Any? = answerJSON.foundation is NSNull ? nil : answerJSON.foundation
            results.append(["name": name, "google_attribution": LocationAnswer.carriesPlaceId(answer)])
        }
        h.state["results"] = results
    }

    // MARK: onboarding_google_credit

    /// setup.config.step = one onboarding step as published; setup.session_data = {responses (the
    /// flow's accumulated answers), session_store (SessionDataStore.onboardingResponses), step (the
    /// step's inputs)}. action: override {title, subtitle, cta_text, field_defaults, field_options},
    /// field_config_overrides, field_options_overrides (the interaction patches), sheet {block_id,
    /// option_id, inputs}.
    func runOnboardingGoogleCredit(_ f: Fixture, _ h: Harness) {
        guard let stepJSON = f.setup.config?.objectValue?["step"]?.foundation,
              let data = try? JSONSerialization.data(withJSONObject: stepJSON) else {
            return XCTFail("[\(f.id)] onboarding_google_credit needs setup.config.step")
        }
        let step: OnboardingStep
        do {
            step = try JSONDecoder().decode(OnboardingStep.self, from: data)
        } catch {
            return XCTFail("[\(f.id)] the SDK's decoder refused setup.config.step: \(error)")
        }

        let session = f.setup.session_data?.objectValue ?? [:]
        let accumulated = (session["responses"]?.foundation as? [String: Any]) ?? [:]
        let stepInputs = (session["step"]?.foundation as? [String: Any]) ?? [:]
        var store: [String: [String: Any]] = [:]
        for (stepId, answers) in (session["session_store"]?.foundation as? [String: Any]) ?? [:] {
            if let d = answers as? [String: Any] { store[stepId] = d }
        }
        let answers = GoogleCredit.Answers(accumulated: accumulated, stepInputs: stepInputs, sessionStore: store)

        let override = Self.creditOverride(f.action.raw["override"])
        let fieldConfigOverrides = (f.action.raw["field_config_overrides"]?.foundation as? [String: [String: Any]]) ?? [:]
        var fieldOptionsOverrides: [String: [InputOption]] = [:]
        for (blockId, options) in f.action.raw["field_options_overrides"]?.objectValue ?? [:] {
            fieldOptionsOverrides[blockId] = Self.decodeOptions(options)
        }

        h.state["shows_credit"] = GoogleCredit.shows(
            step: step, override: override,
            fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides,
            answers: answers
        )

        if let sheet = f.action.raw["sheet"]?.objectValue {
            let blockId = sheet["block_id"]?.stringValue
            let optionId = sheet["option_id"]?.stringValue
            let inputs = (sheet["inputs"]?.foundation as? [String: Any]) ?? [:]
            let context = GoogleCreditSheetContext(
                sources: {
                    GoogleCredit.stepSources(
                        step: step, override: override,
                        fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides
                    )
                },
                answers: answers
            )
            // The presented option, as the sheet receives it in production: from the step the REAL
            // pipeline resolved (raw pass → decode → override → interaction layering), so its sheet
            // blocks have every non-`step` token substituted and a `repeat` has generated its options.
            let resolved = OnboardingStepPipeline.resolve(OnboardingStepPipeline.Input(
                step: step, override: override, pending: false, inputValues: stepInputs,
                responses: accumulated, templateContext: fixtureTemplateContext(f), selected: [:],
                fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides
            ))
            guard let option = resolved.blocks.first(where: { $0.id == blockId })?.field_options?
                .first(where: { $0.id == optionId }) else {
                return XCTFail("[\(f.id)] the resolved step has no option \(optionId ?? "nil") on \(blockId ?? "nil")")
            }
            let presented = option.sheet_blocks ?? []
            h.state["presented_sheet_text"] = presented.compactMap(\.text)
            h.state["sheet_credit"] = context.shows(
                blockId: blockId, optionId: optionId, presentedSheetBlocks: presented, sheetInputs: inputs
            )
        }
    }

    private static func creditOverride(_ json: AnyJSON?) -> StepConfigOverride? {
        guard let o = json?.objectValue else { return nil }
        var fieldOptions: [String: [InputOption]]?
        if let byBlock = o["field_options"]?.objectValue {
            fieldOptions = byBlock.mapValues { decodeOptions($0) }
        }
        return StepConfigOverride(
            fieldDefaults: o["field_defaults"]?.foundation as? [String: Any],
            title: o["title"]?.stringValue,
            subtitle: o["subtitle"]?.stringValue,
            ctaText: o["cta_text"]?.stringValue,
            fieldOptions: fieldOptions
        )
    }

    private static func decodeOptions(_ json: AnyJSON) -> [InputOption] {
        guard let raw = json.foundation as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let options = try? JSONDecoder().decode([InputOption].self, from: data) else { return [] }
        return options
    }
}
