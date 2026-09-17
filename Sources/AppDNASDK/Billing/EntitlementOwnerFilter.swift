import Foundation

/// Outcome of a per-transaction ownership check against the currently
/// identified user. Returned from `EntitlementOwnerFilter.decide(...)`.
enum EntitlementOwnershipDecision: Equatable {
    /// Transaction is bound to the current user — grant.
    case grant
    /// Transaction belongs to a different identified user — DENY
    /// (cross-account leak guard, tagged-mismatch path).
    case denyOtherUser
    /// Untagged historical transaction AND the current user matches the
    /// first-identifier recorded on this device — grant under the
    /// migration-tolerant "first-identifier-claims-untagged-history"
    /// policy. The caller is expected to surface this to the server-side
    /// receipt-verifier so the backend can claim ownership and prevent
    /// silent re-grant on a later user switch.
    case grantUntaggedMigration
    /// Untagged historical transaction but the current user is NOT the
    /// first-identifier recorded on this device — DENY (cross-account
    /// leak guard, untagged-mismatch path). This is the case that closes
    /// the original v1.0.62 leak in flows where the SDK paywall purchases
    /// fire BEFORE the host calls `AppDNA.identify(...)` (e.g. onboarding
    /// paywalls): the resulting untagged transaction now belongs to the
    /// first user who identifies on the device and no other user can
    /// inherit it.
    case denyUntaggedOtherUser
    /// No identified user — fall back to no ownership filter (pre-`identify`
    /// flows like first-launch "Restore" before any user is established).
    case grantAnonymousPolicy
}

/// Pure, fully-unit-testable ownership filter used by every site that reads
/// `Transaction.currentEntitlements`. The decision matrix below is the single
/// source of truth for the SDK's cross-account-entitlement-leak defence.
///
/// Decision matrix:
/// ```
///   expectedToken  | tx.appAccountToken | firstIdentifiedToken             | decision
///   ───────────────┼────────────────────┼──────────────────────────────────┼───────────────────────
///   nil            | any                | any                              | grantAnonymousPolicy
///   set            | == expectedToken   | any                              | grant
///   set            | != expectedToken   | any                              | denyOtherUser
///   set            | nil                | == expectedToken (self-claim)    | grantUntaggedMigration
///   set            | nil                | != expectedToken (other-claim)   | denyUntaggedOtherUser
///   set            | nil                | nil (no firstIdentifier yet)     | denyUntaggedOtherUser
/// ```
///
/// **Why the first-identifier scope on untagged grants**: in v1.0.62 we
/// granted every untagged transaction to whoever happened to be identified
/// at read time (`grantUntaggedMigration` unconditional). That carve-out was
/// designed for one-time legacy migration from pre-v1.0.62 builds, but in
/// SDK-driven onboarding flows where the paywall fires before the host's
/// `identify(...)` call, the resulting transaction is ALWAYS untagged — so
/// every other-user restore on the same device inherited it (the
/// cross-account leak QA reproduced). Scoping the untagged-grant to the
/// first userId ever identified on this device keeps the legacy migration
/// path intact while denying cross-account inheritance for everyone else.
///
/// The "anonymous" branch preserves pre-identify behaviour (a host that calls
/// `restorePurchases` before any user has identified gets every transaction
/// the device knows about — same as before this fix). Once the host calls
/// `AppDNA.identify(...)`, the filter is armed and the per-user binding is
/// enforced on every subsequent read.
///
/// Server-side enforcement (`receiptVerifier.restore/verify` — see
/// `ReceiptVerifier.swift`) is the PRIMARY defence; this client-side filter
/// is a belt-and-suspenders layer for the cached/silent paths
/// (`refreshEntitlementCache` and the bridge's `getEntitlements`/`restore`
/// shortcuts that don't always round-trip the verifier).
enum EntitlementOwnerFilter {

    /// Apply the decision matrix above to a single transaction's token.
    ///
    /// `firstIdentifiedToken` defaults to `nil` to preserve source-compat for
    /// any call site that hasn't been updated yet — but doing so falls into
    /// the strict `denyUntaggedOtherUser` branch for untagged transactions
    /// (i.e. no migration grant unless the caller actively threads the
    /// first-identifier through). All shipped call sites pass it explicitly.
    static func decide(
        transactionToken: UUID?,
        expectedToken: UUID?,
        firstIdentifiedToken: UUID? = nil
    ) -> EntitlementOwnershipDecision {
        guard let expected = expectedToken else { return .grantAnonymousPolicy }
        if let txToken = transactionToken {
            return txToken == expected ? .grant : .denyOtherUser
        }
        // Untagged: only the first-identifier on this device may claim
        // historical untagged transactions. Any other identified user is
        // denied (this is the cross-account-leak close for onboarding-
        // paywall flows that purchase before identify()).
        if let first = firstIdentifiedToken, first == expected {
            return .grantUntaggedMigration
        }
        return .denyUntaggedOtherUser
    }
}
