import XCTest
import SwiftUI
import UIKit
@testable import AppDNASDK

/// A field holding a Google answer is kept in view while its step lays out, and is let go the moment
/// the user drags.
///
/// The step is the real `OnboardingStepRouter`, inserted the way the flow host inserts a step (an `.id`
/// change with an asymmetric move, under a nav bar) into a landscape-sized window, already holding a
/// Google answer, which is what returning to it with Back does. The step's own UIKit scroll view is
/// read back: its offset, its content size and its viewport.
///
/// 1. **It keeps up with the layout.** A form step's content grows for a few hundred milliseconds
///    after it appears. The offset must end where the least scroll that shows the field's container
///    puts it: the content's height, less the viewport, less the form's 24 pt bottom padding (the
///    container is the last thing in the form). It must also equal the offset of a step drawn fresh.
///    RED CONTROL: one request when the logo appears, and none after → the offset stops 13 pt short
///    (202.3 of 215.3 at 330 pt), the logo cut under the pinned zone.
/// 2. **It never fights a drag.** The user drags the step back to its top 0.10, 0.25 or 0.35 s after
///    it appears, while the content is still growing; a second later the step is still at its top.
///    RED CONTROL: following the layout without stopping for a drag (or a timed second request) →
///    the step jumps back to the field.
///
/// The drag is the offset moving while the scroll view reports a finger on it (see `FingerDown`).
@MainActor
final class GoogleResolvedLogoFollowsLayoutTests: XCTestCase {

    final class Nav: ObservableObject { @Published var index = 0 }

    private struct Host: View {
        @ObservedObject var nav: Nav
        let make: (Int) -> AnyView
        var body: some View {
            VStack(spacing: 0) {
                Color.gray.frame(height: 44) // the flow host's nav bar
                ZStack {
                    make(nav.index)
                        .id(nav.index)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }
            }
            .background(Color.white)
        }
    }

    private func step(_ json: String) throws -> OnboardingStep {
        try JSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
    }

