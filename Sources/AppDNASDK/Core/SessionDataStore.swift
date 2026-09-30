import Foundation

/// Persists cross-module data (onboarding responses, computed hook data, session data)
/// so it can be used by TemplateEngine across all SDK modules (SPEC-088).
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
        // infinite number or a non-JSON leaf, so validate first: an odd answer is not persisted,
        // rather than taking the host app down (SPEC-497 §13h).
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        // Enforce size cap
        guard data.count <= Self.maxStorageBytes else {
            Log.warning("SessionDataStore: \(key) exceeds \(Self.maxStorageBytes) bytes — not persisting")
            return
        }
        defaults.set(data, forKey: key)
    }

    private func loadDict(key: String) -> [String: Any]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
