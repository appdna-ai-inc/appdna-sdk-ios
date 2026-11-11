import Foundation
import KeychainAccess

/// The identity-persistence surface `IdentityManager` depends on.
///
/// It exists so a test can inject an in-memory double, and that is not a stylistic preference — it
/// is the fix for a test that could not fail.
///
/// `IdentityManagerTests` used to guard its two persistence tests with:
///
///     try XCTSkipIf(keychainStore.getString(key: "anon_id") == nil, "Keychain not available")
///
/// THE SKIP CONDITION WAS THE BUG. If the SDK failed to persist `anon_id`, `getString` returns nil —
/// and the test that exists to catch exactly that SKIPPED instead of failing. The skip is
/// indistinguishable from "this CI runner has no keychain entitlements", which is the normal
/// SwiftPM-simulator path, so the skip was the EXPECTED outcome and nobody looked twice. The two
/// tests standing between us and "identity does not survive a relaunch" were switched off by the
/// very condition they were meant to detect.
///
/// With an injected in-memory store there is no environment to be unavailable, so there is nothing
/// to skip: the persistence assertion runs, always, and fails when persistence breaks.
protocol KeychainStoring: AnyObject {
    func getAnonId() -> String?
    func setAnonId(_ id: String)

    func getUserId() -> String?
    func setUserId(_ id: String)
    func clearUserId()

    func getUserTraits() -> [String: Any]?
    func setUserTraits(_ traits: [String: Any])
    func clearUserTraits()

    /// Generic Keychain strings: the consent signal's ack record lives here, beside `anon_id`.
    func getString(key: String) -> String?
    func setString(key: String, value: String)
}

extension KeychainStoring {
    /// Default for identity-only doubles: no generic storage.
    func getString(key: String) -> String? { nil }
    func setString(key: String, value: String) {}
}

/// Wrapper around KeychainAccess for identity persistence.
final class KeychainStore: KeychainStoring {
    private let keychain: Keychain

    private enum Keys {
        static let anonId = "anon_id"
        static let userId = "user_id"
        static let userTraits = "user_traits"
    }

    init(service: String = "ai.appdna.sdk") {
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlock)
    }

    // MARK: - Anonymous ID

    func getAnonId() -> String? {
        try? keychain.get(Keys.anonId)
    }

    func setAnonId(_ id: String) {
        try? keychain.set(id, key: Keys.anonId)
    }

    // MARK: - User ID

    func getUserId() -> String? {
        try? keychain.get(Keys.userId)
    }

    func setUserId(_ id: String) {
        try? keychain.set(id, key: Keys.userId)
    }

    func clearUserId() {
        try? keychain.remove(Keys.userId)
    }

    // MARK: - User Traits

    func getUserTraits() -> [String: Any]? {
        guard let data = try? keychain.getData(Keys.userTraits) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func setUserTraits(_ traits: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: traits) else { return }
        try? keychain.set(data, key: Keys.userTraits)
    }

    func clearUserTraits() {
        try? keychain.remove(Keys.userTraits)
    }

    // MARK: - Generic string storage

    func getString(key: String) -> String? {
        try? keychain.get(key)
    }

    func setString(key: String, value: String) {
        try? keychain.set(value, key: key)
    }
}
