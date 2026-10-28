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

    /// The step's source, as the walk reads it: the step encoded (its `config` and its raw blocks),
    /// the config after the host's override is merged (the override itself is not `Codable`), and the
    /// interaction patches the router layers on (`fieldConfigOverrides` / `fieldOptionsOverrides`).
    static func stepSources(
        step: OnboardingStep,
        override: StepConfigOverride?,
        fieldConfigOverrides: [String: [String: Any]],
        fieldOptionsOverrides: [String: [InputOption]]
    ) -> [Any] {
        var sources: [Any] = []
        if let encoded = encodeToJSON(step) { sources.append(encoded) }
        // Without an override the merged config IS `step.config`, already in the encoded step.
        if override != nil, let merged = encodeToJSON(StepConfigOverrideMerger.apply(override, to: step.config)) {
            sources.append(merged)
        }
        if !fieldConfigOverrides.isEmpty { sources.append(fieldConfigOverrides) }
        if !fieldOptionsOverrides.isEmpty, let options = encodeToJSON(fieldOptionsOverrides) {
            // Keyed by block id, as the router keys them; kept as `{id, field_options}` objects so the
            // sheet index below files each option's sheet under its block.
            let byBlock = (options as? [String: Any] ?? [:]).map { ["id": $0.key, "field_options": $0.value] as [String: Any] }
            sources.append(byBlock)
        }
        return sources
    }

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
    let sources: () -> [Any]
    let answers: GoogleCredit.Answers

    /// The credit for the sheet of `optionId` on `blockId`. A sheet whose source is not found (an
    /// option a `repeat` template generated) walks the presented blocks instead.
    func shows(blockId: String?, optionId: String?, presentedSheetBlocks: [ContentBlock], sheetInputs: [String: Any]) -> Bool {
        var own = answers
        own.step = sheetInputs
        guard own.holdAGoogleAnswer else { return false }
        let index = GoogleCredit.sheetSources(in: sources())
        if let blockId, let optionId, let source = index[GoogleCredit.sheetKey(blockId: blockId, optionId: optionId)] {
            return GoogleCredit.sheetShows(sheetBlocks: source, sheetInputs: sheetInputs, answers: answers)
        }
        let presented = GoogleCredit.encodeToJSON(presentedSheetBlocks) as? [Any] ?? []
        return GoogleCredit.sheetShows(sheetBlocks: presented, sheetInputs: sheetInputs, answers: answers)
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
