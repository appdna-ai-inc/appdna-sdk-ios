// StoreTrialEligibilityHostedTests.swift — #933 / #934
//
// THE PARKED PROOF, RUN. This is `Tests/AppDNASDKTests/StoreTrialEligibilitySessionTests.swift`
// moved into an APP-HOSTED test target, which is the one thing it was waiting for.
//
// #933 held itself open on a state a sandbox account cannot be put into on demand: a user who has
// ALREADY used the trial. `SKTestSession` can manufacture it — its transaction history is what
// `isEligibleForIntroOffer` is computed from — but `buyProduct(identifier:)` fails with an unknown
// StoreKit error in the package's HOSTLESS test target, so the test could only skip with its
// reason.
//
// 🔴 The limitation was the TARGET, not the API. A throwaway probe in this same target measured it
// — `buyProduct` succeeds inside an app process — and was then DELETED, for a reason worth keeping:
//
// 🔴 TWO `SKTestSession`s IN ONE PROCESS INTERFERE, and it nearly cost a filed defect. With the
// probe present this test reported a trial surviving a consumed offer, which reads exactly like the
// SDK ignoring eligibility. Asking StoreKit directly separated the two: alone, it answers
// `isEligibleForIntroOffer = false` and this test passes; with a second session in the process it
// answers `true`, meaning the purchase never took effect and the SDK was right all along.
//
// 🔴 AND THE FLAG DOES NOT SETTLE AT THE MOMENT `buyProduct` RETURNS. Read once, immediately, it
// came back ineligible in 2 of 7 runs; the other 5 were reading a transaction store that had not
// caught up, which is indistinguishable from a purchase that failed. `waitUntilIneligible` polls a
// freshly fetched product instead, and that is 5 of 5 — with the eligibility check removed from
// `StorePriceLookup` the same 5 runs fail on `"P1W" - the trial survived`, so the instrument
// discriminates.
//
// So this target holds ONE session-based test. A second one must not simply be added beside it —
// it needs its own process, or the first will quietly invalidate it.
//
// The original file stays in `Tests/AppDNASDKTests/`, skipping on the hostless target, as the
// honest record of why it could not run there.
//
// THE STATE THAT CANNOT OCCUR ON DEMAND, MANUFACTURED.
//
// #933 held itself open on one sentence: the only state where a wrong trial implementation is
// visible is a store account **that has already used the trial**. On a fresh account every
// implementation looks correct, including one with no eligibility check at all — which is exactly
// the shape of defect that reaches production believing it is covered.
//
// A sandbox account with a consumed trial is not something this session can create. `SKTestSession`
// IS: its transaction history is the thing `isEligibleForIntroOffer` is computed from, so buying
// the subscription inside the session consumes the introductory offer and the SAME product answers
// false afterwards. That is Rule 18's probe pattern — if the state cannot occur naturally,
// manufacture it.
//
// 🔴 THE PRODUCTION PATH IS CALLED, NOT RE-IMPLEMENTED. `StorePriceLookup.facts` is what the
// presenter uses, and its `trialIso` is nil-ed behind the eligibility flag. A test that asked
// StoreKit for eligibility itself and asserted on THAT would agree with any implementation,
// including one that never consults it.
//
// 🔴 AND THE FIRST ASSERTION IS THE CONTROL. "No trial after the purchase" passes against an SDK
// that never returns a trial at all, so the eligible case has to be measured first, in the same
// run, from the same product.
import XCTest
import StoreKit
import StoreKitTest
@testable import AppDNASDK

final class StoreTrialEligibilityHostedTests: XCTestCase {

    /// The `.storekit` product that carries a free P1W introductory offer.
    private let trialProduct = "ai.appdna.test.monthly_trial"

