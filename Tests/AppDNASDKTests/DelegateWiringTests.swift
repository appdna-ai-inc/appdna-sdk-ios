import XCTest
@testable import AppDNASDK

/// Verify each newly-wired delegate fires from the
/// public `AppDNA.<module>.delegate` slot. Like the paywall bridge
/// tests, we exercise the contract through the public setDelegate APIs
/// rather than constructing internal managers; the end-to-end wiring
/// is exercised on the Mac build bridge.
final class DelegateWiringTests: XCTestCase {

    override func tearDown() {
        AppDNA.surveys.setDelegate(nil)
        AppDNA.inAppMessages.setDelegate(nil)
        AppDNA.billingDelegate = nil
        AppDNA.pushDelegate = nil
        AppDNA.screenDelegate = nil
        super.tearDown()
    }

    // MARK: - Survey delegate (3 methods)

    func testSurveyDelegateRegistersAndFires() {
        let recorder = SurveyRecorder()
        AppDNA.surveys.setDelegate(recorder)
        XCTAssertTrue(AppDNA.surveys.delegate === recorder)

        AppDNA.surveys.delegate?.onSurveyPresented(surveyId: "s1")
        AppDNA.surveys.delegate?.onSurveyCompleted(surveyId: "s1", responses: [
            SurveyResponse(questionId: "q1", answer: 5)
        ])
        AppDNA.surveys.delegate?.onSurveyDismissed(surveyId: "s1")

        XCTAssertEqual(recorder.presentedIds, ["s1"])
        XCTAssertEqual(recorder.completedIds, ["s1"])
        XCTAssertEqual(recorder.dismissedIds, ["s1"])
        XCTAssertEqual(recorder.lastResponses?.count, 1)
    }

    func testSurveyDelegateLegacyHostUsesDefaults() {
        // A host that conforms to AppDNASurveyDelegate WITHOUT
        // implementing the methods must still compile and produce
        // no-op behavior thanks to the default extension.
        final class LegacySurveyDelegate: AppDNASurveyDelegate {}
        let host = LegacySurveyDelegate()
        host.onSurveyPresented(surveyId: "s1")
        host.onSurveyCompleted(surveyId: "s1", responses: [])
        host.onSurveyDismissed(surveyId: "s1")
        XCTAssertTrue(true)
    }

    // MARK: - InAppMessage delegate (4 methods incl. veto)

    func testInAppMessageDelegateVetoTrueShows() {
        let recorder = InAppMessageRecorder(allowDisplay: true)
        AppDNA.inAppMessages.setDelegate(recorder)

        // shouldShowMessage(true) → host is asked but grants display.
        let allowed = AppDNA.inAppMessages.delegate?.shouldShowMessage(messageId: "m1")
        XCTAssertEqual(allowed, true)

        // Subsequent lifecycle callbacks fire.
        AppDNA.inAppMessages.delegate?.onMessageShown(messageId: "m1", trigger: "session_start")
        AppDNA.inAppMessages.delegate?.onMessageAction(messageId: "m1", action: "open_url", data: ["url": "https://x"])
        AppDNA.inAppMessages.delegate?.onMessageDismissed(messageId: "m1")

        XCTAssertEqual(recorder.shouldShowAsked, ["m1"])
        XCTAssertEqual(recorder.shownIds, ["m1"])
        XCTAssertEqual(recorder.actions, [InAppMessageRecorder.ActionRecord(messageId: "m1", action: "open_url")])
        XCTAssertEqual(recorder.dismissedIds, ["m1"])
    }

    func testInAppMessageDelegateVetoFalseSuppresses() {
        let recorder = InAppMessageRecorder(allowDisplay: false)
        AppDNA.inAppMessages.setDelegate(recorder)

        // Veto returns false → the SDK must short-circuit before
        // tracking shown / firing onMessageShown. We assert the
        // delegate decision here; the actual short-circuit in
        // MessageManager.present is exercised in the Mac smoke test.
        let allowed = AppDNA.inAppMessages.delegate?.shouldShowMessage(messageId: "m_blocked")
        XCTAssertEqual(allowed, false)
        XCTAssertEqual(recorder.shouldShowAsked, ["m_blocked"])
    }

    func testInAppMessageDelegateLegacyHostShowsByDefault() {
        // Default extension returns true so legacy hosts that don't
        // implement shouldShowMessage continue to see all messages.
        final class LegacyHost: AppDNAInAppMessageDelegate {}
        let host = LegacyHost()
        XCTAssertTrue(host.shouldShowMessage(messageId: "anything"))
    }

    // MARK: - Billing delegate (3 methods)

