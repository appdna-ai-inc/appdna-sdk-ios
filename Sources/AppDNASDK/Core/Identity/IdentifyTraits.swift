import Foundation

/// The trait values `identify` can carry: JSON values, and the SDK's own `LocationData`.
///
/// A `LocationData` becomes the answer map a location field stores, the same map the onboarding
/// `responses` hold for it (snake_case keys, only the keys the answer has), so the server treats it as a
/// location answer. Any other value that is not a JSON value (a string, a finite number, a boolean,
/// `NSNull`, a dictionary with string keys, an array of them) is dropped with a warning naming its
/// trait key, and only that key. A null is a JSON value and is kept: `NSNull`, and an optional's `nil`
/// boxed in `Any`, are sent and stored as `null`, as a trait or anywhere inside one.
///
/// This is what keeps `identify` from crashing: `JSONSerialization.data(withJSONObject:)`, which the
/// keychain write and the request body use, raises an Objective-C exception for any other value, and
/// `try?` cannot catch that. The Kotlin twin is `IdentifyTraits` in `IdentifyTraits.kt`.
enum IdentifyTraits {

    /// `traits` with every value JSON-safe: a `LocationData` as its answer map, any other non-JSON value
    /// dropped. `log` says which keys were dropped (the public `identify` logs; the identity store,
    /// which sanitises again before persisting, does not).
    static func sanitize(_ traits: [String: Any], log: Bool = true) -> [String: Any] {
        var out: [String: Any] = [:]
        var dropped: [String] = []
        for (key, value) in traits {
            if let json = jsonValue(value), JSONSerialization.isValidJSONObject([key: json]) {
                out[key] = json
            } else {
                dropped.append(key)
            }
        }
        if log, !dropped.isEmpty {
            Log.warning("identify: trait(s) \(dropped.sorted()) dropped — a trait value must be a JSON value "
                + "(string, number, boolean, dictionary, array) or LocationData")
        }
        return out
    }

    /// `location` as the answer map a location field stores: `formatted_address` and each set field.
    static func answerMap(_ location: LocationData) -> [String: Any] {
        var map: [String: Any] = ["formatted_address": location.formatted_address]
        if let v = location.city { map["city"] = v }
        if let v = location.state { map["state"] = v }
        if let v = location.state_code { map["state_code"] = v }
        if let v = location.country { map["country"] = v }
        if let v = location.country_code { map["country_code"] = v }
        if let v = location.latitude, v.isFinite { map["latitude"] = v }
        if let v = location.longitude, v.isFinite { map["longitude"] = v }
        if let v = location.timezone { map["timezone"] = v }
        if let v = location.timezone_offset { map["timezone_offset"] = v }
        if let v = location.postal_code { map["postal_code"] = v }
        if let v = location.raw_query { map["raw_query"] = v }
        if let v = location.mapbox_id { map["mapbox_id"] = v }
        if let v = location.place_id { map["place_id"] = v }
        return map
    }

    /// `value` as a JSON-safe value, or nil when it cannot be one (anywhere inside it).
    private static func jsonValue(_ value: Any) -> Any? {
        // An optional boxed in `Any` (`["referrer": referrer as Any]`): a nil is the JSON null it stands
        // for, and a set one is its value. Neither matches a case below as it is.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return NSNull() }
            return jsonValue(wrapped)
        }
        switch value {
        case let location as LocationData:
            return answerMap(location)
        case is String, is NSNull:
            return value
        case let number as NSNumber:
            // Bool and every numeric type bridge here; a non-finite double is not JSON.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : nil
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                guard let json = jsonValue(v) else { return nil }
                out[k] = json
            }
            return out
        case let array as [Any]:
            var out: [Any] = []
            for v in array {
                guard let json = jsonValue(v) else { return nil }
                out.append(json)
            }
            return out
        default:
            return nil
        }
    }
}
