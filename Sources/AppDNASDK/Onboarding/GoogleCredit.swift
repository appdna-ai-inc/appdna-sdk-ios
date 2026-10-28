import Foundation
import SwiftUI

/// Whether an onboarding step shows a Google answer's content in its text, and so must draw Google's
/// attribution in its own container.
///
/// Google requires attribution "within the same visual container" wherever its content is shown
/// without a Google map. On an onboarding step, three resolvers substitute an answer into text — the
/// raw host-data pass for content blocks, the TemplateEngine behind `loc()` and every legacy view's
/// `interpolated()`, and the view-level block pass — and none of them has view context to report a
/// substitution up from. So the step's container decides BEFORE it renders, from the step's own
/// data: a pure function of the step's SOURCE (never the substituted copy, whose raw-resolved blocks
/// no longer hold tokens) and of the answers each root reads.
///
/// The walk is generic, not a field list, so a field added to a step later is covered:
/// - every string's `{{…}}` tokens (the same scanner the raw pass uses);
/// - every string under a block's `bindings` object, as a bare path (`applyBindings` resolves those);
/// - visibility conditions name their variable without braces and outside `bindings`, so they never
///   set it — a condition decides whether something shows, it shows nothing itself.
///
/// A path credits when, under a root that reads onboarding answers, it reaches an answer carrying
/// `place_id` (`LocationAnswer.carriesPlaceId`), a key inside one, or a value holding one.
///
/// An option's `sheet_blocks` are a modal ABOVE the step, so the step's walk skips them and each sheet
/// walks its own, drawing the credit inside the sheet; a sheet resolves its `step` root against its
/// own inputs, as the sheet renderer does.
enum GoogleCredit {

    /// The roots that read onboarding answers.
    static let roots: Set<String> = ["responses", "step", "input", "onboarding"]

    /// The answers each root reads.
    struct Answers {
        /// `responses`: the flow's accumulated answers AND `SessionDataStore.onboardingResponses` — a
        /// block that is not raw-resolved interpolates through the TemplateEngine, which reads the
        /// latter. That store is replaced only when a step completes, so on the first step of a
        /// re-presented flow it can still hold the previous run's answer; it is walked all the same.
        var responses: [Any]
        /// `step`: the current step's inputs (a sheet's own inputs, for a sheet).
        var step: [String: Any]
        /// `input` / `onboarding`, and every legacy view's `interpolated()`:
        /// `SessionDataStore.onboardingResponses`.
        var onboarding: [String: Any]

        init(accumulated: [String: Any], stepInputs: [String: Any], sessionStore: [String: [String: Any]]) {
            self.responses = [accumulated, sessionStore]
            self.step = stepInputs
            self.onboarding = sessionStore
        }

        /// Whether any answer a root can read is a Google one. Nothing can credit otherwise, so the
        /// step's source is not even encoded.
        var holdAGoogleAnswer: Bool {
            responses.contains(where: GoogleCredit.holdsGoogleAnswer) || GoogleCredit.holdsGoogleAnswer(step)
                || GoogleCredit.holdsGoogleAnswer(onboarding)
        }
    }

    // MARK: - The step

