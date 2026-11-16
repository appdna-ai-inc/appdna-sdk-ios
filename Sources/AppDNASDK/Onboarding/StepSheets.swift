import Foundation

/**
 A sheet inside a step: declared on the step (`sheets`, beside `content_blocks`), opened by a button on the
 step (`action: "open_sheet"`, `sheet_id`) or by the step's Continue when the first required answer it is
 missing sits in the sheet. Mirror of Android `StepSheets.kt`, pinned by the shared `step_sheet_*` fixtures.

 The sheet's blocks are the STEP's: its inputs write the step's own answer store, so a consent ticked in it
 is in the step's answers the moment it is ticked, and the step's required-field gate counts its blocks.
 Closing it by a gesture is not a decline: what was ticked stays, nothing is written false, and Continue
 stays gated until the required answers are given.
 */
public struct StepSheet: Codable, Identifiable, Equatable {
    public let id: String
    public let content_blocks: [ContentBlock]
    /// `fit` (as tall as the content, up to `large`), `medium` (half the screen) or `large`.
    public let height: String
    /// Whether a swipe and a scrim tap close it.
    public let dismissible: Bool
    public let scrim_color: String
    /// Nil draws the step's background colour.
    public let background_color: String?
    public let corner_radius: Double
    public let drag_indicator: Bool
    /// Whether Continue opens it when the first missing required answer is in it.
    public let open_on_gate: Bool

    enum CodingKeys: String, CodingKey {
        case id, content_blocks, height, dismissible, scrim_color, background_color, corner_radius, drag_indicator, open_on_gate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? ""
        content_blocks = (try c.decodeLenientArray(ContentBlock.self, forKey: .content_blocks, in: "sheet.content_blocks")) ?? []
        let h = c.lenient(String.self, .height)
        height = (h == "medium" || h == "large" || h == "fit") ? h! : "fit"
        dismissible = c.lenient(Bool.self, .dismissible) ?? true
        scrim_color = c.lenient(String.self, .scrim_color).flatMap { $0.isEmpty ? nil : $0 } ?? StepSheets.defaultScrim
        background_color = c.lenient(String.self, .background_color).flatMap { $0.isEmpty ? nil : $0 }
        corner_radius = c.lenient(Double.self, .corner_radius) ?? 16
        drag_indicator = c.lenient(Bool.self, .drag_indicator) ?? true
        open_on_gate = c.lenient(Bool.self, .open_on_gate) ?? true
    }

    public static func == (a: StepSheet, b: StepSheet) -> Bool { a.id == b.id }
}

public enum StepSheets {
    public static let openAction = "open_sheet"
    public static let closeAction = "close_sheet"
    public static let openedEvent = "onboarding_sheet_opened"
    public static let closedEvent = "onboarding_sheet_closed"
    public static let defaultScrim = "#00000066"

    /// Drops a sheet with no id and a repeated id (the first wins); nil when nothing is left.
    static func normalized(_ raw: [StepSheet]?) -> [StepSheet]? {
        guard let raw else { return nil }
        var seen = Set<String>()
        let out = raw.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        return out.isEmpty ? nil : out
    }

    /// What the step's required-field gate reads: the step's blocks, then every sheet's, in order.
    static func gateBlocks(_ stepBlocks: [ContentBlock], _ sheets: [StepSheet]?) -> [ContentBlock] {
        guard let sheets, !sheets.isEmpty else { return stepBlocks }
        return stepBlocks + sheets.flatMap { $0.content_blocks }
    }

    /**
     Seeds the sheets' agreement defaults into the step's answers as the step first appears, as an on-step
     agreement seeds itself when drawn: each consent's `default_checked` under `<field_id>.<consent_id>`, a
     single-shape agreement's under its field id. A value already there (a restored answer) is kept.
     */
    static func seedDefaults(_ sheets: [StepSheet]?, into inputValues: inout [String: Any]) {
        for sheet in sheets ?? [] {
            for block in sheet.content_blocks where block.type == .agreement {
                let fieldId = block.field_id ?? block.id
                let consents = AgreementConsents.parse(block.field_config?["consents"]?.value)
                if consents.isEmpty {
                    if !(inputValues[fieldId] is Bool) {
                        inputValues[fieldId] = (block.field_config?["default_checked"]?.value as? Bool) ?? false
                    }
                } else {
                    for consent in consents {
                        let key = AgreementConsents.key(fieldId: fieldId, consentId: consent.id)
                        if !(inputValues[key] is Bool) { inputValues[key] = consent.defaultChecked }
                    }
                }
            }
        }
    }
}