    /// Two text fields above the Location field, as on the walk's form step.
    private func formStep() throws -> OnboardingStep {
        try step(#"{"id":"f","type":"form","config":{"title":"Details","fields":[{"id":"t0","type":"text","label":"First name","required":false},{"id":"t1","type":"text","label":"Last name","required":false},{"id":"home","type":"location","label":"Home","required":false}]}}"#)
    }

    private func blockStep() throws -> OnboardingStep {
        var blocks: [String] = [#"{"id":"h","type":"heading","text":"Where","zone":"top"}"#]
        for i in 0..<3 { blocks.append(#"{"id":"t\#(i)","type":"text","text":"A line of copy above the field, number \#(i).","zone":"center"}"#) }
        blocks.append(#"{"id":"loc","type":"input_location","field_id":"home","field_label":"Home","zone":"center"}"#)
        blocks.append(#"{"id":"next","type":"button","text":"Next","action":"continue","zone":"bottom"}"#)
        return try step(#"{"id":"b","type":"custom","config":{"content_blocks":[\#(blocks.joined(separator: ","))]}}"#)
    }

    private func router(_ s: OnboardingStep) -> AnyView {
        AnyView(OnboardingStepRouter(step: s, onNext: { _ in }, onSkip: {}, savedResponses: ["home": GoogleAttributionData.google]))
    }

    private func spin(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

    private func scrollViews(_ v: UIView) -> [UIScrollView] {
        var out: [UIScrollView] = []
        if let s = v as? UIScrollView { out.append(s) }
        for c in v.subviews { out += scrollViews(c) }
        return out
    }

    /// The step's scroll view: the one with the tallest content.
    private func stepScroll(_ host: UIViewController) -> UIScrollView? {
        scrollViews(host.view).filter { $0.window != nil }.max { $0.contentSize.height < $1.contentSize.height }
    }

    private func mount(_ h: CGFloat, _ nav: Nav, _ make: @escaping (Int) -> AnyView) -> (UIWindow, UIViewController) {
        let size = CGSize(width: 852, height: h)
        let host = UIHostingController(rootView: Host(nav: nav, make: make).environment(\.verticalSizeClass, .compact))
        host.overrideUserInterfaceStyle = .light
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    // MARK: 1. it keeps up with the layout

    func testAFormStepReturnedToWithBackEndsWithTheFieldAndItsLogoInView() throws {
        let s = try formStep()
        for h in [CGFloat(330), 360] {
            // A step drawn fresh, for comparison.
            let freshNav = Nav(); freshNav.index = 1
            let (fw, fresh) = mount(h, freshNav) { i in i == 1 ? self.router(s) : AnyView(Color.yellow) }
            spin(1.5)
            let freshOffset = stepScroll(fresh)?.contentOffset.y ?? -1
            fw.isHidden = true

            for (name, animation) in [("none", Animation?.none), ("easeInOut 0.25", .easeInOut(duration: 0.25)), ("default", .default)] {
                let nav = Nav()
                let (w, host) = mount(h, nav) { i in i == 1 ? self.router(s) : AnyView(Color.yellow) }
                spin(0.5)
                if let animation { withAnimation(animation) { nav.index = 1 } } else { nav.index = 1 }
                spin(1.5)
                guard let sv = stepScroll(host) else { w.isHidden = true; return XCTFail("no step scroll view") }
                let viewport = sv.bounds.height - sv.adjustedContentInset.top - sv.adjustedContentInset.bottom
                let target = sv.contentSize.height - viewport - 24
                let offset = sv.contentOffset.y
                print("[follows-layout] form h=\(Int(h)) anim=\(name) offset=\(fmt(offset)) target=\(fmt(target)) fresh=\(fmt(freshOffset)) content=\(fmt(sv.contentSize.height)) viewport=\(fmt(viewport))")
                XCTAssertGreaterThan(target, 1, "[h=\(Int(h))] control: this layout needs a scroll to show the field's container")
                XCTAssertEqual(offset, target, accuracy: 1, "[h=\(Int(h)) \(name)] the step stops \(fmt(target - offset)) pt short of showing the field and its logo")
                XCTAssertEqual(offset, freshOffset, accuracy: 1, "[h=\(Int(h)) \(name)] a step returned to ends where a fresh one does")
                w.isHidden = true
            }
        }
    }

    // MARK: 2. it never fights a drag

    /// A drag that takes the step to its top: the offset moves while the scroll view reports a finger
    /// on it (`isTracking`), which is how UIKit describes a drag in progress. A package test cannot put a
    /// finger on the screen, so `isTracking` answers true for this one scroll view while the offset moves.
    /// A finger that MOVES the step, then leaves it at the top. Setting the offset to where it already is moves nothing, so
    /// the scroll view reports no change and the SDK cannot see a drag; a real finger always moves the content (or bounces it).
    private func drag(_ sv: UIScrollView) {
        FingerDown.on(sv) {
            sv.setContentOffset(CGPoint(x: 0, y: 24), animated: false)
            sv.setContentOffset(.zero, animated: false)
        }
    }

    /// The order a slow device produces, without depending on its timing: the user drags BEFORE the field appears.
    /// The field appearing must not clear the drag; only a turn of the device may.
    func testTheFieldAppearingAfterADragDoesNotTakeTheStepBack() {
        let coordinator = AppDNAStepScrollCoordinator()
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        sv.contentSize = CGSize(width: 320, height: 1200)
        sv.contentOffset = CGPoint(x: 0, y: 200)
        coordinator.attach(sv)
        XCTAssertFalse(coordinator.userScrolled, "control: a new step starts unscrolled")
        drag(sv)
        XCTAssertTrue(coordinator.userScrolled, "control: the drag counts as the user's")
        coordinator.keepInView("field")
        XCTAssertTrue(coordinator.userScrolled, "the field appearing after the drag cleared it, so the step would jump back")
        coordinator.keepInView("field", deviceTurned: true)
        XCTAssertFalse(coordinator.userScrolled, "a turn of the device is a fresh request")
    }

    func testADragWhileTheStepLaysOutIsNotUndone() throws {
        for (what, s) in [("form", try formStep()), ("block", try blockStep())] {
            for delay in [0.10, 0.25, 0.35] {
                let nav = Nav(); nav.index = 1
                let (w, host) = mount(330, nav) { i in i == 1 ? self.router(s) : AnyView(Color.yellow) }
                spin(delay)
                guard let sv = stepScroll(host) else { w.isHidden = true; return XCTFail("no step scroll view") }
                let before = sv.contentOffset.y
                drag(sv)
                let afterDrag = sv.contentOffset.y
                spin(1.0)
                let later = sv.contentOffset.y
                print("[follows-layout] drag \(what) at=\(delay)s before=\(fmt(before)) afterDrag=\(fmt(afterDrag)) 1s-later=\(fmt(later))")
                XCTAssertEqual(afterDrag, 0, accuracy: 0.5, "control: the drag took the \(what) step to its top")
                XCTAssertEqual(later, 0, accuracy: 1, "[\(what) at \(delay) s] the step jumped back to \(fmt(later)) after the user dragged it to the top")
                w.isHidden = true
            }
        }
    }
}

/// `isTracking` answers true for one scroll view while `body` runs, and as before otherwise.
enum FingerDown {
    private static weak var target: UIScrollView?

    static func on(_ scrollView: UIScrollView, _ body: () -> Void) {
        guard let method = class_getInstanceMethod(UIScrollView.self, #selector(getter: UIScrollView.isTracking)) else {
            return XCTFail("no isTracking getter")
        }
        let original = method_getImplementation(method)
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let originalGetter = unsafeBitCast(original, to: Getter.self)
        let block: @convention(block) (AnyObject) -> Bool = { obj in
            obj === FingerDown.target ? true : originalGetter(obj, #selector(getter: UIScrollView.isTracking))
        }
        target = scrollView
        method_setImplementation(method, imp_implementationWithBlock(block))
        defer {
            method_setImplementation(method, original)
            target = nil
        }
        XCTAssertTrue(scrollView.isTracking, "control: the scroll view reports the finger")
        body()
    }
}
