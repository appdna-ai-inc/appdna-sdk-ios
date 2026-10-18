import Foundation

/// The four Console settings that shape a location autocomplete search, resolved once for whichever
/// surface is asking.
///
/// 🔴 EXTRACTED BECAUSE THE DUPLICATION WAS THE DEFECT (#963). The form-step Location field read all
/// four settings and the `input_location` content block read none of them, so an author who set
/// Type = "City" on a content block got street addresses and an authored Min characters did
/// nothing — silently, on both platforms. One resolver, used by every surface, is what makes that
/// impossible to repeat rather than merely fixed once. `LocationSearchSettings` in `LocationAnswer.kt` is the Kotlin
/// twin, field for field.
///
/// `defaultMinChars` differs per surface on purpose: the form-step field has always used 2 and the
/// content block 3 (which is also what the Console seeds). Preserving each keeps a surface that
/// authored nothing on the threshold it has today.
///
/// 🔴 `type`, `biasCountry` and `language` are resolved here for BOTH surfaces, but only the
/// form-step field can act on them: the content block searches Apple's place index, which takes no
/// country bias, no language tag and has no city/region/country result type. That asymmetry is
/// documented per surface on all four SDK pages and enforced by `check:location-config-reach`.
struct LocationSearchSettings: Equatable {
    /// 🔴 OPTIONAL, and nil means the author never chose one — which is NOT the same as "address".
    /// The server narrows results only when `type` is present (`GeocodingService.ts:230-232`,
    /// `:318-323`), so substituting a default here would silently change what every unauthored
    /// field returns. Each surface applies its own historical default at the call site, and the
    /// three-way disagreement that creates is tracked separately rather than papered over here.
    let type: String?
    let biasCountry: String?
    let language: String?
    let minChars: Int

    /// From a content block's free-form `field_config`.
    static func from(blockConfig: [String: AnyCodable]?, defaultMinChars: Int) -> LocationSearchSettings {
        LocationSearchSettings(
            type: nonBlank(blockConfig?["location_type"]?.value as? String),
            biasCountry: nonBlank(blockConfig?["location_bias_country"]?.value as? String),
            language: nonBlank(blockConfig?["location_language"]?.value as? String),
            minChars: clampMinChars(blockConfig?["location_min_chars"]?.value, defaultMinChars)
        )
    }

    /// From a form-step field's `FormFieldConfig`.
    static func from(fieldConfig: FormFieldConfig?, defaultMinChars: Int) -> LocationSearchSettings {
        LocationSearchSettings(
            type: nonBlank(fieldConfig?.location_type),
            biasCountry: nonBlank(fieldConfig?.location_bias_country),
            language: nonBlank(fieldConfig?.location_language),
            minChars: clampMinChars(fieldConfig?.location_min_chars, defaultMinChars)
        )
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// A threshold below 1 would search on an empty field — a request the proxy rejects and a
    /// dropdown the user never asked for. The Console sends a number; a JSON decode can hand it
    /// back as a `Double`, so both are accepted.
    private static func clampMinChars(_ raw: Any?, _ fallback: Int) -> Int {
        let value: Int?
        switch raw {
        case let i as Int: value = i
        case let d as Double where d.isFinite: value = Int(d)
        case let n as NSNumber: value = n.intValue
        default: value = nil
        }
        return max(1, value ?? fallback)
    }
}
