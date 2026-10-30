import Foundation

/// The four Console settings that shape a location autocomplete search, resolved once for whichever
/// surface is asking.
///
/// 🔴 EXTRACTED BECAUSE THE DUPLICATION WAS THE DEFECT. The form-step Location field read all
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
/// `type`, `biasCountry` and `language` are resolved here for BOTH surfaces, and both act on them:
/// the form-step field and the content block search through the same geocoding proxy, which
/// filters by type, restricts to the bias country and answers in the language. Every setting is
/// checked on every surface by `check:location-config-reach`.
struct LocationSearchSettings: Equatable {
    /// 🔴 OPTIONAL, and nil means the author never chose one — which is NOT the same as "address".
    /// No surface substitutes a default: both pass `type` to the search as it is here, and a nil
    /// one is left out of the request body. The proxy then applies its own unset-type behaviour
    /// (`mapboxTypeFilter` and `googlePrimaryTypes` in the server's `GeocodingService`): Mapbox
    /// searches places, localities and addresses, and Google applies no type filter. Substituting
    /// a default here would silently change what every unauthored field returns.
    let type: String?
    let biasCountry: String?
    let language: String?
    let minChars: Int

    /// From a content block's free-form `field_config`.
    static func from(blockConfig: [String: AnyCodable]?, defaultMinChars: Int) -> LocationSearchSettings {
        LocationSearchSettings(
            type: acceptableType(blockConfig?["location_type"]?.value as? String),
            biasCountry: nonBlank(blockConfig?["location_bias_country"]?.value as? String),
            language: nonBlank(blockConfig?["location_language"]?.value as? String),
            minChars: clampMinChars(blockConfig?["location_min_chars"]?.value, defaultMinChars)
        )
    }

    /// From a form-step field's `FormFieldConfig`.
    static func from(fieldConfig: FormFieldConfig?, defaultMinChars: Int) -> LocationSearchSettings {
        LocationSearchSettings(
            type: acceptableType(fieldConfig?.location_type),
            biasCountry: nonBlank(fieldConfig?.location_bias_country),
            language: nonBlank(fieldConfig?.location_language),
            minChars: clampMinChars(fieldConfig?.location_min_chars, defaultMinChars)
        )
    }

    /// The only values the geocoding proxy accepts
    /// (`/api/v1/sdk/geocode/autocomplete` → `z.enum(['city','address','region','country'])`).
    ///
    /// 🔴 A TYPE WE CANNOT USE IS TREATED AS ABSENT, NOT PASSED ON. The proxy answers an unknown
    /// `type` with a ValidationError, and both SDKs read a non-200 as "no suggestions" — so
    /// forwarding a bad value turns the whole autocomplete OFF rather than degrading it.
    ///
    /// Not hypothetical: content-block `field_config` is `.passthrough()` and therefore
    /// UNVALIDATED, and the Console's content-block Location Type select offered `coordinates` —
    /// in no enum, no SDK, and refused by the proxy. Those blocks were harmless only because this
    /// surface sent no `type` at all; the moment it honoured the authored one every one of
    /// them would have gone silently dead. The picker is fixed too, but published documents
    /// outlive a picker fix.
    private static let proxyTypes: Set<String> = ["city", "address", "region", "country"]

    private static func acceptableType(_ raw: String?) -> String? {
        guard let t = nonBlank(raw), proxyTypes.contains(t) else { return nil }
        return t
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
