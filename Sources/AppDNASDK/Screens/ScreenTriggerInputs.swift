import Foundation

/// What a screen's `trigger_rules` compare against besides the event: the sessions this install has started and
/// the whole days since the app was installed.
///
/// `daysSinceInstall` is nil when the install time cannot be read, and a `days_since_install` trigger then does not
/// fire (rather than reading the install as "today"). The Kotlin twin is `ScreenTriggerInputs` in
/// `ScreenTriggerInputs.kt`.
struct ScreenTriggerInputs {
    let sessionCount: Int
    let daysSinceInstall: Int?

    private static let dayMs: Int64 = 86_400_000

    /// Whole days from `installEpochMs` to `nowMs`; nil when the install time is unknown.
    static func daysSinceInstall(installEpochMs: Int64?, nowMs: Int64) -> Int? {
        guard let install = installEpochMs else { return nil }
        return Int(max(0, (nowMs - install) / dayMs))
    }

    /// The live inputs: the per-install session counter `SessionManager` keeps, and the install date experiment
    /// targeting reads (`AppInstallDate`, a backup-excluded marker written on the install's first launch).
    static func current(now: Date = Date()) -> ScreenTriggerInputs {
        let sessions = UserDefaults.standard.integer(forKey: SessionManager.sessionCountKey)
        return ScreenTriggerInputs(
            sessionCount: max(1, sessions),
            daysSinceInstall: daysSinceInstall(
                installEpochMs: AppInstallDate.epochMs(), nowMs: Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
        )
    }
}
