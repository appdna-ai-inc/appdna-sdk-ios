import XCTest
@testable import AppDNASDK

/// The last link in the after-onboarding CTA: the flow finishes and the SDK actually OPENS the
/// destination the CTA recorded.
///
/// WHY THIS IS SEPARATE FROM THE FIXTURE: the shared fixture proves the CTA advances and the route
/// survives the button, and it deliberately does NOT finish the flow — so it never reaches
/// `OnboardingCompletion`. Everything a user would notice happens here, and until this existed the
/// only untested step was the one that opens the link.
///
/// `URLSafety.opener` is the seam. Substituting it asserts the CALL SITE, not just the helper — a
/// tested guard nothing calls is not a guard, which is the lesson recorded in `URLSafety` itself.
final class CompletionRouteTests: XCTestCase {

    private var opened: [URL] = []
    private var realOpener: ((URL) -> Void)!
    private var realHostSchemes: Set<String>!

    override func setUp() {
        super.setUp()
        opened = []
        realOpener = URLSafety.opener
        URLSafety.opener = { [weak self] url in self?.opened.append(url) }
        // Stand in for a host that registered `winetrails://`. Under XCTest `Bundle.main` is the
        // test runner and declares no CFBundleURLTypes, so without this a real deep link is refused
        // on POLICY and the test would fail for a reason that never occurs in a shipped app —
        // which `URLSafety` documents as the reason this property is a `var`.
        realHostSchemes = URLSafety.hostSchemes
        URLSafety.hostSchemes = ["winetrails"]
        // The store is a shared single-shot; a route left by another test would make these pass for
        // the wrong reason.
        PendingCompletionRoute.shared.clear()
    }

    override func tearDown() {
        URLSafety.opener = realOpener
        URLSafety.hostSchemes = realHostSchemes
        PendingCompletionRoute.shared.clear()
        super.tearDown()
    }

    private func complete(delegate: AppDNAOnboardingDelegate? = nil) {
        OnboardingCompletion.complete(
            flowId: "flow_1",
            totalSteps: 2,
            durationMs: 10,
            responses: [:],
            track: { _, _ in },
            delegate: delegate
        )
    }

    func testCompletionOpensTheDestinationTheCtaRecorded() {
        PendingCompletionRoute.shared.record("winetrails://booking/tasting")
        complete()
        XCTAssertEqual(opened.map(\.absoluteString), ["winetrails://booking/tasting"])
    }

    func testCompletionOpensNothingWhenNoCtaAskedForOne() {
        complete()
        XCTAssertTrue(opened.isEmpty)
    }

    func testTheDestinationIsConsumedSoASecondCompletionOpensNothing() {
        // The abandoned-flow bug: without consuming, finishing ANY later flow would navigate the
        // user somewhere they never asked to go.
        PendingCompletionRoute.shared.record("winetrails://booking/tasting")
        complete()
        XCTAssertEqual(opened.count, 1)
        complete()
        XCTAssertEqual(opened.count, 1, "a consumed route must not fire again")
    }

    func testTheHostDelegateRunsBeforeTheLinkOpens() {
        // The host dismisses the flow and does its own navigation in `onOnboardingCompleted`.
        // Opening first would race our navigation against theirs.
        var order: [String] = []
        URLSafety.opener = { _ in order.append("open") }
        let delegate = OrderRecordingDelegate { order.append("delegate") }
        PendingCompletionRoute.shared.record("winetrails://booking/tasting")
        complete(delegate: delegate)
        XCTAssertEqual(order, ["delegate", "open"])
    }

    func testASchemeTheHostHasNotRegisteredIsRefused() {
        // The mirror of the case above: the SDK opens a deep link only into an app that actually
        // declares the scheme. This is why the manual tells the customer they must own the
        // destination — an unregistered scheme is silently refused, not opened.
        URLSafety.hostSchemes = []
        PendingCompletionRoute.shared.record("winetrails://booking/tasting")
        complete()
        XCTAssertTrue(opened.isEmpty)
    }

    func testAnUnsafeSchemeIsRefusedRatherThanOpened() {
        // The URL comes from remote config, so a compromised or mis-authored one must not reach the
        // system opener. This is the reason the open goes through `URLSafety` at all.
        PendingCompletionRoute.shared.record("javascript:alert(1)")
        complete()
        XCTAssertTrue(opened.isEmpty, "an unsafe scheme must never reach the opener")
    }

    func testABlankDestinationRecordsNothing() {
        PendingCompletionRoute.shared.record("   ")
        complete()
        XCTAssertTrue(opened.isEmpty)
    }

    func testALaterTapReplacesAnEarlierDestination() {
        PendingCompletionRoute.shared.record("winetrails://booking/tasting")
        PendingCompletionRoute.shared.record("winetrails://audio/pass")
        complete()
        XCTAssertEqual(opened.map(\.absoluteString), ["winetrails://audio/pass"])
    }
}

/// Minimal delegate: only the completion callback matters here.
private final class OrderRecordingDelegate: AppDNAOnboardingDelegate {
    private let onCompleted: () -> Void
    init(onCompleted: @escaping () -> Void) { self.onCompleted = onCompleted }

    func onOnboardingStarted(flowId: String) {}
    func onOnboardingStepChanged(flowId: String, stepId: String, stepIndex: Int, totalSteps: Int) {}
    func onOnboardingCompleted(flowId: String, responses: [String: Any]) { onCompleted() }
    func onOnboardingDismissed(flowId: String, atStep: Int) {}
}
