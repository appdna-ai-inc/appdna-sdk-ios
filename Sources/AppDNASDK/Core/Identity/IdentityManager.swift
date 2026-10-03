import Foundation

/// Represents the current device + user identity.
struct DeviceIdentity {
    let anonId: String
    var userId: String?
    var traits: [String: Any]?
}

/// Manages anonymous and identified user identity.
/// Thread-safe via serial dispatch queue.
final class IdentityManager {
    private let queue = DispatchQueue(label: "ai.appdna.sdk.identity")
    /// `KeychainStoring`, not `KeychainStore`: the tests inject an in-memory double so the
    /// persistence assertions are deterministic instead of skipped. See `KeychainStore.swift`.
    private let keychainStore: KeychainStoring

    // Weak reference set after initialization
    weak var sessionManager: SessionManager?

    private var _anonId: String
    private var _userId: String?
    private var _traits: [String: Any]?
    /// The device-scoped traits the bootstrap answer carries (`country`, `region`, `city`, `timezone`, from the IP
    /// address), kept apart from the host's: every change of the host's traits — `identify(userId, traits)`, an
    /// account switch, `reset()` — keeps them under the host's (a host key wins). `identify` with traits used to
    /// replace the whole set, so the location traits were gone until the next bootstrap (the next app start), and
    /// a "user trait" rule on `country` stopped matching after a login. In memory: the bootstrap sends them on every
    /// start, and the persisted traits keep the last merge for the start before it answers.
    private var _deviceTraits: [String: Any] = [:]

    var currentIdentity: DeviceIdentity {
        queue.sync {
            DeviceIdentity(anonId: _anonId, userId: _userId, traits: _traits)
        }
    }

    init(keychainStore: KeychainStoring) {
        self.keychainStore = keychainStore

        // Load or generate anonymous ID
        if let existing = keychainStore.getAnonId() {
            self._anonId = existing
            Log.debug("Loaded existing anon_id: \(existing)")
        } else {
            let newId = UUID().uuidString.lowercased()
            keychainStore.setAnonId(newId)
            self._anonId = newId
            Log.info("Generated new anon_id: \(newId)")
        }

        // Load persisted user ID and traits
        self._userId = keychainStore.getUserId()
        self._traits = keychainStore.getUserTraits()
    }

    /// Link anonymous user to a known user.
    ///
    /// Traits behavior on a nil `traits` argument now matches Android AND is
    /// internally consistent (in-memory + keychain agree): clear traits ONLY when the user actually
    /// CHANGES (an account switch — the prior user's traits don't apply to the new one); retain them on a
    /// same-user re-identify (the common per-launch call). The old iOS code wiped in-memory traits on
    /// every nil-traits identify while leaving the keychain intact (inconsistent), and Android retained
    /// them even across a user switch (stale-trait targeting).
    func identify(userId: String, traits: [String: Any]? = nil) {
        queue.sync {
            let previousUserId = _userId
            _userId = userId
            keychainStore.setUserId(userId)
            if let traits = traits {
                let merged = withDeviceTraits(traits)
                _traits = merged
                keychainStore.setUserTraits(merged)
            } else if let previousUserId, previousUserId != userId {
                // Clear only on a genuine account SWITCH (a known user → a DIFFERENT known user), not on
                // the first anonymous→login transition (previousUserId == nil). Device-scoped traits such
                // as bootstrap geo (merged via mergeTraits before the host's first identify) should
                // survive first login.
                // The device's location traits stay.
                setDeviceTraitsOnly()
            }
            // else: same user or first login with no new traits → keep existing traits.
        }
    }

    /// On `queue`: `hostTraits` with the device traits under them (a host key wins).
    private func withDeviceTraits(_ hostTraits: [String: Any]) -> [String: Any] {
        var merged = hostTraits
        for (key, value) in _deviceTraits where merged[key] == nil { merged[key] = value }
        return merged
    }

    /// On `queue`: the host's traits are gone; only the device traits remain (none → nil).
    private func setDeviceTraitsOnly() {
        if _deviceTraits.isEmpty {
            _traits = nil
            keychainStore.clearUserTraits()
        } else {
            _traits = _deviceTraits
            keychainStore.setUserTraits(_deviceTraits)
        }
    }

    /// Merge the bootstrap's location traits without overwriting the host's ones; they are also kept as device
    /// traits (see `_deviceTraits`).
    func mergeTraits(_ newTraits: [String: Any]) {
        queue.sync {
            for (key, value) in newTraits { _deviceTraits[key] = value }
            var merged = _traits ?? [:]
            for (key, value) in newTraits {
                if merged[key] == nil { // Don't overwrite user-set traits
                    merged[key] = value
                }
            }
            _traits = merged
            keychainStore.setUserTraits(merged)
        }
    }

    /// Clear user identity. Keeps anonymous ID.
    func reset() {
        queue.sync {
            _userId = nil
            keychainStore.clearUserId()
            setDeviceTraitsOnly()
        }
    }
}
