import Foundation

/// The persisted analytics-consent decision.
///
/// Consent used to live only in `EventTracker.analyticsConsent`, an in-memory `Bool` initialised to
/// `true`. So `setConsent(false)` held for the life of the process and was silently undone by the
/// next cold start: an opted-out user was opted back in on every launch. That is a bug, not a
/// missing feature, which is why the fix lands here rather than waiting for the full multi-purpose
/// consent store.
///
/// `UserDefaults` — not the EventStore — because the decision must be readable *before*
/// `configure()` wires the pipeline, exactly like `ClientSeqCounter`.
///
/// Three states, and the third is load-bearing:
///   - `true`  — granted
///   - `false` — denied
///   - `nil`   — **no decision yet**. `AppDNAOptions.requireConsent` decides what that means.
internal enum ConsentStore {
    private static let key = "ai.appdna.sdk.analytics_consent"

    /// The persisted decision, or nil if the user has never been asked.
    static var decision: Bool? {
        get { UserDefaults.standard.object(forKey: key) as? Bool }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Resolve the decision that `configure()` should start with.
    ///
    /// ⚠️ **READ THIS BEFORE SHIPPING INTO THE EU/UK.** `requireConsent` defaults to **false**, so
    /// the `?? !requireConsent` below resolves a *never-asked* user to **granted**. Analytics are
    /// **opt-OUT by default**, and `sdk_initialized` — carrying device, OS, locale and session
    /// context — is emitted by `configure()` **before the user has made any consent decision at
    /// all**. If your app needs a lawful basis before the first byte leaves the device, you MUST
    /// pass `requireConsent: true`; nothing else in this SDK will do it for you.
    ///
    /// This is a deliberate contract, not an oversight, and the reasoning is worth stating because
    /// the line reads like a bug:
    ///
    ///   - Opt-out is what this SDK has always done (`EventTracker.analyticsConsent = true`), and
    ///     what Amplitude/Mixpanel/Firebase do. Flipping the DEFAULT to opt-in would silently zero
    ///     the analytics of every already-shipped host on their next SDK bump — they would not find
    ///     out from an error, they would find out from an empty dashboard weeks later. A default
    ///     that breaks existing hosts quietly is a worse failure than the one it fixes.
    ///   - What AC-36 actually owed, and what this type delivers, is that the decision is now
    ///     (a) **persisted** — `setConsent(false)` is no longer undone by the next cold start — and
    ///     (b) **honored before the first event**, `sdk_initialized` included, whenever a decision
    ///     exists or `requireConsent` is set. The pre-decision exposure at the default is the
    ///     documented behavior of the default, not a hole in the gate.
    ///   - The per-purpose consent store (marketing / personalisation / analytics as separate
    ///     grants) is separate work, and it is where a compliant DEFAULT belongs — it needs a consent UI
    ///     and a host migration, neither of which is a wrapper's to invent.
    ///
    /// - Parameter requireConsent: when true, the absence of a decision means **denied** (opt-in),
    ///   and NO event — `sdk_initialized` included — is emitted until `setConsent(_:)` is called.
    static func effectiveConsent(requireConsent: Bool) -> Bool {
        decision ?? !requireConsent
    }

    /// Test seam. Not part of the public surface.
    static func reset() { decision = nil }
}
