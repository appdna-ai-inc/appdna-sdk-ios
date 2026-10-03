import XCTest
@testable import AppDNASDK

/**
 *"a paywall with NO delegate REJECTS a non-blank promo code — on both
 platforms."*

 🔴 The bug this guards is a REVENUE path. A paywall presented with no `AppDNAPaywallDelegate` ran

     updateState(code.isNotBlank() ? "success" : "error")

 so ANY non-blank string the user typed rendered "Code applied!", and the CTA path then folded that
 unvalidated string into the purchase metadata as `promo_code` — reaching the backend looking exactly
 like a code the app had validated. Nobody had validated it. The SDK cannot: only the host can.

 Android has proven this since the fix landed, with a Compose UI test driving the real renderer
 (`PromoCodeFallbackTest.kt` — "no delegate - a non-blank code is REJECTED, not silently applied").
 iOS shipped the same fix and asserted NOTHING about it: the decision was inline in a SwiftUI `Button`
 action inside a `@ViewBuilder`, which nothing in this test target can reach. "Android is right" is
 not evidence about Swift — the two renderers are separate hand-written code, and this exact branch
 was wrong on both.

 (`AppdnaPromoDefaultTests.swift` in the React Native wrapper tests the WRAPPER's veto default — what
 the bridge answers when JS never replies. A different thing entirely: it says nothing about what the
 renderer does when there is no delegate at all.)

 The decision now lives in `PaywallRenderer.resolvePromoSubmission`, which is what the button calls
 and all it calls. These tests drive that function, so they exercise the branch that ships.
 */
final class PromoCodeFallbackTests: XCTestCase {

    /// Drive the real decision and collect every state it transitions through.
    private func submit(
        _ code: String,
        onPromoCodeSubmit: ((String, @escaping (Bool) -> Void) -> Void)?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [PromoState] {
        var states: [PromoState] = []
        let done = expectation(description: "promo submission settles")
        // The delegate path answers on `DispatchQueue.main`; the no-delegate path answers inline. Both
        // must reach a terminal state, and a test that only worked for one of them would be worthless.
        PaywallRenderer.resolvePromoSubmission(code: code, onPromoCodeSubmit: onPromoCodeSubmit) { state in
            states.append(state)
            if state != .loading { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        return states
    }

    // MARK: - No delegate

    func testNoDelegateRejectsANonBlankCode() {
        let states = submit("TOTALLY-MADE-UP", onPromoCodeSubmit: nil)

        XCTAssertEqual(
            states.last, .error,
            "a code no host validated is not a valid code — it must not be accepted"
        )
        XCTAssertFalse(
            states.contains(.success),
            "the paywall reported SUCCESS for an unvalidated code; the CTA then sends it as `promo_code`"
        )
    }

    func testNoDelegateRejectionDoesNotDependOnTheCode() {
        // The original fallback's whole logic was `isNotBlank()`, so the code's CONTENT decided the
        // answer. It must not: with no delegate there is nothing that could tell one code from another.
        for code in ["SAVE90", "a", "FREE-FOREVER", "🎉"] {
            XCTAssertEqual(
                submit(code, onPromoCodeSubmit: nil).last, .error,
                "\(code) was accepted with no delegate to validate it"
            )
        }
    }

    func testNoDelegateBlankCodeIsAlsoAnError() {
        XCTAssertEqual(submit("", onPromoCodeSubmit: nil).last, .error)
    }

    // MARK: - With a delegate (the guard against "fixing" this by hard-coding rejection)

    func testDelegateSaysValidTheCodeIsApplied() {
        // The host validated it, so success is legitimate. Without this, the whole feature could be
        // "fixed" by always rejecting and the suite would not notice.
        let states = submit("REAL-CODE", onPromoCodeSubmit: { _, completion in completion(true) })
        XCTAssertEqual(states.last, .success)
        XCTAssertFalse(states.contains(.error))
    }

    func testDelegateSaysInvalidTheCodeIsRejected() {
        XCTAssertEqual(
            submit("BAD-CODE", onPromoCodeSubmit: { _, completion in completion(false) }).last,
            .error
        )
    }

    func testTheDelegateReceivesTheCodeTheUserTyped() {
        var seen: [String] = []
        _ = submit("SAVE20", onPromoCodeSubmit: { code, completion in
            seen.append(code)
            completion(true)
        })
        XCTAssertEqual(seen, ["SAVE20"])
    }

    func testAHostAnsweringOffTheMainThreadStillSettles() {
        // `promoState` drives SwiftUI, so the answer has to land on the main queue. A host validating
        // a code against its own backend answers on a URLSession queue — the common case, and the one
        // that would otherwise mutate view state off-main.
        let states = submit("ASYNC-CODE", onPromoCodeSubmit: { _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { completion(true) }
        })
        XCTAssertEqual(states.last, .success)
    }

    // MARK: - The state the CTA reads

    func testOnlySuccessCanPutAPromoCodeIntoPurchaseMetadata() {
        // `handlePurchase` gates on `!promoCode.isEmpty && promoState == .success` before writing
        // `metadata["promo_code"]`. That guard is the second half of the bug: the first half made
        // `.success` reachable with no validation, and this is what it then unlocked. Pinning the
        // relation keeps a future "let's show a friendlier state" refactor from re-opening it.
        XCTAssertNotEqual(PromoState.error, .success)
        XCTAssertNotEqual(PromoState.idle, .success)
        XCTAssertNotEqual(PromoState.loading, .success)

        // And the no-delegate path can never reach the one state that unlocks it.
        XCTAssertFalse(submit("ANY", onPromoCodeSubmit: nil).contains(.success))
    }
}
