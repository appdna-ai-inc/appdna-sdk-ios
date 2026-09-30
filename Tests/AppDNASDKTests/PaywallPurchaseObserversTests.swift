// PaywallPurchaseObserversTests.swift
//
// SPEC-497 round 11 — `PaywallRenderer`'s post-purchase observers live exactly as long as the view.
// They used to be removed in `.onDisappear`, which also fires while a host full-screen cover hides the
// paywall: a `.paywallPurchaseEnded` posted then reached no one and the CTA stayed spinning. The holder has
// no "disappear" path at all — only `deinit` removes the observers.

import XCTest
@testable import AppDNASDK

final class PaywallPurchaseObserversTests: XCTestCase {
    private var center: NotificationCenter!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
    }

    private func register(_ holder: PaywallPurchaseObservers,
                          success: @escaping () -> Void = {},
                          ended: @escaping () -> Void = {},
                          failure: @escaping () -> Void = {}) {
        holder.register(onSuccess: { _ in success() }, onEnded: { _ in ended() }, onFailure: { _ in failure() })
    }

    /// A post made at any point while the holder is alive (e.g. while a cover hides the paywall) still resets
    /// the CTA: both the ended and the failure paths are delivered.
    func testPostsReachTheBlocksForAsLongAsTheHolderLives() {
        let holder = PaywallPurchaseObservers(center: center)
        let ended = expectation(description: "ended delivered")
        let failed = expectation(description: "failure delivered")
        register(holder, ended: { ended.fulfill() }, failure: { failed.fulfill() })
        XCTAssertEqual(holder.registeredCount, 3)

        center.post(name: .paywallPurchaseEnded, object: nil)
        center.post(name: .paywallPurchaseFailure, object: nil, userInfo: ["message": "x"])
        wait(for: [ended, failed], timeout: 2)
    }

    /// The observers are removed at `deinit` — the I4 m3 leak stays fixed. NEGATIVE CONTROL: without the
    /// `removeAll()` in `deinit`, the block-based observers outlive the holder and this post is delivered.
    func testObserversAreRemovedAtDeinit() {
        var holder: PaywallPurchaseObservers? = PaywallPurchaseObservers(center: center)
        weak var weakHolder = holder
        let notDelivered = expectation(description: "nothing delivered after deinit")
        notDelivered.isInverted = true
        notDelivered.expectedFulfillmentCount = 3 // one per post: a leak fails cleanly, not as an API violation
        register(holder!, success: { notDelivered.fulfill() }, ended: { notDelivered.fulfill() },
                 failure: { notDelivered.fulfill() })
        holder = nil
        XCTAssertNil(weakHolder, "the blocks must not keep the holder alive")

        center.post(name: .paywallPurchaseSuccess, object: nil)
        center.post(name: .paywallPurchaseEnded, object: nil)
        center.post(name: .paywallPurchaseFailure, object: nil)
        wait(for: [notDelivered], timeout: 0.5)
    }

    /// A repeated `onAppear` replaces the observers rather than stacking a second set.
    func testRegisterAgainReplacesTheObservers() {
        let holder = PaywallPurchaseObservers(center: center)
        let first = expectation(description: "first set not delivered")
        first.isInverted = true
        let second = expectation(description: "second set delivered once")
        second.expectedFulfillmentCount = 1
        second.assertForOverFulfill = true
        register(holder, ended: { first.fulfill() })
        register(holder, ended: { second.fulfill() })
        XCTAssertEqual(holder.registeredCount, 3)

        center.post(name: .paywallPurchaseEnded, object: nil)
        wait(for: [first, second], timeout: 0.5)
    }
}
