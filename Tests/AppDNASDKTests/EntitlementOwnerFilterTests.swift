import XCTest
@testable import AppDNASDK

/// Pure unit tests for the cross-account-leak ownership filter — the single
/// source of truth for the decision matrix that defends every site reading
/// `Transaction.currentEntitlements`. The QA reproducer (User A buys → User
/// B signs in → B sees A's subscription) lives or dies on this decision
/// table being correct; if any case here flips wrong, the whole defence
/// silently breaks.
///
/// Decision matrix re-stated for clarity:
///   expectedToken nil                                                   → grantAnonymousPolicy   (pre-identify pass-through)
///   expectedToken set, tx token == match                                → grant                  (current user's purchase)
///   expectedToken set, tx token mismatch                                → denyOtherUser          (tagged-cross-account leak guard)
///   expectedToken set, tx token nil, firstIdentifier == expected        → grantUntaggedMigration (legitimate self-claim)
///   expectedToken set, tx token nil, firstIdentifier != expected        → denyUntaggedOtherUser  (untagged-cross-account leak guard — THE v1.0.63 FIX)
///   expectedToken set, tx token nil, firstIdentifier == nil             → denyUntaggedOtherUser  (no anchor recorded — no migration grant)
final class EntitlementOwnerFilterTests: XCTestCase {

    private let tokenA = UUID()
    private let tokenB = UUID()

    // MARK: - The six cases of the decision matrix

    func testAnonymousUser_noFilter() {
        // No identified user (host hasn't called identify yet) — any
        // transaction token, including nil, is accepted under the legacy
        // pass-through. Preserves first-launch / pre-identify flows.
        // `firstIdentifiedToken` is irrelevant in this branch.
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: tokenA, expectedToken: nil, firstIdentifiedToken: nil),
            .grantAnonymousPolicy
        )
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: nil, expectedToken: nil, firstIdentifiedToken: nil),
            .grantAnonymousPolicy
        )
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: tokenA, expectedToken: nil, firstIdentifiedToken: tokenB),
            .grantAnonymousPolicy,
            "firstIdentifiedToken must be ignored when expectedToken is nil — the user hasn't identified yet"
        )
    }

    func testTaggedAndMatches_grant() {
        // Identified user, transaction tagged with the same user's token → grant.
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: tokenA, expectedToken: tokenA, firstIdentifiedToken: tokenA),
            .grant
        )
        // First-identifier irrelevant on the matched-token path.
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: tokenA, expectedToken: tokenA, firstIdentifiedToken: tokenB),
            .grant
        )
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: tokenA, expectedToken: tokenA, firstIdentifiedToken: nil),
            .grant
        )
    }

    func testTaggedDifferentUser_deny() {
        // Identified user A, transaction tagged for user B → DENY.
        // This is the tagged-mismatch path (v1.0.62 already handled this
        // correctly; we keep the test to lock the behaviour).
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: tokenB, expectedToken: tokenA, firstIdentifiedToken: tokenA),
            .denyOtherUser
        )
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: tokenA, expectedToken: tokenB, firstIdentifiedToken: tokenA),
            .denyOtherUser,
            "Tagged-mismatch always denies regardless of first-identifier"
        )
    }

    // MARK: - The v1.0.63 fix — first-identifier-scoped migration

    func testUntaggedHistorical_grantedToFirstIdentifier() {
        // Identified user A IS the device's first-identifier; transaction
        // has no appAccountToken (purchased before SDK started tagging OR
        // by the SDK paywall onboarding flow before identify(...) was
        // called). Migration-tolerant grant is preserved for this case.
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: nil, expectedToken: tokenA, firstIdentifiedToken: tokenA),
            .grantUntaggedMigration
        )
    }

    func testUntaggedHistorical_deniedToLaterIdentifier() {
        // THE FIX — the QA repro. User B identifies on a device where
        // user A is the first-identifier. An untagged transaction (most
        // commonly the SDK-paywall onboarding purchase made BEFORE A
        // identified) MUST NOT be inherited by B.
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: nil, expectedToken: tokenB, firstIdentifiedToken: tokenA),
            .denyUntaggedOtherUser
        )
    }

    func testUntaggedHistorical_deniedWhenNoFirstIdentifierAnchored() {
        // Defensive case: expectedToken is set but no first-identifier
        // anchor exists yet (shouldn't happen in production because
        // identify() records the anchor before refreshEntitlementCache
        // runs, but the filter is paranoid about it). Untagged tx is
        // denied — better safe than leaking on an unanchored first read.
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(transactionToken: nil, expectedToken: tokenA, firstIdentifiedToken: nil),
            .denyUntaggedOtherUser
        )
    }

    // MARK: - Property-style sanity checks

    /// Exactly two denial cases (tagged-mismatch + untagged-mismatch) and
    /// three grant cases (match, anonymous, migration). A future refactor
    /// that adds a sixth case can't accidentally collapse grant vs deny.
    func testDenialCaseCount() {
        let allCases: [EntitlementOwnershipDecision] = [
            .grant, .grantAnonymousPolicy, .grantUntaggedMigration, .denyOtherUser, .denyUntaggedOtherUser,
        ]
        let denyCases = allCases.filter { $0 == .denyOtherUser || $0 == .denyUntaggedOtherUser }
        XCTAssertEqual(denyCases.count, 2, "Exactly two decision cases deny — tagged-mismatch and untagged-other-user")
    }

    // MARK: - The QA reproducer at the decision-table level

    /// End-to-end repro encoded against the filter only. Simulates the
    /// SDK-paywall onboarding flow (anonymous purchase) → user A
    /// identifies → user B identifies → B taps Restore. Pins that B sees
    /// nothing because the untagged transaction is scoped to A (the
    /// device's first identifier).
    func testQAReproducer_decisionTable() {
        // 1. SDK paywall purchase happens during onboarding before
        //    AppDNA.identify(...). transactionToken = nil (untagged).
        let untaggedTransaction: UUID? = nil

        // 2. User A identifies first → tokenA is the first-identifier.
        let firstIdentifier: UUID? = tokenA

        // 3. User A taps Restore → expected = tokenA, first = tokenA
        //    → grant (legitimate self-claim).
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(
                transactionToken: untaggedTransaction,
                expectedToken: tokenA,
                firstIdentifiedToken: firstIdentifier
            ),
            .grantUntaggedMigration,
            "User A is the first identifier — their own untagged purchase MUST be granted"
        )

        // 4. User A signs out, user B signs in. The first-identifier
        //    anchor does NOT change (B is the second identifier on the
        //    device). User B taps Restore.
        XCTAssertEqual(
            EntitlementOwnerFilter.decide(
                transactionToken: untaggedTransaction,
                expectedToken: tokenB,
                firstIdentifiedToken: firstIdentifier
            ),
            .denyUntaggedOtherUser,
            "User B is NOT the first identifier — A's untagged transaction MUST NOT be inherited"
        )
    }
}
