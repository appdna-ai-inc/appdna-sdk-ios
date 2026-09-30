import Foundation

/// 🔴 EVERY `expiresAt` FROM THE SERVER PARSED TO `nil`.
///
/// The server sends `Date.toISOString()` — `2026-07-14T10:00:00.000Z`, WITH fractional seconds. A bare
/// `ISO8601DateFormatter()` does not set `.withFractionalSeconds`, and without it the parse of a
/// fractional timestamp returns nil. Not "sometimes": every time, for every entitlement, on every build.
///
/// So the one code path that DID read an expiry threw it away, while the other
/// (`BillingModule.getEntitlements`) hard-coded nil. Between them, `Entitlement.expiresAt` was
/// unreachable — a public field of a public type that could not hold a value.
///
/// Tries fractional first (what our server actually sends), then plain (what a store or a hand-written
/// fixture might send). One parser, one place, both spellings.
enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    /// The server's own spelling (`Date.toISOString()`, fractional seconds, UTC) — used when a local
    /// StoreKit expiry rides in the same `ServerEntitlement.expiresAt` field a server one does.
    static func string(from date: Date) -> String {
        fractional.string(from: date)
    }
}