    /// The step's source, as the walk reads it. Only what can be DRAWN is walked, so a key or an entry
    /// nothing renders never credits:
    /// - the step's `config` as the SDK decodes it (a key the decoder drops is never drawn);
    /// - each content block as published, because the raw host-data pass resolves the published block
    ///   before it is decoded (`data_templates` render from keys the typed block does not hold);
    /// - the config after the host's override is merged, as the renderer merges it (the override itself
    ///   is not `Codable`): an override's options for a block the step does not hold are dropped;
    /// - the interaction patches the router layers on (`fieldConfigOverrides` /
    ///   `fieldOptionsOverrides`), for the blocks they are layered onto — the step's top-level blocks.
    static func stepSources(
        step: OnboardingStep,
        override: StepConfigOverride?,
        fieldConfigOverrides: [String: [String: Any]],
        fieldOptionsOverrides: [String: [InputOption]]
    ) -> [Any] {
        sourcesBuilt += 1
        var sources: [Any] = []
        if let config = encodeToJSON(step.config) { sources.append(config) }
        if let raw = step.rawContentBlocks, let encoded = encodeToJSON(raw) { sources.append(encoded) }
        // Without an override the merged config IS `step.config`, already walked.
        let merged = override.map { StepConfigOverrideMerger.apply($0, to: step.config) }
        if let merged, let encoded = encodeToJSON(merged) { sources.append(encoded) }
        // A patch reaches the screen only through a block the step draws.
        let drawn = Set(((merged ?? step.config).content_blocks ?? []).map(\.id))
        let patches = fieldConfigOverrides.filter { drawn.contains($0.key) }
        if !patches.isEmpty { sources.append(patches) }
        let options = fieldOptionsOverrides.filter { drawn.contains($0.key) }
        if !options.isEmpty, let encoded = encodeToJSON(options) {
            // Keyed by block id, as the router keys them; kept as `{id, field_options}` objects so the
            // sheet index below files each option's sheet under its block.
            let byBlock = (encoded as? [String: Any] ?? [:]).map { ["id": $0.key, "field_options": $0.value] as [String: Any] }
            sources.append(byBlock)
        }
        return sources
    }

    /// How many times `stepSources` has encoded a step. Read by the tests that hold the router to one
    /// encode per change of what the step draws, not one per body pass.
    static var sourcesBuilt = 0

    /// The step's credit: its own walk, `sheet_blocks` skipped.
    static func shows(sources: [Any], answers: Answers) -> Bool {
        guard answers.holdAGoogleAnswer else { return false }
        return sources.contains { walk($0, answers) }
    }

    /// The step's credit from its parts — what the router calls.
    static func shows(
        step: OnboardingStep,
        override: StepConfigOverride?,
        fieldConfigOverrides: [String: [String: Any]],
        fieldOptionsOverrides: [String: [InputOption]],
        answers: Answers
    ) -> Bool {
        guard answers.holdAGoogleAnswer else { return false }
        return shows(
            sources: stepSources(
                step: step, override: override,
                fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides
            ),
            answers: answers
        )
    }

    // MARK: - Option sheets

    /// Every option sheet in the sources, by `sheetKey(blockId:optionId:)`: the source of each, walked
    /// on its own when that sheet opens. A key seen twice (the authored option and a host's
    /// replacement with the same id) keeps both sources, so either one's reference credits.
    static func sheetSources(in sources: [Any]) -> [String: [Any]] {
        var out: [String: [Any]] = [:]
        for s in sources { indexSheets(s, into: &out) }
        return out
    }

    static func sheetKey(blockId: String, optionId: String) -> String { "\(blockId)\u{1F}\(optionId)" }

    /// The source of the sheet `optionId` opens on `blockId`. An option a `repeat` generated is
    /// `<template id>__<n>`, and it opens its TEMPLATE's sheet: the index holds that one, filed under
    /// the template's id, as authored.
    static func sheetSource(in index: [String: [Any]], blockId: String, optionId: String) -> [Any]? {
        if let own = index[sheetKey(blockId: blockId, optionId: optionId)] { return own }
        guard let r = optionId.range(of: "__", options: .backwards),
              !optionId[r.upperBound...].isEmpty, optionId[r.upperBound...].allSatisfy(\.isNumber) else { return nil }
        return index[sheetKey(blockId: blockId, optionId: String(optionId[..<r.lowerBound]))]
    }

    /// A sheet's credit: its own blocks, its `step` root its own inputs, every other root the step's.
    static func sheetShows(sheetBlocks: [Any], sheetInputs: [String: Any], answers: Answers) -> Bool {
        var own = answers
        own.step = sheetInputs
        guard own.holdAGoogleAnswer else { return false }
        return sheetBlocks.contains { walk($0, own) }
    }

