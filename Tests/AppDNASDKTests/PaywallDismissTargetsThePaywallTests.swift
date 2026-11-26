// PaywallDismissTargetsThePaywallTests.swift
//
// the SDK's post-purchase dismiss closes THE PAYWALL, never the screen it was presented from.
//
// The setup, in a real key window: a root screen presents a MODAL host screen, and that screen presents the paywall. The
// host then closes the paywall itself, which is what a host following the old docs does in onPaywallPurchaseCompleted.
// After that, the SDK's dismiss must leave the host's modal screen up, and its completion must still run, so
// `onPaywallDismissed` and an onboarding route still fire. RED CONTROL, on the same harness: the old call,
// `presenter.dismiss(animated:)`, closes the host's modal screen. That is the defect, measured here as well as on the
// iOS 1.0.91 simulator walk.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UIKit
@testable import AppDNASDK

final class PaywallDismissTargetsThePaywallTests: XCTestCase {
    private func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    override func setUp() { super.setUp(); UIView.setAnimationsEnabled(false) }
    override func tearDown() { UIView.setAnimationsEnabled(true); super.tearDown() }

    /// root → modal host screen → paywall in a real key window. A window with no scene runs no transition animation, so
    /// animations are off and the live `animated: true` calls complete at once (as ConfigMessageBackgroundLaunchTests).
    private func stack() throws -> (UIWindow, root: UIViewController, modal: UIViewController, paywall: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        let modal = UIViewController(); modal.modalPresentationStyle = .pageSheet
        root.present(modal, animated: true); spin(0.6)
        let paywall = UIViewController(); paywall.modalPresentationStyle = .fullScreen
        modal.present(paywall, animated: true); spin(0.6)
        try XCTSkipUnless(root.presentedViewController === modal && modal.presentedViewController === paywall,
            "this host cannot build a present stack; the simulator walk covers the real close")
        return (window, root, modal, paywall)
    }

    func testTheHostClosedThePaywall_theSDKDismissLeavesTheHostModalUp_andStillCompletes() throws {
        let (window, root, modal, paywall) = try stack(); defer { window.isHidden = true }
        modal.dismiss(animated: true); spin(0.6) // the host closes the paywall itself
        XCTAssertNil(modal.presentedViewController)
        var completed = 0
        PaywallDismissal.dismiss(paywall: paywall, presenter: modal ) { completed += 1 }
        spin(0.8)
        XCTAssertTrue(root.presentedViewController === modal, "the SDK dismissed the host's own modal screen")
        XCTAssertEqual(completed, 1, "the completion (onPaywallDismissed / onboarding route) must still run once")
    }

    func testThePaywallIsStillUp_theSDKDismissClosesOnlyThePaywall() throws {
        let (window, root, modal, paywall) = try stack(); defer { window.isHidden = true }
        var completed = 0
        PaywallDismissal.dismiss(paywall: paywall, presenter: modal ) { completed += 1 }
        spin(0.8)
        XCTAssertNil(modal.presentedViewController, "the paywall is closed")
        XCTAssertTrue(root.presentedViewController === modal, "and the host's modal screen is not")
        XCTAssertEqual(completed, 1)
    }

    func testNoPaywallReference_fallsBackToWhatThePresenterPresented() throws {
        let (window, root, modal, _) = try stack(); defer { window.isHidden = true }
        modal.dismiss(animated: true); spin(0.6)
        var completed = 0
        PaywallDismissal.dismiss(paywall: nil, presenter: modal ) { completed += 1 }
        spin(0.8)
        XCTAssertTrue(root.presentedViewController === modal, "with nothing presented, the presenter is not dismissed")
        XCTAssertEqual(completed, 1)
    }

    /// RED CONTROL: what every branch did before this fix.
    func testRedControl_theOldPresenterDismissClosesTheHostModal() throws {
        let (window, root, modal, _) = try stack(); defer { window.isHidden = true }
        modal.dismiss(animated: true); spin(0.6)
        modal.dismiss(animated: true) // the old SDK call, `viewController.dismiss(animated:)`
        spin(0.8)
        XCTAssertNil(root.presentedViewController, "harness: the old call is expected to close the host's modal screen")
    }
}