    private var session: SKTestSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        /*
         🔴 NOT `Bundle.module`. This target is an app-hosted XCTest bundle, not an SPM module, so
         there is no generated resource bundle — the catalogue ships inside the HOST app and is
         found through the test bundle first, then the host's.
         */
        guard let url = Bundle(for: Self.self).url(forResource: "AppDNATestProducts", withExtension: "storekit")
            ?? Bundle.main.url(forResource: "AppDNATestProducts", withExtension: "storekit") else {
            throw XCTSkip("AppDNATestProducts.storekit is in neither the test nor the host bundle")
        }
        do {
            session = try SKTestSession(contentsOf: url)
        } catch {
            throw XCTSkip("SKTestSession cannot run in this (hostless) test target: \(error)")
        }
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session?.clearTransactions()
        super.tearDown()
    }

    /// StoreKit's OWN answer for `trialProduct`, re-fetching the product each time.
    ///
    /// 🔴 RE-FETCHED, NOT RE-READ. `isEligibleForIntroOffer` hangs off a `Product` value that was
    /// resolved at a point in time; asking the same instance again can return the same answer it
    /// already computed. The product has to come back from `Product.products(for:)` on every
    /// attempt or this poll would spin on a cached `true` until it timed out.
    private func storeSaysEligible() async throws -> Bool? {
        let products = try await Product.products(for: [trialProduct])
        guard let sub = products.first?.subscription else { return nil }
        return await sub.isEligibleForIntroOffer
    }

    /// Wait for a consumed introductory offer to become visible to `isEligibleForIntroOffer`.
    ///
    /// 🔴 THE WRITE AND THE COMPUTATION ARE NOT THE SAME MOMENT. `SKTestSession.buyProduct` returns
    /// as soon as the transaction is written, and eligibility is derived from the transaction store
    /// by a separate asynchronous path. Reading the flag ONCE, immediately, measured 2 of 7 runs
    /// ineligible — the other 5 were reading a store that had not caught up yet, which looks
    /// exactly like a purchase that failed. Polling turns that into a deterministic answer.
    private func waitUntilIneligible(attempts: Int = 40, gapMs: UInt64 = 250) async throws -> Bool? {
        var last: Bool?
        for _ in 0..<attempts {
            last = try await storeSaysEligible()
            if last == false { return false }
            try await Task.sleep(nanoseconds: gapMs * 1_000_000)
        }
        return last
    }

    /// `StorePriceLookup.facts` — the production call — resolved once, awaitable.
    ///
    /// A continuation rather than an `XCTestExpectation`, because the purchase below is `async` and
    /// `wait(for:)` inside an async test deadlocks the cooperative pool on this toolchain.
    private func facts(timeout: TimeInterval = 10) async -> [String: StorePriceLookup.StoreFacts] {
        await withCheckedContinuation { continuation in
            StorePriceLookup.facts(for: [trialProduct], timeout: timeout) { facts in
                continuation.resume(returning: facts)
            }
        }
    }

    func testTheTrialDisappearsOnceTheUserHasUsedIt() async throws {
        /*
         * 🔴 `SKTestSession.buyProduct(identifier:)` is iOS 17+. Below that the state cannot be
         * manufactured here at all, and the honest answer is a skip rather than a weaker assertion
         * — the whole point of this test is the state a fresh account cannot be in.
         */
        guard #available(iOS 17.0, macOS 14.0, *) else {
            throw XCTSkip("SKTestSession.buyProduct needs iOS 17; this runner is older")
        }

        // 1. The control: a fresh session IS eligible, so the SDK reports the store's trial.
        let before = await facts()
        let eligible = try XCTUnwrap(
            before[trialProduct],
            "the store returned nothing for \(trialProduct) — the catalogue did not load, so neither "
                + "half of this test means anything",
        )
        XCTAssertEqual(
            eligible.trialIso, "P1W",
            "a fresh account is eligible for the .storekit product's free P1W offer and the SDK must "
                + "report it — without this the second assertion passes against an SDK that never "
                + "returns a trial at all",
        )

        // 2. Consume the introductory offer. `SKTestSession.buyProduct` writes the transaction
        //    directly, which is what makes this workable in the hostless target where
        //    `Product.purchase()` fails on this bridge (see StoreKitSessionTests.probePurchasesWork).
        do {
            try await session.buyProduct(identifier: trialProduct)
        } catch {
            throw XCTSkip("SKTestSession.buyProduct is unavailable in this target: \(error)")
        }

        /*
         🔴 ASK STOREKIT DIRECTLY FIRST — a control for the INSTRUMENT, not for the SDK.
         *
         If the SDK still reports a trial after the purchase, there are two very different causes:
         the SDK does not consult eligibility, or `SKTestSession.buyProduct` did not actually make
         this user ineligible. Only the first is a defect; the second means this test's premise is
         wrong and it proves nothing. Reading the flag StoreKit itself exposes distinguishes them,
         and printing it means the answer is in the log either way.
         */
        let stillEligible = try await waitUntilIneligible()
        print("[#933] StoreKit isEligibleForIntroOffer AFTER buyProduct = \(stillEligible as Any)")

        /*
         🔴 SKIP RATHER THAN FAIL WHEN THE STATE DID NOT TAKE. StoreKit saying the user is STILL
         eligible after the wait above means `buyProduct` never reached the eligibility computation
         — the state this test exists to manufacture was not manufactured, so the assertion below
         would be measuring the harness and calling it an SDK defect. That distinction cost a
         nearly-filed defect once already (see this file's header), so it is a skip with its reason
         rather than a failure.
         */
        try XCTSkipIf(
            stillEligible != false,
            "SKTestSession.buyProduct did not make this user ineligible within the wait — StoreKit "
                + "still reports isEligibleForIntroOffer = \(stillEligible as Any), so the ineligible "
                + "state was NOT manufactured and anything asserted past here would be about the "
                + "harness. The SDK is not implicated.",
        )

        // 3. The state the sandbox account could not be put into: the SAME product, same lookup,
        //    this user no longer eligible.
        let after = await facts()
        let used = try XCTUnwrap(after[trialProduct], "the product vanished from the catalogue after the purchase")
        XCTAssertNil(
            used.trialIso,
            "the trial survived a consumed introductory offer — the paywall would promise a free "
                + "trial the purchase sheet refuses, which is the defect #933 held itself open for",
        )
        // And the price is still reported, so this is eligibility being read rather than the
        // whole lookup having failed.
        XCTAssertNotNil(used.price, "the price went with it — the lookup broke rather than the eligibility changing")
    }
}