    // MARK: - The walk

    /// Every string in `value`, `sheet_blocks` skipped. Exposed so the fixture runner drives this,
    /// not a copy.
    static func walk(_ value: Any, _ answers: Answers) -> Bool {
        if let s = value as? String { return tokensCredit(s, answers) }
        if let d = value as? [String: Any] {
            for (key, child) in d {
                if key == "sheet_blocks" { continue }
                if key == "bindings", bindingsCredit(child, answers) { return true }
                if walk(child, answers) { return true }
            }
            return false
        }
        if let a = value as? [Any] { return a.contains { walk($0, answers) } }
        return false
    }

    /// The `{{…}}` tokens of one string.
    private static func tokensCredit(_ s: String, _ answers: Answers) -> Bool {
        guard s.contains("{{") else { return false }
        return HostDataResolver.extractTokens(s).contains { pathCredits($0.path, answers) }
    }

    /// Every string under a `bindings` object is a bare path.
    private static func bindingsCredit(_ value: Any, _ answers: Answers) -> Bool {
        if let s = value as? String { return pathCredits(s.trimmingCharacters(in: .whitespaces), answers) }
        if let d = value as? [String: Any] { return d.values.contains { bindingsCredit($0, answers) } }
        if let a = value as? [Any] { return a.contains { bindingsCredit($0, answers) } }
        return false
    }

    /// Whether one path, under an onboarding-answer root, reaches a Google answer, a key inside one,
    /// or a value holding one.
    static func pathCredits(_ path: String, _ answers: Answers) -> Bool {
        let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let root = segments.first, roots.contains(root) else { return false }
        let rest = Array(segments.dropFirst())
        switch root {
        case "responses":
            return answers.responses.contains { reaches(rest, in: $0) }
        case "step":
            return reaches(rest, in: answers.step)
        case "onboarding":
            return reaches(rest, in: answers.onboarding)
        case "input":
            // `{{input.<field>}}` searches every step's answers for the field.
            guard let field = rest.first else { return holdsGoogleAnswer(answers.onboarding) }
            return answers.onboarding.values.contains { stepAnswers in
                guard let value = dictionary(stepAnswers)?[field] else { return false }
                return reaches(Array(rest.dropFirst()), in: value)
            }
        default:
            return false
        }
    }

    /// Follows `segments` into `value`. Credits as soon as the walk stands on a Google answer (the
    /// rest of the path is a key inside it), or when the value it ends on holds one.
    private static func reaches(_ segments: [String], in value: Any) -> Bool {
        var current: Any = value
        for segment in segments {
            if LocationAnswer.carriesPlaceId(current) { return true }
            if let d = dictionary(current), let next = d[segment] {
                current = next
            } else if let a = current as? [Any], let i = Int(segment), a.indices.contains(i) {
                current = a[i]
            } else {
                return false
            }
        }
        return holdsGoogleAnswer(current)
    }

    /// Whether `value` is, or holds at any depth, a Google answer.
    static func holdsGoogleAnswer(_ value: Any) -> Bool {
        if LocationAnswer.carriesPlaceId(value) { return true }
        if let d = dictionary(value) { return d.values.contains(where: holdsGoogleAnswer) }
        if let a = value as? [Any] { return a.contains(where: holdsGoogleAnswer) }
        return false
    }

    /// Where each Google answer sits among the answers, one path per answer (root first, segments
    /// joined by a unit separator): `pathCredits` reaches a Google answer exactly when its path and one
    /// of these is a prefix of the other, so the walk's answer depends on the answers only through
    /// these. Empty when no Google answer is held.
    static func googlePaths(_ answers: Answers) -> [String] {
        var out: [String] = []
        func collect(_ value: Any, _ path: String) {
            if LocationAnswer.carriesPlaceId(value) { out.append(path); return }
            if let d = dictionary(value) {
                for (k, v) in d { collect(v, path + "\u{1F}" + k) }
            } else if let a = value as? [Any] {
                for (i, v) in a.enumerated() { collect(v, path + "\u{1F}" + String(i)) }
            }
        }
        for (i, r) in answers.responses.enumerated() { collect(r, "responses\(i)") }
        collect(answers.step, "step")
        collect(answers.onboarding, "onboarding")
        return out.sorted()
    }

