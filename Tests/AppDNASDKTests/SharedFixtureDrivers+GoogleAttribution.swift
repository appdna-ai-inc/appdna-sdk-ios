// SharedFixtureDrivers+GoogleAttribution.swift
//
// iOS drivers for Google's attribution. Dispatched from `driveMapFixtures`. Every value asserted is
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
import SwiftUI
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
    /// the step down to it, as each block's view applies it. A case with `appearances: true` reports
    /// `[{name, variant_light, variant_dark}]` instead: the variant in each system appearance.
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
                // `dropdown`: what is behind the logo under the block's location dropdown, the call the
                // block's view makes with what is behind the dropdown.
                if o["dropdown"]?.boolValue == true, let block = path.last {
                    let cfg = block.field_config
                    backdrop = A.backdrop(
                        ofDropdownFill: cfg?["dropdown_bg_color"]?.value as? String,
                        opacity: cfgDouble(cfg?["dropdown_opacity"]) ?? 1,
                        behind: backdrop, unstyled: .plain(hex: nil)
                    )
                }
            }
            let described: String
            switch backdrop {
            case .plain(let hex): described = hex.map { "plain:\($0)" } ?? "plain"
            case .busy: described = "busy"
            case .busyLight: described = "busy_light"
            }
            func variantName(dark: Bool) -> String {
                switch A.variant(on: backdrop, darkAppearance: dark) {
                case .gray: return "gray"
                case .white: return "white"
                case .lightOutline: return "light_outline"
                case .darkOutline: return "dark_outline"
                }
            }
            if o["appearances"]?.boolValue == true {
                // The variant in each appearance, as the step draws it there. No backdrop: an unstyled fill is the
                // system background on this platform and a theme colour on Android, and the variant is what the
                // two must agree on.
                results.append(["name": name, "variant_light": variantName(dark: false), "variant_dark": variantName(dark: true)])
                continue
            }
            if o["ink"]?.boolValue == true {
                // The ink of text nobody coloured, in a light appearance, through the real rule.
                let light = A.needsLightInk(on: backdrop, darkAppearance: o["dark_appearance"]?.boolValue == true)
                results.append(["name": name, "backdrop": described, "variant_light": variantName(dark: false), "ink": light ? "light" : "dark"])
                continue
            }
            results.append(["name": name, "backdrop": described, "variant_light": variantName(dark: false)])
        }
        h.state["results"] = results
    }

    // MARK: markdown_links

    /// `action.cases[] = {name, markdown, surface?, draw?}` → `[{name, links: [{text, url}], runs?}]`:
    /// each line through `MarkdownLinks.parseLine` — the Foundation parse `rich_text` and an agreement's
    /// copy draw with — and the runs carrying a link, adjacent runs with the same link joined. `surface:
    /// "rich_text"` first runs the rich-text block's own `normaliseMarkdown` (which drops a code span's
    /// backticks); `"agreement"`, or no surface, hands the parser the line as written, as an
    /// agreement's copy does.
    ///
    /// `draw: true` adds `runs`: the text as `MarkdownText.attributed` draws it for that surface (the
    /// function both views call; `++underline++` on `rich_text` only), one entry per stretch drawn the
    /// same way — `{text, style?: [bold, italic, underline, strike, code], link?}`. `underline` is the
    /// `++` marker's (a link is always underlined). U+FFFC, which Foundation puts where an image has no
    /// alt text, is left out: `Text` draws it with no width (measured: `x\u{FFFC}x` is as wide as `xx`).
    func runMarkdownLinks(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue, !cases.isEmpty else {
            return XCTFail("[\(f.id)] markdown_links needs action.cases")
        }
        var results: [[String: Any]] = []
        for c in cases {
            guard let o = c.objectValue, let name = o["name"]?.stringValue, let raw = o["markdown"]?.stringValue else {
                return XCTFail("[\(f.id)] a case needs name + markdown")
            }
            let md: String
            switch o["surface"]?.stringValue {
            case nil, "agreement"?: md = raw
            case "rich_text"?: md = ContentBlockRendererView.normaliseMarkdown(raw)
            case let other?: return XCTFail("[\(f.id)] case \(name): unknown surface '\(other)'")
            }
            var links: [[String: Any]] = []
            if #available(iOS 15.0, *), let parsed = MarkdownLinks.parseLine(md) {
                var lastURL: URL?
                for run in parsed.runs {
                    guard let url = run.link else { lastURL = nil; continue }
                    let text = String(parsed[run.range].characters)
                    if url == lastURL, var last = links.popLast() {
                        last["text"] = (last["text"] as? String ?? "") + text
                        links.append(last)
                    } else {
                        links.append(["text": text, "url": url.absoluteString])
                    }
                    lastURL = url
                }
            }
            var result: [String: Any] = ["name": name, "links": links]
            if #available(iOS 15.0, *), o["draw"]?.boolValue == true {
                let drawn = MarkdownText.attributed(md, linkColor: .blue, textColor: nil, underlineMarkers: o["surface"]?.stringValue == "rich_text")
                result["runs"] = Self.drawnRuns(drawn)
            }
            results.append(result)
        }
        h.state["results"] = results
    }

    @available(iOS 15.0, *)
    static func drawnRuns(_ drawn: AttributedString) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var lastKey: String?
        for run in drawn.runs {
            let text = String(drawn[run.range].characters).replacingOccurrences(of: "\u{FFFC}", with: "")
            if text.isEmpty { continue }
            var style: [String] = []
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { style.append("bold") }
            if intent.contains(.emphasized) { style.append("italic") }
            if run.link == nil, run.underlineStyle != nil { style.append("underline") }
            if intent.contains(.strikethrough) { style.append("strike") }
            if intent.contains(.code) { style.append("code") }
            let link = run.link?.absoluteString
            let key = style.joined(separator: ",") + "|" + (link ?? "")
            if key == lastKey, var last = out.popLast() {
                last["text"] = (last["text"] as? String ?? "") + text
                out.append(last)
                continue
            }
            var entry: [String: Any] = ["text": text]
            if !style.isEmpty { entry["style"] = style }
            if let link { entry["link"] = link }
            out.append(entry)
            lastKey = key
        }
        return out
    }

    // MARK: onboarding_google_credit

    /// setup.config.step = one onboarding step as published; setup.session_data = {responses (the
    /// flow's accumulated answers), session_store (SessionDataStore.onboardingResponses), step (the
    /// step's inputs)}. action: override {title, subtitle, cta_text, field_defaults, field_options, data},
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
        // The TemplateEngine roots (`input`, `onboarding`) read the session store, on the onboarding
        // surface — as the router's context does.
        let base = fixtureTemplateContext(f)
        let templateContext = TemplateContext(
            userTraits: base.userTraits, remoteConfig: base.remoteConfig, onboardingResponses: store,
            computedData: [:], sessionData: base.sessionData, deviceInfo: [:], surface: .onboarding
        )
        // `action.select = {step, block_id, option_id | option_ids, in_sheet?, override?,
        // field_options_overrides?}` (or a list of them, picked in order): an EARLIER step, resolved
        // through the REAL pipeline with the same answers and the picks before it, drawn as its
        // renderer draws it, and the option(s) the user picked there, recorded by the REAL
        // `SelectedOptionStore` — the `selected` root this step reads.
        var selected: [String: Any] = [:]
        let picks: [[String: AnyJSON]] = f.action.raw["select"].map { $0.arrayValue?.compactMap(\.objectValue) ?? [$0.objectValue].compactMap { $0 } } ?? []
        let selectedStore = SelectedOptionStore()
        for pick in picks {
            guard let pickJSON = pick["step"]?.foundation, let pickData = try? JSONSerialization.data(withJSONObject: pickJSON),
                  let pickStep = try? JSONDecoder().decode(OnboardingStep.self, from: pickData) else {
                return XCTFail("[\(f.id)] action.select.step did not decode")
            }
            var pickOptions: [String: [InputOption]] = [:]
            for (blockId, options) in pick["field_options_overrides"]?.objectValue ?? [:] {
                pickOptions[blockId] = Self.decodeOptions(options)
            }
            // `inputs`: what the user entered on the pick step itself before picking (its `step` root).
            let pickInputs = (pick["inputs"]?.foundation as? [String: Any]) ?? [:]
            let resolvedPick = OnboardingStepPipeline.resolve(OnboardingStepPipeline.Input(
                step: pickStep, override: Self.creditOverride(pick["override"]), pending: false, inputValues: pickInputs,
                responses: accumulated, templateContext: templateContext, selected: selected,
                fieldConfigOverrides: [:], fieldOptionsOverrides: pickOptions
            ))
            // The picked Select at any depth: a container's child records its pick like a top-level one,
            // drawn as the step's renderer draws it (`displayBlock`: a block the raw pass did not
            // produce goes through the view-level pass). `in_sheet = {block_id, option_id, inputs?}`: the
            // Select is drawn in that option's sheet, as the sheet's renderer draws it, against the
            // sheet's own inputs.
            var pickBlocks = Self.withShared(selected) {
                resolvedPick.blocks.map {
                    OnboardingStepPipeline.displayBlock(
                        $0, rawResolved: resolvedPick.isRawResolved($0.id), hookData: nil, responses: accumulated, stepInputs: pickInputs
                    )
                }
            }
            // `via: "view_pass"`: the pick step is drawn as a step with no raw capture draws it — every block
            // through the view-level pass, against the step's own inputs.
            if pick["via"]?.stringValue == "view_pass" {
                pickBlocks = Self.withShared(selected) {
                    (pickStep.config.content_blocks ?? []).map {
                        OnboardingStepPipeline.displayBlock(
                            $0, rawResolved: false, hookData: nil, responses: accumulated, stepInputs: pickInputs
                        )
                    }
                }
            }
            if let inSheet = pick["in_sheet"]?.objectValue {
                let owner = Self.findBlock(inSheet["block_id"]?.stringValue, in: resolvedPick.blocks)
                let opened = owner?.field_options?.first { ($0.id ?? $0.value) == inSheet["option_id"]?.stringValue }
                // `in_sheet.inputs`: what the user entered in the sheet before picking (its own inputs).
                let sheetInputs = (inSheet["inputs"]?.foundation as? [String: Any]) ?? [:]
                pickBlocks = (opened?.sheet_blocks ?? []).map {
                    OnboardingStepPipeline.displayBlock($0, rawResolved: true, hookData: nil, responses: [:], stepInputs: sheetInputs)
                }
            }
            guard let block = Self.findBlock(pick["block_id"]?.stringValue, in: pickBlocks) else {
                return XCTFail("[\(f.id)] the picked block is not on the resolved step")
            }
            // Each picked option goes through the write the Select's own presentation runs, in order, so a
            // fixture can only assert a pick its own Select can make: several ids on a single Select leave the
            // last one picked, as a user's taps would. A dropdown-style Select picks through its menu's seam
            // (`DropdownSelectPick.apply`, which refuses an add over `max_selections` silently, as the menu does);
            // the tap-path styles through `SelectOptionTap.apply`.
            let ids = pick["option_ids"]?.arrayValue?.compactMap(\.stringValue)
                ?? [pick["option_id"]?.stringValue].compactMap { $0 }
            let options = ids.compactMap { id in block.field_options?.first { ($0.id ?? $0.value) == id } }
            guard !ids.isEmpty, options.count == ids.count else {
                return XCTFail("[\(f.id)] a picked option is not on the resolved step")
            }
            var values: [String] = []
            var tapInputs: [String: Any] = [:]
            let fid = block.field_id ?? block.id
            for option in options where Self.drawsAsDropdown(block) {
                _ = DropdownSelectPick.apply(
                    value: option.resolvedValue, options: block.field_options ?? [], block: block,
                    selectedValues: values, sourcedOptions: block.field_options ?? [],
                    inputValues: &tapInputs, store: selectedStore
                )
                values = SelectOptionTap.isMultiSelect(block)
                    ? SelectionResync.multiAfterExternalChange(tapInputs[fid], drawn: values) : []
            }
            for option in options where !Self.drawsAsDropdown(block) {
                guard let next = SelectOptionTap.apply(
                    option: option, block: block, selectedValues: values, sourcedOptions: block.field_options ?? [],
                    inputValues: &tapInputs, store: selectedStore
                ) else { return XCTFail("[\(f.id)] the Select refused a pick (its max_selections)") }
                values = next.selectedValues
            }
            h.state["selected_label"] = options.last?.label ?? NSNull()
            selected = selectedStore.snapshot
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
                responses: accumulated, templateContext: templateContext, selected: selected,
                fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides
            ))
        }

        // The option sheet `action.sheet` opens, as its renderer draws it: the presented option's sheet
        // blocks from the REAL pipeline, each through `displayBlock` — the call the sheet's own renderer
        // makes — so its deferred `{{step.…}}` paths resolve against the sheet's own inputs.
        let sheetSpec = f.action.raw["sheet"]?.objectValue
        let sheetOption: () -> InputOption? = {
            guard let sheet = sheetSpec else { return nil }
            return resolveStep().blocks.first(where: { $0.id == sheet["block_id"]?.stringValue })?.field_options?
                .first(where: { $0.id == sheet["option_id"]?.stringValue })
        }
        let drawnSheet: () -> [ContentBlock] = {
            let inputs = (sheetSpec?["inputs"]?.foundation as? [String: Any]) ?? [:]
            return (sheetOption()?.sheet_blocks ?? []).map {
                OnboardingStepPipeline.displayBlock($0, rawResolved: true, hookData: nil, responses: [:], stepInputs: inputs)
            }
        }

        // `action.read[] = {name, via?, block_id?, option_id?, key}`: one value as a renderer draws or
        // stores it — an option's `label` / `value`, or a block's `text` / `action_value` /
        // `default_value` (its `field_config.default_value`) / `image_url` / `video_url` / `lottie_url`
        // / `markdown_content`, the block found at any depth. `via`: `pipeline` (default) the step the
        // REAL pipeline resolves; `view_pass` the same step built without raw capture, each block drawn
        // through `displayBlock` (the view-level pass); `sheet` the sheet above; `legacy` the step's
        // `title` / `subtitle` / `cta_text` through `interpolated()`, as every legacy view draws them.
        // Absent → null.
        if let reads = f.action.raw["read"]?.arrayValue {
            var cache: [String: [ContentBlock]] = [:]
            func blocks(_ via: String) -> [ContentBlock] {
                if let hit = cache[via] { return hit }
                let out: [ContentBlock]
                switch via {
                case "view_pass":
                    let bare = OnboardingStep(id: step.id, type: step.type, config: step.config, hook: step.hook,
                                              hide_progress: step.hide_progress, hide_back: step.hide_back,
                                              next_step_rules: step.next_step_rules, name: step.name)
                    let resolved = OnboardingStepPipeline.resolve(OnboardingStepPipeline.Input(
                        step: bare, override: override, pending: false, inputValues: stepInputs,
                        responses: accumulated, templateContext: templateContext, selected: selected,
                        fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides
                    ))
                    // The view-level pass reads the `selected` root from the shared store.
                    out = Self.withShared(selected) {
                        (resolved.config.content_blocks ?? []).map {
                            OnboardingStepPipeline.displayBlock(
                                $0, rawResolved: resolved.isRawResolved($0.id),
                                hookData: nil, responses: accumulated, stepInputs: stepInputs
                            )
                        }
                    }
                case "screen":
                    // A Screen draws the same blocks through the view-level pass with the surface a
                    // Screen's renderer has (`appdnaTemplateSurface`'s default): no Google credit there.
                    out = Self.withShared(selected) {
                        (step.config.content_blocks ?? []).map {
                            resolveBlockTemplates($0, hookData: nil, responses: accumulated, stepInputs: stepInputs,
                                                  surface: EnvironmentValues().appdnaTemplateSurface)
                        }
                    }
                case "sheet": out = drawnSheet()
                default: out = resolveStep().blocks
                }
                cache[via] = out
                return out
            }
            let legacyContext = templateContext
            var out: [String: Any] = [:]
            for r in reads {
                guard let o = r.objectValue, let name = o["name"]?.stringValue, let key = o["key"]?.stringValue else {
                    return XCTFail("[\(f.id)] a read needs name + key")
                }
                let via = o["via"]?.stringValue ?? "pipeline"
                var value: Any?
                if via == "legacy" {
                    let source: String?
                    switch key {
                    case "title": source = step.config.title
                    case "subtitle": source = step.config.subtitle
                    case "cta_text": source = step.config.cta_text
                    default: return XCTFail("[\(f.id)] read \(name): unknown legacy key \(key)")
                    }
                    value = source?.interpolated(context: legacyContext)
                    out[name] = value ?? NSNull()
                    continue
                }
                let block = Self.findBlock(o["block_id"]?.stringValue, in: blocks(via))
                if let planId = o["plan_id"]?.stringValue {
                    // What a pick of the plan stores (`selected_plan_label`).
                    guard key == "stored_plan_label" else { return XCTFail("[\(f.id)] read \(name): unknown plan key \(key)") }
                    value = block?.pricing_plans?.first { $0.id == planId }?.storedLabel
                } else if let optionId = o["option_id"]?.stringValue {
                    let option = block?.field_options?.first { ($0.id ?? $0.value) == optionId }
                    switch key {
                    case "label": value = option?.label
                    case "value": value = option?.value
                    // The text a pick of the option records for its label when the label took a Google
                    // answer's content: what the user typed. Null when it took none.
                    case "google_label": value = option?.googleKeys?["label"]
                    default: return XCTFail("[\(f.id)] read \(name): unknown option key \(key)")
                    }
                } else {
                    switch key {
                    case "text": value = block?.text
                    case "action_value": value = block?.action_value
                    case "default_value": value = block?.field_config?["default_value"]?.value
                    case "image_url": value = block?.image_url
                    case "video_url": value = block?.video_url
                    case "lottie_url": value = block?.lottie_url
                    case "markdown_content": value = block?.markdown_content
                    default: return XCTFail("[\(f.id)] read \(name): unknown block key \(key)")
                    }
                }
                // `match = {contains?, lacks?}`: a value whose exact text is not portable (a picked record
                // drawn whole, which each platform stringifies its own way) is checked for what it must
                // and must not hold; the read reports "matched", or the value itself when a check fails.
                if let match = o["match"]?.objectValue, let v = value {
                    let text = "\(v)"
                    let contains = match["contains"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let lacks = match["lacks"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    value = contains.allSatisfy { text.contains($0) } && !lacks.contains { text.contains($0) } ? "matched" : text
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

    /// `body` run with the shared `SelectedOptionStore` holding `selected` — the store the view-level
    /// pass reads the `selected` root from — and emptied after.
    static func withShared<T>(_ selected: [String: Any], _ body: () -> T) -> T {
        let store = SelectedOptionStore.shared
        store.resetForTesting()
        for (field, value) in selected { store.seedForTesting(fieldId: field, value: value) }
        defer { store.resetForTesting() }
        return body()
    }

    /// The block with `id` among `blocks` at any depth: `children`, `stack_children` and option sheets.
    /// Whether a picked block draws as a dropdown, as the Select view decides it: an `input_select` whose
    /// `display_style` (default `dropdown`) is not a tap-path style, or a Segmented drawn through the Select.
    static func drawsAsDropdown(_ block: ContentBlock) -> Bool {
        let style = block.field_config?["display_style"]?.value as? String
        let select = block.type == .input_select
            || (block.type == .input_segmented && !SegmentedPresentation.drawsSegmentedControl(displayStyle: style))
        return select && !["stacked", "grid", "image_tiles", "bubble", "bubble_scroll", "list"].contains(style ?? "dropdown")
    }

    static func findBlock(_ id: String?, in blocks: [ContentBlock]) -> ContentBlock? {
        guard let id else { return nil }
        for b in blocks {
            if b.id == id { return b }
            let nested = (b.children ?? []) + (b.stack_children ?? []) + (b.field_options ?? []).flatMap { $0.sheet_blocks ?? [] }
            if let hit = findBlock(id, in: nested) { return hit }
        }
        return nil
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
            fieldOptions: fieldOptions,
            // The host's data for the step: the `hook_data` root.
            dataContext: o["data"]?.foundation as? [String: Any]
        )
    }

    private static func decodeOptions(_ json: AnyJSON) -> [InputOption] {
        guard let raw = json.foundation as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let options = try? JSONDecoder().decode([InputOption].self, from: data) else { return [] }
        return options
    }
}
