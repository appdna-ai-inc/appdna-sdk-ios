// PresentableHostTests.swift — #1078
//
// A PAYWALL THAT DOES NOT PRESENT EARNS NOTHING, AND NOBODY WAS TOLD.
//
// `AppDNA.showPaywall` resolved `topViewController()` synchronously and `presentPaywall` then
// dispatched the presentation onto the main queue. In between, that controller could begin
// dismissing or start presenting something else — and UIKit refuses `present(_:animated:)` on such
// a controller by logging and doing nothing. The completion never runs, so `onPaywallPresented`
// never fires, and the caller was already told `true`.
//
// Measured in 2 of 2 stress runs of the plan-selection walk: twelve taps over sixty seconds with
// no paywall, in a process that had already presented the same paywall about twenty times.
//
// 🔴 THIS TESTS THE CHOICE, NOT THE PRESENTATION. Driving a real refused `present` needs a window
// mid-transition, which a test cannot hold still; what it CAN do is put a controller into each
// state UIKit refuses and assert the SDK stops choosing it. The presentation itself is covered by
// the walk, which is where the defect was measured.
//
// 🔴 AND IT LIVES IN THE APP-HOSTED TARGET, not beside the package's other tests. The hostless
// target has no connected window scene, so `UIWindow.makeKeyAndVisible()` attaches to nothing and
// `present(_:animated:)` never completes — the first draft of this file hung for 33 seconds and
// failed on a harness limitation rather than on the SDK. Inside the host app there is a real
// scene, a real key window and a real presentation.
import XCTest
import UIKit
@testable import AppDNASDK

@MainActor
final class PresentableHostTests: XCTestCase {

    /// A controller in a real key window, which is the only state UIKit will present from.
    private func hosted() -> (UIWindow, UIViewController) {
        let vc = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        return (window, vc)
    }

    /// 🔴 THE CONTROL, first: a controller that CAN present must be kept. Without this, every
    /// assertion below passes against a helper that always returns something else.
    func testAUsableControllerIsKept() {
        let (window, vc) = hosted()
        defer { window.isHidden = true }
        XCTAssertTrue(
            PaywallManager.presentableHost(preferring: vc) === vc,
            "a controller in a window, presenting nothing, is exactly the one to present on",
        )
    }

    func testAControllerAlreadyPresentingIsNotChosen() {
        let (window, root) = hosted()
        defer { window.isHidden = true }
        let occupier = UIViewController()
        let presented = expectation(description: "the first modal is up")
        root.present(occupier, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)

        let chosen = PaywallManager.presentableHost(preferring: root)
        XCTAssertFalse(
            chosen === root,
            "a controller that is already presenting cannot present again — UIKit refuses it "
                + "silently, which is the whole defect",
        )
        XCTAssertTrue(chosen === occupier, "the deepest presented controller is the one that can")
    }

    func testAControllerWithNoWindowIsNotChosen() {
        // A real key window exists, so there IS a usable controller to find — otherwise the
        // fallback would have nothing to return and this would pass for the wrong reason.
        let (window, root) = hosted()
        defer { window.isHidden = true }

        // Never added to a window: `present` on it is refused with "view is not in the window
        // hierarchy", the other half of the same silence.
        let orphan = UIViewController()
        let chosen = PaywallManager.presentableHost(preferring: orphan)
        XCTAssertFalse(chosen === orphan, "a controller outside the window hierarchy cannot present")
        /*
         🔴 NOT `chosen === root`. Inside the HOST APP there is already a real key window with the
         app's own root controller, and `topViewController()` finds that one rather than the window
         this test just made — which is correct, and is the whole point of falling back to what is
         actually on screen. The property that matters is that whatever comes back CAN present.
         */
        XCTAssertNotNil(
            chosen.view.window,
            "the fallback must return a controller that is in a window — one that is not would be "
                + "refused by UIKit exactly like the orphan",
        )
        XCTAssertNil(chosen.presentedViewController, "…and that is not already presenting")
    }
}