    func testBillingDelegateRegistersAndFires() {
        let recorder = BillingRecorder()
        AppDNA.billingDelegate = recorder
        XCTAssertTrue(AppDNA.billingDelegate === recorder)

        let txInfo = TransactionInfo(transactionId: "t1", productId: "annual_99", purchaseDate: Date())
        AppDNA.billingDelegate?.onPurchaseCompleted(productId: "annual_99", transaction: txInfo)
        AppDNA.billingDelegate?.onPurchaseFailed(productId: "annual_99", error: NSError(domain: "test", code: 1))
        AppDNA.billingDelegate?.onRestoreCompleted(restoredProducts: ["annual_99"])

        XCTAssertEqual(recorder.completedIds, ["annual_99"])
        XCTAssertEqual(recorder.failedIds, ["annual_99"])
        XCTAssertEqual(recorder.restoredIds, [["annual_99"]])
    }

    // MARK: - Push delegate (onPushTokenRegistered)

    func testPushDelegateTokenRegisteredFires() {
        let recorder = PushRecorder()
        AppDNA.pushDelegate = recorder
        AppDNA.pushDelegate?.onPushTokenRegistered(token: "abc123")
        XCTAssertEqual(recorder.tokens, ["abc123"])
    }

    // MARK: - Screen delegate (3 lifecycle methods)

    func testScreenDelegateLifecycleFires() {
        let recorder = ScreenRecorder()
        AppDNA.screenDelegate = recorder

        AppDNA.screenDelegate?.onScreenPresented(screenId: "scr1")
        let dismissResult = ScreenResult(screenId: "scr1", dismissed: true, duration_ms: 1234)
        AppDNA.screenDelegate?.onScreenDismissed(screenId: "scr1", result: dismissResult)
        let flowResult = FlowResult(flowId: "f1", completed: true, screensViewed: ["scr1", "scr2"], duration_ms: 5000)
        AppDNA.screenDelegate?.onFlowCompleted(flowId: "f1", result: flowResult)

        XCTAssertEqual(recorder.presentedIds, ["scr1"])
        XCTAssertEqual(recorder.dismissedIds, ["scr1"])
        XCTAssertEqual(recorder.completedFlowIds, ["f1"])
    }
}

// MARK: - Recorder helpers

private final class SurveyRecorder: AppDNASurveyDelegate {
    var presentedIds: [String] = []
    var completedIds: [String] = []
    var dismissedIds: [String] = []
    var lastResponses: [SurveyResponse]?

    func onSurveyPresented(surveyId: String) { presentedIds.append(surveyId) }
    func onSurveyCompleted(surveyId: String, responses: [SurveyResponse]) {
        completedIds.append(surveyId)
        lastResponses = responses
    }
    func onSurveyDismissed(surveyId: String) { dismissedIds.append(surveyId) }
}

private final class InAppMessageRecorder: AppDNAInAppMessageDelegate {
    let allowDisplay: Bool
    var shouldShowAsked: [String] = []
    var shownIds: [String] = []
    var actions: [ActionRecord] = []
    var dismissedIds: [String] = []

    init(allowDisplay: Bool) { self.allowDisplay = allowDisplay }

    func shouldShowMessage(messageId: String) -> Bool {
        shouldShowAsked.append(messageId)
        return allowDisplay
    }
    func onMessageShown(messageId: String, trigger: String) { shownIds.append(messageId) }
    func onMessageAction(messageId: String, action: String, data: [String: Any]?) {
        actions.append(ActionRecord(messageId: messageId, action: action))
    }
    func onMessageDismissed(messageId: String) { dismissedIds.append(messageId) }

    struct ActionRecord: Equatable {
        let messageId: String
        let action: String
    }
}

private final class BillingRecorder: AppDNABillingDelegate {
    var completedIds: [String] = []
    var failedIds: [String] = []
    var restoredIds: [[String]] = []

    func onPurchaseCompleted(productId: String, transaction: TransactionInfo) {
        completedIds.append(productId)
    }
    func onPurchaseFailed(productId: String, error: Error) { failedIds.append(productId) }
    func onEntitlementsChanged(entitlements: [Entitlement]) { /* not exercised here */ }
    func onRestoreCompleted(restoredProducts: [String]) { restoredIds.append(restoredProducts) }
}

private final class PushRecorder: AppDNAPushDelegate {
    var tokens: [String] = []
    func onPushTokenRegistered(token: String) { tokens.append(token) }
    // onPushReceived / onPushTapped left to default extension (no-op);
    // those callbacks are wired earlier and tested elsewhere.
}

private final class ScreenRecorder: AppDNAScreenDelegate {
    var presentedIds: [String] = []
    var dismissedIds: [String] = []
    var completedFlowIds: [String] = []

    func onScreenPresented(screenId: String) { presentedIds.append(screenId) }
    func onScreenDismissed(screenId: String, result: ScreenResult) { dismissedIds.append(screenId) }
    func onFlowCompleted(flowId: String, result: FlowResult) { completedFlowIds.append(flowId) }
    // onScreenAction left to default extension (returns true).
}
