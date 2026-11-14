import Foundation

/// "The selected item" — what the user actually picked, addressable as
/// `{{selected.<field_id>.description}}` on a later screen.
///
/// 🔴 This is deliberately NOT stored in `responses`, and that is an acceptance criterion rather
/// than a design preference: `responses` is what customer webhooks receive, and quietly fattening
/// every payload with the full option object — images, sheet blocks, translations — would change
/// the bytes every existing integration parses. A customer who never asked for this feature must
/// see byte-identical payloads.
///
/// So the reported VALUE is unchanged (analytics joins and `next_step_rules` keep working exactly
/// as before) and the rest of the option lives here, reachable only through the template root.
final class SelectedOptionStore: @unchecked Sendable {
    static let shared = SelectedOptionStore()

    private let queue = DispatchQueue(label: "ai.appdna.selectedOptions", attributes: .concurrent)
    private var storage: [String: Any] = [:]

    /// Record a single-select choice.
    func record(fieldId: String, option: InputOption) {
        let payload = Self.payload(from: option)
        queue.async(flags: .barrier) { self.storage[fieldId] = payload }
    }

    /// Record a multi-select choice.
    ///
    /// An ARRAY in selection order, not a set: the order the user picked things in is information,
    /// and `{{selected.x.0.label}}` addressing the first choice depends on it being stable.
    func record(fieldId: String, options: [InputOption]) {
        let payloads = options.map { Self.payload(from: $0) }
        queue.async(flags: .barrier) { self.storage[fieldId] = payloads }
    }

    func clear(fieldId: String) {
        queue.async(flags: .barrier) { self.storage.removeValue(forKey: fieldId) }
    }

    /// The presented flow's own options as `{ value, label }` records, by field id and by `<step id>/<field id>`
    /// (`scopedKey`). An answer with no recorded pick (a resumed flow, a default, a host patch) still draws its label
    /// from these.
    private var flowOptionRecords: [String: Any] = [:]

    /// Keep this flow's option list. Replaces the previous flow's: only the flow on screen has answers to draw.
    func setFlowOptions(_ flow: OnboardingFlowConfig) {
        let records = Self.optionRecords(of: flow)
        queue.async(flags: .barrier) { self.flowOptionRecords = records }
    }

    /// The flow's option records, for the raw pass (`flow_options`).
    var flowOptions: [String: Any] { queue.sync { flowOptionRecords } }

    /// What a drawn answer looks up: each field's picked records, then the flow's own options.
    var drawingRecords: [String: Any] { queue.sync { Self.drawingRecords(selected: storage, flowOptions: flowOptionRecords) } }

    /// The key a step's own option list is kept under: two steps may answer the same field id with different
    /// options under the same values, and an answer's label is its own step's.
    static func scopedKey(step: String, field: String) -> String { "\(step)/\(field)" }

    /// The record keys an answer at `path` is labelled from, most specific first: `responses.<step>.<field>` reads its
    /// step's own options before the field's picks and options; any other answer path reads the field's.
    static func recordKeys(atPath path: String) -> [String] {
        let parts = path.components(separatedBy: ".")
        let field = parts.last ?? ""
        if parts.count == 3, parts[0] == "responses" { return [scopedKey(step: parts[1], field: field), field] }
        return [field]
    }

    /// Picks first, so a recorded pick wins over the flow's list.
    static func drawingRecords(selected: [String: Any], flowOptions: [String: Any]) -> [String: Any] {
        var out = selected
        for (field, list) in flowOptions {
            let picks: [Any] = selected[field].map { ($0 as? [Any]) ?? [$0] } ?? []
            out[field] = picks + ((list as? [Any]) ?? [])
        }
        return out
    }

    /// `{ value, label }` for every option a step of this flow authors. A label that is still a template
    /// has nothing to draw until it resolves, so it is left out and the stored value is drawn.
    static func optionRecords(of flow: OnboardingFlowConfig) -> [String: Any] {
        var out: [String: [[String: Any]]] = [:]
        func add(_ field: String?, _ value: String?, _ label: String?) {
            guard let field, !field.isEmpty, let value, !value.isEmpty, !value.contains("{{"),
                  let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !label.contains("{{") else { return }
            out[field, default: []].append(["value": value, "label": label])
        }
        for step in flow.steps {
            // Each record twice: under the field (any step's answer to it) and under this step's own key.
            func both(_ field: String?, _ value: String?, _ label: String?) {
                add(field, value, label)
                if let field, !field.isEmpty { add(scopedKey(step: step.id, field: field), value, label) }
            }
            func walk(_ blocks: [ContentBlock]?) {
                for block in blocks ?? [] {
                    if block.type.rawValue.hasPrefix("input_") {
                        for option in block.field_options ?? [] { both(block.field_id, option.resolvedValue, option.label) }
                    }
                    walk(block.children)
                    walk(block.stack_children)
                }
            }
            walk(step.config.content_blocks)
            for field in step.config.fields ?? [] {
                for option in field.options ?? [] {
                    both(field.id, option.value.flatMap { TemplateEngine.stringify($0.value) } ?? option.id, option.label)
                }
            }
        }
        return out
    }

    /// The map the template resolver reads as the `selected` root.
    var snapshot: [String: Any] {
        queue.sync { storage }
    }

    /// Test seam: inject an already-shaped payload.
    ///
    /// The fixture describes what the user PICKED, not the option DTO that produced it, so this
    /// takes the flattened shape directly. Going through `record` would require the fixture to
    /// carry a full InputOption, which would be testing the flattener rather than the root.
    func seedForTesting(fieldId: String, value: Any) {
        queue.sync(flags: .barrier) { storage[fieldId] = value }
    }

