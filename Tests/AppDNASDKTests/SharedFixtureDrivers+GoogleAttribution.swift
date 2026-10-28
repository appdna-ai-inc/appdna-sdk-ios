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

    // MARK: google_attribution_backdrop

    /// `action.cases[] = {name, step, block_id?}` → `[{name, backdrop, variant_light}]`: the step decoded
    /// by the SDK's own decoder, then `GoogleMapsAttribution.backdrop(ofStep:type:)` — what the step
    /// container hands down — and, for a block, `backdrop(ofBlock:behind:)` applied at every block from
    /// the step down to it, as each block's view applies it.
    func runGoogleAttributionBackdrop(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue, !cases.isEmpty else {
            return XCTFail("[\(f.id)] google_attribution_backdrop needs action.cases")
        }
        typealias A = GoogleMapsAttribution
        func chain(to id: String, in blocks: [ContentBlock]) -> [ContentBlock]? {
            for b in blocks {
                if b.id == id { return [b] }
                if let rest = chain(to: id, in: (b.children ?? []) + (b.stack_children ?? [])) { return [b] + rest }
            }
            return nil
        }
        var results: [[String: Any]] = []
        for c in cases {
            guard let o = c.objectValue, let name = o["name"]?.stringValue, let json = o["step"]?.foundation,
                  let data = try? JSONSerialization.data(withJSONObject: json) else {
                return XCTFail("[\(f.id)] a case needs name + step")
            }
            let step: OnboardingStep
            do { step = try JSONDecoder().decode(OnboardingStep.self, from: data) } catch {
                return XCTFail("[\(f.id)] \(name): the SDK's decoder refused the step: \(error)")
            }
            var backdrop = A.backdrop(ofStep: step.config, type: step.type)
            if let blockId = o["block_id"]?.stringValue {
                guard let path = chain(to: blockId, in: step.config.content_blocks ?? []) else {
                    return XCTFail("[\(f.id)] \(name): no block \(blockId)")
                }
                for b in path { backdrop = A.backdrop(ofBlock: b, behind: backdrop) }
            }
            let described: String
            switch backdrop {
            case .plain(let hex): described = hex.map { "plain:\($0)" } ?? "plain"
            case .busy: described = "busy"
            }
            let variant: String
            switch A.variant(on: backdrop, darkAppearance: false) {
            case .gray: variant = "gray"
            case .white: variant = "white"
            case .lightOutline: variant = "light_outline"
            case .darkOutline: variant = "dark_outline"
            }
            results.append(["name": name, "backdrop": described, "variant_light": variant])
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
        // `action.select = {step, block_id, option_id}`: an EARLIER step, resolved through the REAL
        // pipeline with the same answers, and the option the user picked there, recorded by the REAL
        // `SelectedOptionStore` — the `selected` root this step reads.
        var selected: [String: Any] = [:]
        if let pick = f.action.raw["select"]?.objectValue {
            guard let pickJSON = pick["step"]?.foundation, let pickData = try? JSONSerialization.data(withJSONObject: pickJSON),
                  let pickStep = try? JSONDecoder().decode(OnboardingStep.self, from: pickData) else {
                return XCTFail("[\(f.id)] action.select.step did not decode")
            }
            let resolvedPick = OnboardingStepPipeline.resolve(OnboardingStepPipeline.Input(
                step: pickStep, override: nil, pending: false, inputValues: [:],
                responses: accumulated, templateContext: fixtureTemplateContext(f), selected: [:],
                fieldConfigOverrides: [:], fieldOptionsOverrides: [:]
            ))
            guard let block = resolvedPick.blocks.first(where: { $0.id == pick["block_id"]?.stringValue }),
                  let option = block.field_options?.first(where: { ($0.id ?? $0.value) == pick["option_id"]?.stringValue }) else {
                return XCTFail("[\(f.id)] the picked option is not on the resolved step")
            }
            let selectedStore = SelectedOptionStore()
            selectedStore.record(fieldId: block.field_id ?? block.id, option: option)
            selected = selectedStore.snapshot
            h.state["selected_label"] = option.label ?? NSNull()
        }
        let answers = GoogleCredit.Answers(accumulated: accumulated, stepInputs: stepInputs, sessionStore: store, selected: selected)

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

        // The step as the REAL pipeline resolves it (raw pass → decode → override → interaction
        // layering) — what the step draws, and what it stores.
        let resolveStep = {
            OnboardingStepPipeline.resolve(OnboardingStepPipeline.Input(
                step: step, override: override, pending: false, inputValues: stepInputs,
                responses: accumulated, templateContext: self.fixtureTemplateContext(f), selected: [:],
                fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides
            ))
        }

        // `action.read[] = {name, block_id, option_id?, key}`: one value of the resolved step — an
        // option's `label` / `value`, or a block's `text` / `action_value` / `default_value` (its
        // `field_config.default_value`). Absent → null.
        if let reads = f.action.raw["read"]?.arrayValue {
            let blocks = resolveStep().blocks
            var out: [String: Any] = [:]
            for r in reads {
                guard let o = r.objectValue, let name = o["name"]?.stringValue, let key = o["key"]?.stringValue else {
                    return XCTFail("[\(f.id)] a read needs name + key")
                }
                let block = blocks.first { $0.id == o["block_id"]?.stringValue }
                var value: Any?
                if let optionId = o["option_id"]?.stringValue {
                    let option = block?.field_options?.first { ($0.id ?? $0.value) == optionId }
                    switch key {
                    case "label": value = option?.label
                    case "value": value = option?.value
                    default: return XCTFail("[\(f.id)] read \(name): unknown option key \(key)")
                    }
                } else {
                    switch key {
                    case "text": value = block?.text
                    case "action_value": value = block?.action_value
                    case "default_value": value = block?.field_config?["default_value"]?.value
                    default: return XCTFail("[\(f.id)] read \(name): unknown block key \(key)")
                    }
                }
                out[name] = value ?? NSNull()
            }
            h.state["read"] = out
        }

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
            let resolved = resolveStep()
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
