import Foundation

/// API endpoint definitions.
enum Endpoint {
    case bootstrap
    case ingestEvents
    case ingestIdentify
    // Billing endpoints
    case verifyReceipt(body: [String: Any])
    case restorePurchases(body: [String: Any])
    case getEntitlements
    case signOffer(body: [String: Any])
    // Push endpoints (SPEC-030)
    case registerPushToken(body: [String: Any])
    case deactivatePushToken(body: [String: Any])
    case pushDelivered(body: [String: Any])
    case pushTapped(body: [String: Any])
    // Geocoding (SPEC-089)
    case geocodeAutocomplete
    // SPEC-448 — a page of an Option Set, or a search within it.
    case optionSet(id: String, cursor: String?, query: String?)

    var path: String {
        switch self {
        case .bootstrap:            return "/api/v1/sdk/bootstrap"
        case .ingestEvents:         return "/api/v1/ingest/events"
        case .ingestIdentify:       return "/api/v1/ingest/identify"
        case .verifyReceipt:        return "/api/v1/billing/verify"
        case .restorePurchases:     return "/api/v1/billing/restore"
        case .getEntitlements:      return "/api/v1/billing/entitlements"
        case .signOffer:            return "/api/v1/billing/offers/sign"
        case .registerPushToken:    return "/api/v1/push/token"
        case .deactivatePushToken:  return "/api/v1/push/token"
        case .pushDelivered:        return "/api/v1/push/delivered"
        case .pushTapped:           return "/api/v1/push/tapped"
        case .geocodeAutocomplete:  return "/api/v1/sdk/geocode/autocomplete"
        case .optionSet(let id, let cursor, let query):
            var path = "/api/v1/sdk/option-sets/\(id)"
            var params: [String] = []
            // Percent-encoded: a set id is a UUID, but a QUERY is whatever the user typed —
            // `Wschód słońca` or an ampersand would otherwise corrupt the URL.
            if let cursor, !cursor.isEmpty {
                params.append("cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)")
            }
            if let query, !query.isEmpty {
                params.append("q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
            }
            if !params.isEmpty { path += "?" + params.joined(separator: "&") }
            return path
        }
    }

    var method: String {
        switch self {
        case .bootstrap:            return "GET"
        case .ingestEvents:         return "POST"
        case .ingestIdentify:       return "POST"
        case .verifyReceipt:        return "POST"
        case .restorePurchases:     return "POST"
        case .getEntitlements:      return "GET"
        case .signOffer:            return "POST"
        case .registerPushToken:    return "POST"
        case .deactivatePushToken:  return "DELETE"
        case .pushDelivered:        return "POST"
        case .pushTapped:           return "POST"
        case .geocodeAutocomplete:  return "POST"
        case .optionSet:            return "GET"
        }
    }

    /// JSON body for POST endpoints that carry associated data.
    var body: [String: Any]? {
        switch self {
        case .verifyReceipt(let body):       return body
        case .restorePurchases(let body):     return body
        case .signOffer(let body):            return body
        case .registerPushToken(let body):    return body
        case .deactivatePushToken(let body):  return body
        case .pushDelivered(let body):        return body
        case .pushTapped(let body):           return body
        default:                              return nil
        }
    }

    func url(environment: Environment) -> URL? {
        let base: String
        switch environment {
        case .production: base = "https://api.appdna.ai"
        case .sandbox:    base = "https://api.appdna.ai"
        }
        return URL(string: base + path)
    }
}