    func resetForTesting() {
        queue.sync(flags: .barrier) { storage.removeAll(); flowOptionRecords.removeAll() }
    }

    /// Test seam: the flow's option list in its stored shape, without building a whole flow.
    func seedFlowOptionsForTesting(_ records: [String: Any]) {
        queue.sync(flags: .barrier) { flowOptionRecords = records }
    }

    /// Flatten an option into something a dot path can walk.
    ///
    /// Only fields an author would plausibly reference. Copying the whole DTO would put images and
    /// nested sheet blocks behind `{{selected.…}}`, and a template that resolves to a dictionary
    /// renders as its Swift description — which is worse than not resolving at all.
    private static func payload(from option: InputOption) -> [String: Any] {
        var out: [String: Any] = [:]
        out["value"] = option.resolvedValue
        if let label = option.label { out["label"] = label }
        if let subtitle = option.subtitle { out["subtitle"] = subtitle }
        if let category = option.category { out["category"] = category }
        if let imageURL = option.image_url { out["image_url"] = imageURL }
        // `description` is the field the spec's own example uses; it rides in the set item's
        // free-form data rather than being a column, so it arrives through the same passthrough
        // as any other extra.
        if let icon = option.icon { out["icon"] = icon }
        // The keys whose text is a Google answer's content, each with that text as the user typed it:
        // a later step that DRAWS one draws Google's attribution (`GoogleCredit`); one that STORES or
        // SENDS it (an option value, a field default, a link or media URL) takes the typed text.
        if let keys = option.googleKeys, !keys.isEmpty { out[googleKeysKey] = keys }
        return out
    }

    /// The text a picked option draws, or nil: no label, a blank one, or a label that is a Google
    /// answer's content, which a token drawing an answer does not credit. Android `drawnLabel`.
    static func drawnLabel(_ record: Any?) -> String? {
        guard let record, !googleKeys(of: record).contains("label"),
              let label = (record as? [String: Any])?["label"], let text = TemplateEngine.stringify(label),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// A drawn answer as what the user picked: a select stores the option's id, and the screen
    /// must show its label. `field` is the answer's field id, `answer` the stored value (a single pick,
    /// or a multi pick's list, whose labels are comma-joined). `selected` is `drawingRecords`, so it holds
    /// picks then the flow's own options. Nil when nothing here applies, and the caller draws the stored
    /// value: no record for this value anywhere. A multi pick keeps the stored value of any item with no label.
    /// Never for a value that leaves the screen: an option's `value`, a URL, a hook's headers.
    static func drawnAnswer(field: String, answer: Any?, selected: [String: Any]) -> String? {
        drawnAnswer(keys: [field], answer: answer, selected: selected)
    }

    /// `drawnAnswer` reading the records under each of `keys` in turn: the first record holding the stored value wins.
    static func drawnAnswer(keys: [String], answer: Any?, selected: [String: Any]) -> String? {
        let records: [Any] = keys.flatMap { key -> [Any] in
            guard let r = selected[key] else { return [] }
            return (r as? [Any]) ?? [r]
        }
        func labelFor(_ text: String) -> String? {
            for r in records {
                guard let v = (r as? [String: Any])?["value"], TemplateEngine.stringify(v) == text else { continue }
                if let label = drawnLabel(r) { return label }
            }
            return nil
        }
        guard let answer else { return nil }
        if let items = answer as? [Any] {
            guard !items.isEmpty else { return nil }
            var texts: [String] = []
            for item in items {
                guard !(item is [String: Any]), !(item is [Any]), let t = TemplateEngine.stringify(item) else { return nil }
                texts.append(labelFor(t) ?? t)
            }
            return texts.joined(separator: ", ")
        }
        guard !(answer is [String: Any]), let text = TemplateEngine.stringify(answer) else { return nil }
        return labelFor(text)
    }

    /// `drawnAnswer` for a `responses.` or `step.` path, the only roots that name an answer.
    static func drawnAnswer(atPath path: String, answer: Any?, selected: [String: Any]) -> String? {
        guard path.hasPrefix("responses.") || path.hasPrefix("step.") else { return nil }
        return drawnAnswer(keys: recordKeys(atPath: path), answer: answer, selected: selected)
    }

    /// Where a recorded option keeps its Google keys (`InputOption.googleKeys`): key → typed text.
    static let googleKeysKey = "google_keys"

    /// The recorded option's keys whose text is a Google answer's content.
    static func googleKeys(of record: Any) -> [String] {
        guard let keys = (record as? [String: Any])?[googleKeysKey] as? [String: Any] else { return [] }
        return keys.keys.sorted()
    }

    /// The recorded option's text for `key` with every Google answer as the user typed it; nil when
    /// `key` is not a Google key.
    static func typedText(of record: Any?, key: String) -> String? {
        ((record as? [String: Any])?[googleKeysKey] as? [String: Any])?[key] as? String
    }

    /// A token that stops at a picked record (`{{selected.stop}}`), or at a multi pick's list of them,
    /// where a Google answer must not go (a stored value, a URL, a surface with no credit): each record
    /// with every key that came from a Google answer replaced by its text as the user typed it. Anything
    /// that is not a record is returned as it is.
    static func withTypedText(_ value: Any) -> Any {
        if let list = value as? [Any] { return list.map { withTypedText($0) } }
        guard var record = value as? [String: Any],
              let keys = record[googleKeysKey] as? [String: Any], !keys.isEmpty else { return value }
        for (key, typed) in keys where record[key] != nil { record[key] = typed }
        return record
    }
}