/// What the step does when its gate refuses an action (see `StepSheetController.onGateRefused`).
enum StepSheetGateOutcome { case openedSheet, showToast }

/// What a button inside the open sheet does (see `StepSheetController.onSheetAction`).
enum StepSheetActionOutcome { case handled, passToStep }

/**
 The per-step state of its sheets: which one is open, how it was opened, and the action the gate refused
 (re-run by the sheet's `next`). Pure: the renderer and the fixture runner drive the same instance.
 */
final class StepSheetController {
    struct Effects {
        var track: (String, [String: Any]) -> Void
        /// The sheet now shown, or nil when none is.
        var present: (StepSheet?) -> Void
        /// Re-run the action the gate refused (through the step's own dispatcher, which gates again).
        var rerun: (String, String?) -> Void
        /// The step's skip.
        var skip: () -> Void
    }

    let sheets: [StepSheet]
    private let flowId: String
    private let stepId: String
    var effects: Effects
    private(set) var openSheet: StepSheet?
    private var pending: (action: String, value: String?)?

    init(sheets: [StepSheet], flowId: String, stepId: String, effects: Effects) {
        self.sheets = sheets
        self.flowId = flowId
        self.stepId = stepId
        self.effects = effects
    }

    func sheet(_ id: String?) -> StepSheet? {
        guard let id else { return nil }
        return sheets.first { $0.id == id }
    }

    /**
     Opens the sheet `id` (`via` = `button` | `gate`). One sheet at a time: opening while one is up replaces
     it. An id not on the step is a no-op with a debug log (the publisher refuses it).
     */
    @discardableResult
    func open(_ id: String?, via: String) -> Bool {
        guard let target = sheet(id) else {
            Log.debug("Onboarding: open_sheet \"\(id ?? "")\" is not a sheet on step \(stepId); ignored")
            return false
        }
        if via != "gate" { pending = nil }
        openSheet = target
        effects.track(StepSheets.openedEvent, ["flow_id": flowId, "step_id": stepId, "sheet_id": target.id, "via": via])
        effects.present(target)
        return true
    }

    /**
     The step's gate refused `action`. When the step's own blocks pass and the first sheet whose blocks do
     not is `open_on_gate`, that sheet opens (no toast) and `action` is remembered for its `next`.
     `passes` is the step's real gate over one block list.
     */
    func onGateRefused(action: String, value: String?, stepBlocks: [ContentBlock], passes: ([ContentBlock]) -> Bool) -> StepSheetGateOutcome {
        guard !sheets.isEmpty, passes(stepBlocks) else { return .showToast }
        guard let missing = sheets.first(where: { !passes($0.content_blocks) }), missing.open_on_gate else { return .showToast }
        open(missing.id, via: "gate")
        pending = (action, value)
        return .openedSheet
    }

    /// A button inside the open sheet.
    func onSheetAction(_ action: String, value: String?) -> StepSheetActionOutcome {
        guard openSheet != nil else { return .passToStep }
        switch action {
        case "next", "continue":
            let p = pending
            close(via: "next")
            if let p { effects.rerun(p.action, p.value) }
            return .handled
        case "dismiss", StepSheets.closeAction:
            close(via: "dismiss")
            return .handled
        case "skip":
            close(via: "skip")
            effects.skip()
            return .handled
        case StepSheets.openAction:
            open(value, via: "button")
            return .handled
        default:
            return .passToStep
        }
    }

    /// A swipe or a scrim tap (`via`). Refused (false) when the sheet is not dismissible. Not a decline.
    @discardableResult
    func onDismissGesture(via: String) -> Bool {
        guard let s = openSheet, s.dismissible else { return false }
        close(via: via)
        return true
    }

    private func close(via: String) {
        guard let s = openSheet else { return }
        openSheet = nil
        pending = nil
        effects.track(StepSheets.closedEvent, ["flow_id": flowId, "step_id": stepId, "sheet_id": s.id, "via": via])
        effects.present(nil)
    }
}
