import Foundation

/// The destination a `link_on_complete` CTA asked for, held until the flow finishes.
///
/// The case it exists for: a cross-sell near the end of a flow ("book a wine tasting"). Opening the
/// destination when the CTA is tapped tears the user out of a flow they have not finished — the
/// reason the `flag` CTA advances instead of routing. So the tap records where to go, the user
/// continues, and the SDK opens it once the flow is genuinely complete.
///
/// Deliberately NOT stored in `responses`: that map is what customer webhooks receive and what
/// `onOnboardingCompleted` hands the host, and it must stay byte-identical for anyone not using
/// this feature. A CTA destination is SDK plumbing, not an answer the user gave.
///
/// SINGLE-SHOT, and that is the point. `take()` reads and clears, so a recorded route can fire at
/// most once. Without that, a route recorded in a flow the user then ABANDONED would still be
/// sitting here when some later flow completed, and the app would navigate somewhere the user
/// never asked to go — a bug that would surface as "the app randomly opens booking".
final class PendingCompletionRoute: @unchecked Sendable {
    /// The `action` value the console writes and every SDK switches on.
    static let actionName = "link_on_complete"

    static let shared = PendingCompletionRoute()

    private let lock = NSLock()
    private var url: String?

    private init() {}

    /// Record where to go when the flow finishes. A second tap replaces the first — the user's
    /// latest choice is the one that counts.
    func record(_ raw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        url = raw
    }

    /// Read and clear. Returns nil when no CTA asked for a destination.
    func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        let out = url
        url = nil
        return out
    }

    /// Drop anything recorded. Called when a flow is PRESENTED, so a destination left behind by an
    /// abandoned flow cannot leak into the next one.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        url = nil
    }
}
