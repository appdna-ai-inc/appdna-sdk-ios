import XCTest
import UIKit
@testable import AppDNASDK

/// A step's keep-in-view request is applied by SwiftUI on a later pass, so on a slow device one made just before the
/// user touches the step can land after their drag and take the step back (measured under CPU load: the step returned
/// to the request's 202 pt one second after a drag to the top). The coordinator puts the step back where the user left it.
@MainActor
final class StepScrollLateRequestTests: XCTestCase {

    private func spin(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

    private func scroller() -> (UIWindow, UIScrollView) {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        let vc = UIViewController(); w.rootViewController = vc; w.makeKeyAndVisible()
        let sv = UIScrollView(frame: vc.view.bounds)
        sv.contentSize = CGSize(width: 390, height: 900)
        vc.view.addSubview(sv)
        return (w, sv)
    }

    private func userDrag(_ sv: UIScrollView, to y: CGFloat) {
        FingerDown.on(sv) { sv.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
    }

    func testARequestLandingAfterTheUsersDragIsUndone() {
        let (w, sv) = scroller(); defer { w.isHidden = true }
        let c = AppDNAStepScrollCoordinator(); c.attach(sv)
        sv.setContentOffset(CGPoint(x: 0, y: 202), animated: false)   // the step scrolled to the field
        c.noteRequestIssuedForTesting()                               // a further request is in flight
        userDrag(sv, to: 0)                                           // the user drags to the top
        XCTAssertTrue(c.userScrolled, "control: the drag is the user's")
        sv.setContentOffset(CGPoint(x: 0, y: 202), animated: false)   // the earlier request lands late
        spin(0.1)
        XCTAssertEqual(sv.contentOffset.y, 0, accuracy: 0.5, "the late request took the step back from where the user left it")
    }

    func testControlAProgrammaticMoveWithNoRecentRequestIsLeftAlone() {
        let (w, sv) = scroller(); defer { w.isHidden = true }
        let c = AppDNAStepScrollCoordinator(); c.attach(sv)
        userDrag(sv, to: 100)
        sv.setContentOffset(CGPoint(x: 0, y: 150), animated: false)   // the app's own move, nothing of ours in flight
        spin(0.1)
        XCTAssertEqual(sv.contentOffset.y, 150, accuracy: 0.5)
    }

    func testControlAMoveAfterTheWindowIsLeftAlone() {
        let (w, sv) = scroller(); defer { w.isHidden = true }
        let c = AppDNAStepScrollCoordinator(); c.attach(sv)
        c.noteRequestIssuedForTesting()
        userDrag(sv, to: 0)
        spin(AppDNAStepScrollCoordinator.lateRequestWindow + 0.1)
        sv.setContentOffset(CGPoint(x: 0, y: 150), animated: false)
        spin(0.1)
        XCTAssertEqual(sv.contentOffset.y, 150, accuracy: 0.5)
    }
}
