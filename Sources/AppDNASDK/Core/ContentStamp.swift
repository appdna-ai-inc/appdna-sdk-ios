import Foundation

/// The item whose content a served item is showing while Serve instead has swapped it.
///
/// The server writes `served_from: { id, version }` on a served flow, paywall, message or survey
/// while a swap is open, and removes it on Undo. The SDK decides nothing from it: it copies `id`
/// onto the item's analytics events as `content_source_id`.
///
/// Decoded leniently: a malformed marker costs the marker, never the item that carries it.
public struct ServedFrom: Codable, Equatable {
    public let id: String?
    public let version: Int?

    public init(id: String?, version: Int? = nil) {
        self.id = id
        self.version = version
    }

    enum CodingKeys: String, CodingKey { case id, version }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        self.id = c?.lenient(String.self, .id)
        self.version = c?.lenient(Int.self, .version)
    }
}

/// A served item that can say which content it is showing: its own `version`, and `served_from`
/// while it is serving another item's content.
protocol ContentStampSource {
    var version: Int? { get }
    var served_from: ServedFrom? { get }
}

/**
 THE ONE PLACE THE CONTENT KEYS ARE WRITTEN.

 Every onboarding, paywall, purchase, in-app message and survey event names the content that was on
 screen, so analytics can split an item's numbers by content instead of blending a swapped item's
 before and after:

 - `content_version` — the served item's `version`, always when the item has one;
 - `content_source_id` — `served_from.id`, ONLY while the item is serving another item's content.

 No event site writes either key by hand. Mirrors Android `ContentStamp.kt`.
 */
enum ContentStamp {
    static let versionKey = "content_version"
    static let sourceIdKey = "content_source_id"

    /// The keys for one served item. Empty when the item has no version and no marker.
    static func props(version: Int?, servedFrom: ServedFrom?) -> [String: Any] {
        var p: [String: Any] = [:]
        if let version { p[versionKey] = version }
        if let id = servedFrom?.id, !id.isEmpty { p[sourceIdKey] = id }
        return p
    }

    static func props(for item: ContentStampSource?) -> [String: Any] {
        guard let item else { return [:] }
        return props(version: item.version, servedFrom: item.served_from)
    }

    /// `properties` with the stamp applied. The stamp wins over a key of the same name: the content
    /// keys describe what the SDK served, and nothing else may overwrite them.
    static func stamped(_ properties: [String: Any], _ stamp: [String: Any]) -> [String: Any] {
        guard !stamp.isEmpty else { return properties }
        return properties.merging(stamp) { _, stampValue in stampValue }
    }

    static func stamped(_ properties: [String: Any], for item: ContentStampSource?) -> [String: Any] {
        stamped(properties, props(for: item))
    }
}

extension OnboardingFlowConfig: ContentStampSource {}
extension PaywallConfig: ContentStampSource {}
extension MessageConfig: ContentStampSource {}
extension SurveyConfig: ContentStampSource {}
