import Foundation

/// UserDefaults-based cache for Firestore remote configs.
final class ConfigCache {
    private let defaults: UserDefaults
    private let ttlLock = NSLock()
    private var _ttl: TimeInterval
    /// Seconds after a fetch before the cache is stale. Changed by a bootstrap's `configTTL` (`RuntimeSettings`).
    var ttl: TimeInterval {
        get { ttlLock.lock(); defer { ttlLock.unlock() }; return _ttl }
        set { ttlLock.lock(); _ttl = newValue; ttlLock.unlock() }
    }

    private enum Keys {
        static let paywalls = "paywalls"
        static let experiments = "experiments"
        static let flags = "flags"
        static let flows = "flows"
        static let onboarding = "onboarding"
        static let messages = "messages"
        static let surveys = "surveys"
        static let fetchedAt = "fetchedAt"
    }

    init(ttl: TimeInterval, suiteName: String = "ai.appdna.sdk.config") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self._ttl = ttl
    }

    /// Whether the cached config is older than the TTL.
    var isStale: Bool {
        guard let fetchedAt = defaults.object(forKey: Keys.fetchedAt) as? Date else {
            return true
        }
        return Date().timeIntervalSince(fetchedAt) > ttl
    }

    // MARK: - Store

    func storePaywalls(_ data: Data) {
        defaults.set(data, forKey: Keys.paywalls)
    }

    /// Mark the config as freshly fetched.
    func markFetched() {
        defaults.set(Date(), forKey: Keys.fetchedAt)
    }

    func storeExperiments(_ data: Data) {
        defaults.set(data, forKey: Keys.experiments)
    }

    func storeFlags(_ data: Data) {
        defaults.set(data, forKey: Keys.flags)
    }

    func storeFlows(_ data: Data) {
        defaults.set(data, forKey: Keys.flows)
    }

    func storeOnboarding(_ data: Data) {
        defaults.set(data, forKey: Keys.onboarding)
    }

    func storeMessages(_ data: Data) {
        defaults.set(data, forKey: Keys.messages)
    }

    func storeSurveys(_ data: Data) {
        defaults.set(data, forKey: Keys.surveys)
    }

    // MARK: - Retrieve

    func loadPaywalls() -> Data? {
        defaults.data(forKey: Keys.paywalls)
    }

    func loadExperiments() -> Data? {
        defaults.data(forKey: Keys.experiments)
    }

    func loadFlags() -> Data? {
        defaults.data(forKey: Keys.flags)
    }

    func loadFlows() -> Data? {
        defaults.data(forKey: Keys.flows)
    }

    func loadOnboarding() -> Data? {
        defaults.data(forKey: Keys.onboarding)
    }

    func loadMessages() -> Data? {
        defaults.data(forKey: Keys.messages)
    }

    func loadSurveys() -> Data? {
        defaults.data(forKey: Keys.surveys)
    }

    func loadFetchedAt() -> Date? {
        defaults.object(forKey: Keys.fetchedAt) as? Date
    }
}
