import Foundation

/// Persists cross-module data (onboarding responses, computed hook data, session data)
/// so it can be used by TemplateEngine across all SDK modules.
/// Thread-safe via serial dispatch queue. Persists to UserDefaults (not sensitive data).
final class SessionDataStore {

    static let shared = SessionDataStore()

    private let queue = DispatchQueue(label: "ai.appdna.sdk.sessiondata")
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let onboardingResponses = "appdna.session.onboarding_responses"
        static let computedData = "appdna.session.computed_data"
        static let sessionData = "appdna.session.session_data"
    }

    // Cap to prevent unbounded growth
    private static let maxStorageBytes = 100 * 1024 // 100KB

    // MARK: - In-memory state (loaded from UserDefaults on init)

    private var _onboardingResponses: [String: [String: Any]] = [:]
    private var _computedData: [String: Any] = [:]
    private var _sessionData: [String: Any] = [:]

    /// Thread-safe read of onboarding responses.
    var onboardingResponses: [String: [String: Any]] {
        queue.sync { _onboardingResponses }
    }

    /// Thread-safe read of computed data (from proceedWithData hooks).
    var computedData: [String: Any] {
        queue.sync { _computedData }
    }

    /// Thread-safe read of app-defined session data.
    var sessionData: [String: Any] {
        queue.sync { _sessionData }
    }

    private init() {
        // Load persisted data on init
        _onboardingResponses = loadDict(key: Keys.onboardingResponses) as? [String: [String: Any]] ?? [:]
        _computedData = loadDict(key: Keys.computedData) ?? [:]
        _sessionData = loadDict(key: Keys.sessionData) ?? [:]
    }

    // MARK: - Onboarding Responses

    /// Called when onboarding flow completes — persists all step responses.
    func setOnboardingResponses(_ responses: [String: Any]) {
        queue.sync {
            // responses is keyed by stepId, each value is a dict of field values
            var converted: [String: [String: Any]] = [:]
            for (stepId, value) in responses {
                if let dict = value as? [String: Any] {
                    converted[stepId] = dict
                }
            }
            _onboardingResponses = converted
            persistDict(_onboardingResponses, key: Keys.onboardingResponses)
        }
    }

    // MARK: - Computed Data (from proceedWithData)

    /// Merge hook-injected data into the computed namespace.
    func mergeComputedData(_ data: [String: Any]) {
        queue.sync {
            for (key, value) in data {
                _computedData[key] = value
            }
            persistDict(_computedData, key: Keys.computedData)
        }
    }

    // MARK: - Session Data (public API)

    /// Set a session data value (public API: `AppDNA.setSessionData(key, value)`).
    func setSessionData(key: String, value: Any) {
        queue.sync {
            _sessionData[key] = value
            persistDict(_sessionData, key: Keys.sessionData)
        }
    }

    /// Get a session data value (public API: `AppDNA.getSessionData(key)`).
    func getSessionData(key: String) -> Any? {
        queue.sync { _sessionData[key] }
    }

    /// Clear all session data (public API: `AppDNA.clearSessionData()`).
    func clearSessionData() {
        queue.sync {
            _sessionData = [:]
            defaults.removeObject(forKey: Keys.sessionData)
        }
    }

    /// Clear everything (onboarding + computed + session).
    func clearAll() {
        queue.sync {
            _onboardingResponses = [:]
            _computedData = [:]
            _sessionData = [:]
            defaults.removeObject(forKey: Keys.onboardingResponses)
            defaults.removeObject(forKey: Keys.computedData)
            defaults.removeObject(forKey: Keys.sessionData)
        }
    }

    // MARK: - Persistence Helpers

    private func persistDict(_ dict: [String: Any], key: String) {
        // `data(withJSONObject:)` RAISES (an Objective-C exception `try?` cannot catch) on a NaN /
        // infinite number or a non-JSON leaf, so each entry is validated first and only
        // the entries that are not valid JSON are left out of the saved copy. It used to drop the WHOLE
        // store — the next launch lost every other value because one was NaN. The skip is logged (the
        // entry's name only — never the values, which can be answers the user typed); the in-memory
        // value stays readable for the rest of this session.
        var skipped: [String] = []
        var persistable: [String: Any] = [:]
        for (entryKey, value) in dict {
            if JSONSerialization.isValidJSONObject([entryKey: value]) {
                persistable[entryKey] = value
            } else if let inner = value as? [String: Any] {
                // One level down (an onboarding step's answers): keep the step's valid answers.
                var kept: [String: Any] = [:]
                for (innerKey, innerValue) in inner {
                    if JSONSerialization.isValidJSONObject([innerKey: innerValue]) {
                        kept[innerKey] = innerValue
                    } else {
                        skipped.append("\(entryKey).\(innerKey)")
                    }
                }
                persistable[entryKey] = kept
            } else {
                skipped.append(entryKey)
            }
        }
        skipped.sort()
        if !skipped.isEmpty {
            Log.warning("SessionDataStore: \(key) entries \(skipped) hold a value that is not valid JSON (a NaN / infinite number or a non-JSON type) — those entries are not persisted")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: persistable) else {
            Log.warning("SessionDataStore: \(key) could not be encoded — not persisted; the saved copy is cleared")
            defaults.removeObject(forKey: key)
            return
        }
        // Enforce size cap
        guard data.count <= Self.maxStorageBytes else {
            Log.warning("SessionDataStore: \(key) exceeds \(Self.maxStorageBytes) bytes — not persisted; the saved copy is cleared")
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private func loadDict(key: String) -> [String: Any]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
