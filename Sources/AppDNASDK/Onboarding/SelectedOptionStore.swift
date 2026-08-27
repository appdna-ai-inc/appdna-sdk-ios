import Foundation

/// SPEC-448 §"The selected item" — what the user actually picked, addressable as
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
        queue.sync(flags: .barrier) { storage.removeAll() }
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
        return out
    }
}
