import Foundation

/// The served document of one screen or flow, as the console publishes it
/// (`ScreenConfigSyncService.buildScreenConfig` / `buildFlowConfig`, written to
/// `config/screen_index/screens/{id}` and `config/screen_index/flows/{id}`):
///
///     { id, version, name, config: { presentation, layout, sections, … }, audience_rules?, trigger_rules?,
///       start_date?, end_date?, min_sdk_version?, default_locale, analytics_name?, updated_at }
///
/// The renderable config is nested under `config`, and the identity and scheduling fields sit beside it. This
/// flattens it into the shape `ScreenConfig` / `FlowConfig` decode: the nested config, with the document's
/// identity and scheduling fields filled in where the config does not carry its own. The document id is the
/// cache key, so it always wins. `audience_rules` / `trigger_rules` are NOT copied: the index carries them for
/// trigger and slot decisions, and the document's own shape for them differs from the config's.
///
/// A document with no `config` object is taken as an already-flat config (the shape `previewScreen` takes).
/// Mirrors Android `ScreenDocument.normalize`; shared fixture `dto_parsing/screen_served_document.fixture.json`.
enum ScreenDocument {
    private static let carried = [
        "name", "version", "start_date", "end_date", "min_sdk_version", "default_locale", "analytics_name",
    ]

    static func normalize(_ document: [String: Any], id: String) -> [String: Any] {
        let nested = document["config"] as? [String: Any]
        var out = nested ?? document
        if nested != nil {
            for key in carried where (out[key] == nil || out[key] is NSNull) {
                if let v = document[key], !(v is NSNull) { out[key] = v }
            }
        }
        out["id"] = id
        return out
    }

    static func decodeScreen(_ document: [String: Any], id: String) -> ScreenConfig? {
        decode(ScreenConfig.self, normalize(document, id: id), what: "screen", id: id)
    }

    static func decodeFlow(_ document: [String: Any], id: String) -> FlowConfig? {
        decode(FlowConfig.self, normalize(document, id: id), what: "flow", id: id)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ dict: [String: Any], what: String, id: String) -> T? {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.error("Failed to parse \(what) config \(id): \(error)")
            return nil
        }
    }
}
