// StoreTrialEligibilitySessionTests.swift
//
// THE STATE THAT CANNOT OCCUR ON DEMAND, MANUFACTURED.
//
// The trial-eligibility proof rests on one sentence: the only state where a wrong trial implementation is
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

final class StoreTrialEligibilitySessionTests: XCTestCase {

    /// The `.storekit` product that carries a free P1W introductory offer.
    private let trialProduct = "ai.appdna.test.monthly_trial"

    private var session: SKTestSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let url = Bundle.module.url(forResource: "AppDNATestProducts", withExtension: "storekit") else {
            throw XCTSkip("AppDNATestProducts.storekit is not in the test bundle")
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

        // 3. The state the sandbox account could not be put into: the SAME product, same lookup,
        //    this user no longer eligible.
        let after = await facts()
        let used = try XCTUnwrap(after[trialProduct], "the product vanished from the catalogue after the purchase")
        XCTAssertNil(
            used.trialIso,
            "the trial survived a consumed introductory offer — the paywall would promise a free "
                + "trial the purchase sheet refuses, which is the defect this test exists for",
        )
        // And the price is still reported, so this is eligibility being read rather than the
        // whole lookup having failed.
        XCTAssertNotNil(used.price, "the price went with it — the lookup broke rather than the eligibility changing")
    }
}