    // MARK: - Helpers

    private static func indexSheets(_ value: Any, into out: inout [String: [Any]]) {
        if let d = value as? [String: Any] {
            if let blockId = d["id"] as? String, let options = d["field_options"] as? [Any] {
                for case let option as [String: Any] in options {
                    guard let sheet = option["sheet_blocks"] as? [Any], !sheet.isEmpty else { continue }
                    // `InputOption` reads its id as `id`, else `value`.
                    let optionId = (option["id"] as? String) ?? (option["value"] as? String) ?? ""
                    out[sheetKey(blockId: blockId, optionId: optionId), default: []].append(contentsOf: sheet)
                }
            }
            for child in d.values { indexSheets(child, into: &out) }
        } else if let a = value as? [Any] {
            for child in a { indexSheets(child, into: &out) }
        }
    }

    private static func dictionary(_ value: Any) -> [String: Any]? {
        if let d = value as? [String: Any] { return d }
        if let d = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (k, v) in d { if let key = k as? String { out[key] = v } }
            return out
        }
        return nil
    }

    static func encodeToJSON<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - What an option sheet needs to decide its own credit

/// Handed down from the step to the option sheets it can open (SwiftUI's environment reaches `.sheet`
/// content). A sheet looks up its own source by block and option, and walks it with its own inputs.
struct GoogleCreditSheetContext {
    /// Every option sheet in the step's sources, by `GoogleCredit.sheetKey` (built on demand).
    let index: () -> [String: [Any]]
    let answers: GoogleCredit.Answers

    init(index: @escaping () -> [String: [Any]], answers: GoogleCredit.Answers) {
        self.index = index
        self.answers = answers
    }

    init(sources: @escaping () -> [Any], answers: GoogleCredit.Answers) {
        self.init(index: { GoogleCredit.sheetSources(in: sources()) }, answers: answers)
    }

    /// The credit for the sheet of `optionId` on `blockId`, from the sheet's SOURCE: the presented
    /// blocks of a raw-resolved sheet have already had every token but its `step` ones substituted, so
    /// they no longer say what they show. An option a `repeat` generated finds its template's sheet.
    /// Only a sheet no source holds (an Option Set's option) walks the blocks it presents.
    func shows(blockId: String?, optionId: String?, presentedSheetBlocks: [ContentBlock], sheetInputs: [String: Any]) -> Bool {
        var own = answers
        own.step = sheetInputs
        guard own.holdAGoogleAnswer else { return false }
        if let blockId, let optionId, let source = GoogleCredit.sheetSource(in: index(), blockId: blockId, optionId: optionId) {
            return GoogleCredit.sheetShows(sheetBlocks: source, sheetInputs: sheetInputs, answers: answers)
        }
        let presented = GoogleCredit.encodeToJSON(presentedSheetBlocks) as? [Any] ?? []
        return GoogleCredit.sheetShows(sheetBlocks: presented, sheetInputs: sheetInputs, answers: answers)
    }
}

// MARK: - The router's memo

/// The step's credit, kept across body passes. Encoding the step is the cost, and a body pass runs on
/// every keystroke once a Google answer is held; so the sources (and the sheet index) are rebuilt only
/// when what the step draws changes — its content, the host's override, an interaction patch — and the
/// walk re-runs only when, besides, the PLACE of a Google answer among the answers changes. The walk's
/// answer depends on the answers only through those places (`GoogleCredit.googlePaths`), so typing
/// into a field that holds no Google answer re-runs nothing. One instance per router (`@State`).
///
/// The step's content is compared the way `OnboardingStepPipelineMemo` compares it — id, raw blocks,
/// localizations — which is what the router draws from, so the credit never disagrees with the screen.
final class GoogleCreditMemo {
    private struct SourcesKey: Equatable {
        let stepId: String
        let raw: [HostJSON]?
        let localizations: [String: [String: String]]?
        let override: HostJSON
        let patches: HostJSON
        let options: HostJSON
    }

