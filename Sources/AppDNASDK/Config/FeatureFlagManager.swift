import Foundation

/// Thin wrapper over RemoteConfigManager for boolean feature flags.
final class FeatureFlagManager {
    private let remoteConfigManager: RemoteConfigManager

    init(remoteConfigManager: RemoteConfigManager) {
        self.remoteConfigManager = remoteConfigManager
    }

    /// Get the raw value of a feature flag.
    func getValue(flag: String) -> Any? {
        return remoteConfigManager.getConfig(key: flag)
    }

    /// Returns true if the flag exists and is a truthy boolean value.
    func isEnabled(flag: String) -> Bool {
        guard let value = remoteConfigManager.getConfig(key: flag) else {
            return false
        }

        if let bool = value as? Bool {
            return bool
        }

        // String-typed flags are first-class on the server (FeatureFlagValue.type can be
        // 'string'), but iOS had NO String branch → every string flag read `false` while Android read
        // "true"/"1" as truthy. Handle them case-insensitively (trimmed), matching Android's set.
        if let str = value as? String {
            return ["true", "1", "yes", "on"].contains(
                str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }

        // Any non-zero number → true (NSNumber.boolValue). Matches Android's non-zero rule.
        if let num = value as? NSNumber {
            return num.boolValue
        }

        return false
    }
}
