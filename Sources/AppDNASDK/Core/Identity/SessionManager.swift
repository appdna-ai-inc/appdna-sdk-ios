import Foundation
import UIKit

/// Tracks app sessions based on foreground/background lifecycle.
/// A new session starts on cold launch or after >30 minutes of inactivity.
///
/// `app_open` is sent exactly once per foreground entry, the cold launch included, with the same
/// properties every time (none):
/// - a cold launch with UI sends it from `init` (checked on the main queue, where `applicationState`
///   is readable), because `willEnterForegroundNotification` is not posted for an app-delegate launch;
/// - a scene-based launch may ALSO post `willEnterForegroundNotification`, and an app launched in the
///   background (a push, a background fetch) posts it when its UI first comes up. Whichever of the two
///   arrives first sends `app_open`; the other sends nothing until the app has been backgrounded again.
final class SessionManager {
    private let queue = DispatchQueue(label: "ai.appdna.sdk.session")
    private let eventTracker: EventTracker

    private static let sessionTimeoutInterval: TimeInterval = 30 * 60 // 30 minutes
    private static let lastActiveKey = "ai.appdna.sdk.lastActiveAt"
    /// Per-install session counter. SurveyManager READS this key for `min_sessions` triggers and for the
    /// survey-response `session_count`, but nothing WROTE it — so every min_sessions trigger was
    /// unsatisfiable and every response reported 0. Incremented on each new session below.
    static let sessionCountKey = "ai.appdna.sdk.session_count"

    private var _sessionId: String = UUID().uuidString.lowercased()

    /// `app_open` already sent for the current foreground entry. Cleared on `didEnterBackground`.
    /// Process-wide rather than per instance: a shutdown + configure inside one foreground builds a new
    /// SessionManager, and that is not a new foreground entry.
    private static let foregroundLock = NSLock()
    private static var appOpenSentThisForeground = false

    /// Whether the app is in the background right now; nil when it cannot be told (no shared
    /// application, as in a hostless unit test). Called on the main queue only.
    private let isApplicationInBackground: () -> Bool?

    /// Tests only: forget the process-wide foreground state, as a fresh process would.
    static func resetProcessStateForTest() {
        foregroundLock.lock(); appOpenSentThisForeground = false; foregroundLock.unlock()
    }

    /// `UIApplication.shared.applicationState == .background`, looked up dynamically (a hostless test has
    /// no shared application, so nil there). Main-thread-only, like `applicationState` itself.
    static func liveApplicationIsInBackground() -> Bool? {
        guard Thread.isMainThread else { return nil }
        let applicationClass: AnyObject = UIApplication.self
        guard let app = applicationClass.value(forKey: "sharedApplication") as? UIApplication else { return nil }
        return app.applicationState == .background
    }

    var sessionId: String {
        queue.sync { _sessionId }
    }

    init(
        eventTracker: EventTracker,
        isApplicationInBackground: @escaping () -> Bool? = SessionManager.liveApplicationIsInBackground
    ) {
        self.eventTracker = eventTracker
        self.isApplicationInBackground = isApplicationInBackground

        // Check if we need a new session (cold start or >30 min gap)
        let now = Date()
        if let lastActive = UserDefaults.standard.object(forKey: Self.lastActiveKey) as? Date,
           now.timeIntervalSince(lastActive) < Self.sessionTimeoutInterval {
            // Resume existing session — just track app_open
            Log.debug("Resuming session (last active \(lastActive))")
        } else {
            // New session
            startNewSession()
        }

        // Observe app lifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // The cold launch is a foreground entry too. Decided on the main queue, where the application
        // state can be read; configure() may run on any thread.
        DispatchQueue.main.async { [weak self] in
            self?.handleLaunchForeground()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func startNewSession() {
        queue.sync {
            _sessionId = UUID().uuidString.lowercased()
        }
        // Bump the per-install session counter the survey engine reads (see sessionCountKey).
        let d = UserDefaults.standard
        d.set(d.integer(forKey: Self.sessionCountKey) + 1, forKey: Self.sessionCountKey)
        eventTracker.track(event: "session_start", properties: nil)
        // The new session is activity. Without this, a scene-based cold launch that also posts
        // willEnterForeground re-read the stale lastActiveAt init had just acted on and rotated again.
        updateLastActive()
        Log.info("New session started: \(sessionId)")
    }

    /// Marks `app_open` sent for this foreground entry; false when it already was.
    private static func claimAppOpen() -> Bool {
        foregroundLock.lock(); defer { foregroundLock.unlock() }
        if appOpenSentThisForeground { return false }
        appOpenSentThisForeground = true
        return true
    }

    /// The cold-launch half: send `app_open` when the app is launching with UI. A background launch
    /// (or an unknown state) sends nothing here; its foreground arrives as willEnterForeground.
    func handleLaunchForeground() {
        guard isApplicationInBackground() == false else { return }
        guard Self.claimAppOpen() else { return }
        eventTracker.track(event: "app_open", properties: nil)
        updateLastActive()
    }

    private func updateLastActive() {
        UserDefaults.standard.set(Date(), forKey: Self.lastActiveKey)
    }

    @objc func appDidEnterForeground() {
        // Once per foreground entry: the cold launch may already have sent it.
        guard Self.claimAppOpen() else { return }
        let now = Date()
        let lastActive = UserDefaults.standard.object(forKey: Self.lastActiveKey) as? Date

        if let lastActive, now.timeIntervalSince(lastActive) >= Self.sessionTimeoutInterval {
            // End old session, start new one
            eventTracker.track(event: "session_end", properties: nil)
            startNewSession()
        }

        eventTracker.track(event: "app_open", properties: nil)
        updateLastActive()
    }

    @objc func appDidEnterBackground() {
        Self.foregroundLock.lock(); Self.appOpenSentThisForeground = false; Self.foregroundLock.unlock()
        eventTracker.track(event: "app_close", properties: nil)
        updateLastActive()
    }
}