    private var sourcesKey: SourcesKey?
    private var sources: [Any] = []
    private var sheetIndex: [String: [Any]]?
    private var shownFor: (key: SourcesKey, places: [String])?
    private var shown = false

    func sources(
        step: OnboardingStep, override: StepConfigOverride?,
        fieldConfigOverrides: [String: [String: Any]], fieldOptionsOverrides: [String: [InputOption]]
    ) -> [Any] {
        let key = Self.key(step: step, override: override, fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides)
        if key != sourcesKey {
            sources = GoogleCredit.stepSources(
                step: step, override: override,
                fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides
            )
            sourcesKey = key
            sheetIndex = nil
            shownFor = nil
        }
        return sources
    }

    /// The step's credit (`GoogleCredit.shows`).
    func shows(
        step: OnboardingStep, override: StepConfigOverride?,
        fieldConfigOverrides: [String: [String: Any]], fieldOptionsOverrides: [String: [InputOption]],
        answers: GoogleCredit.Answers
    ) -> Bool {
        let places = GoogleCredit.googlePaths(answers)
        guard !places.isEmpty else { return false }
        let s = sources(step: step, override: override, fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides)
        if let key = sourcesKey, let last = shownFor, last.key == key, last.places == places { return shown }
        shown = GoogleCredit.shows(sources: s, answers: answers)
        if let key = sourcesKey { shownFor = (key, places) }
        return shown
    }

    /// The option sheets' index (`GoogleCredit.sheetSources`), from the same sources.
    func sheetIndex(
        step: OnboardingStep, override: StepConfigOverride?,
        fieldConfigOverrides: [String: [String: Any]], fieldOptionsOverrides: [String: [InputOption]]
    ) -> [String: [Any]] {
        let s = sources(step: step, override: override, fieldConfigOverrides: fieldConfigOverrides, fieldOptionsOverrides: fieldOptionsOverrides)
        if let index = sheetIndex { return index }
        let index = GoogleCredit.sheetSources(in: s)
        sheetIndex = index
        return index
    }

    private static func key(
        step: OnboardingStep, override: StepConfigOverride?,
        fieldConfigOverrides: [String: [String: Any]], fieldOptionsOverrides: [String: [InputOption]]
    ) -> SourcesKey {
        func json<T: Encodable>(_ v: T?) -> HostJSON {
            guard let v, let any = GoogleCredit.encodeToJSON(v) else { return .null }
            return HostJSON(any: any)
        }
        let o: HostJSON = override.map { o in
            .object([
                "title": o.title.map { .string($0) } ?? .null,
                "subtitle": o.subtitle.map { .string($0) } ?? .null,
                "cta": o.ctaText.map { .string($0) } ?? .null,
                "defaults": HostJSON(any: o.fieldDefaults),
                "options": json(o.fieldOptions),
            ])
        } ?? .null
        return SourcesKey(
            stepId: step.id, raw: step.rawContentBlocks, localizations: step.config.localizations,
            override: o, patches: HostJSON(any: fieldConfigOverrides), options: json(fieldOptionsOverrides)
        )
    }
}

private struct GoogleCreditSheetContextKey: EnvironmentKey {
    static let defaultValue: GoogleCreditSheetContext? = nil
}

extension EnvironmentValues {
    /// The onboarding step's sheet credit context; nil outside an onboarding step.
    var googleCreditSheetContext: GoogleCreditSheetContext? {
        get { self[GoogleCreditSheetContextKey.self] }
        set { self[GoogleCreditSheetContextKey.self] = newValue }
    }
}
