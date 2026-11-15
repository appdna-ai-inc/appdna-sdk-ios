import Foundation

/**
 The consents ONE Agreement element holds, and whether each required one is accepted.

 An Agreement held one consent with one Required setting. With `field_config.consents` it holds up to five,
 one under another, each with its own text, colours and Required. Each answer is stored FLAT, under
 `<field_id>.<consent_id>` as a Bool, so a rule, `{{responses.*}}` or a webhook reads a consent as it
 reads any other answer. A required consent blocks the CTA until it is checked; an optional one never does.

 An Agreement with no `consents` keeps the single-consent shape it always had (`agreement_text`, the
 block's `field_required`, one Bool under `field_id`).

 Pure, so the rule is pinned by the shared `agreement_consents` fixture on both platforms.
 */
public enum AgreementConsents {
    public struct Consent: Equatable {
        public let id: String
        public let text: String
        public let required: Bool
        public let defaultChecked: Bool
        public let textColor: String?
        public let linkColor: String?
        public let checkboxColor: String?
        public let checkboxBorderColor: String?
    }

    /// At most this many consents are drawn; the editor offers no more.
    public static let max = 5

    /// The consents in `field_config.consents`, in order. An entry without a usable id is dropped (its answer
    /// would have no key), a repeated id keeps its first entry, and anything past the fifth is ignored.
    public static func parse(_ raw: Any?) -> [Consent] {
        guard let items = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var out: [Consent] = []
        for item in items {
            guard out.count < max, let d = item as? [String: Any] else { continue }
            let id = ((d["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard isIdShaped(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Consent(
                id: id,
                text: (d["text"] as? String) ?? "",
                required: (d["required"] as? Bool) ?? false,
                defaultChecked: (d["default_checked"] as? Bool) ?? false,
                textColor: nonEmpty(d["text_color"]),
                linkColor: nonEmpty(d["link_color"]),
                checkboxColor: nonEmpty(d["checkbox_color"]),
                checkboxBorderColor: nonEmpty(d["checkbox_border_color"])
            ))
        }
        return out
    }

    /// Where one consent's answer is stored.
    public static func key(fieldId: String, consentId: String) -> String { "\(fieldId).\(consentId)" }

    /// The key of the first REQUIRED consent that is not checked, or nil when the CTA may advance.
    public static func firstMissing(fieldId: String, consents: [Consent], values: [String: Any]) -> String? {
        for c in consents where c.required {
            let k = key(fieldId: fieldId, consentId: c.id)
            if (values[k] as? Bool) != true { return k }
        }
        return nil
    }

    static func isIdShaped(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" }
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
