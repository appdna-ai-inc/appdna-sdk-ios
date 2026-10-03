import XCTest
@testable import AppDNASDK

/// `Screens/FlowManager.handleAction` used to route 4 of the 21 verbs the SDUI layer can
/// dispatch (`next`/`back`/`dismiss`/`navigate`) and `break` on the rest, under the comment "Other
/// actions handled by parent". There is no parent: `ScreenPresenter.presentFlow` wires
/// `context.onAction` straight into it. So inside a multi-screen FLOW every other console-authored
/// button — "show_paywall", "open_url", "deep_link", "track" — did nothing, while the same button
/// worked on a single screen and on Android (`screens/FlowManager.kt` routes all 21).
///
/// Worse, `set_response` had no route either, so `responses` stayed `{}` forever: no navigation rule
/// could ever match and `FlowResult.responses` was always empty — conditional flows were structurally
/// broken on iOS.
///
/// Every test below fails on the old FlowManager.
final class FlowActionRoutingTests: XCTestCase {

    // MARK: - Fixtures

    private func decodeFlow(_ json: String) -> FlowConfig {
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(FlowConfig.self, from: Data(json.utf8))
    }

    /// s1 → s3 when `responses.plan == "pro"`, otherwise sequential (s2).
    private var conditionalFlow: FlowConfig {
        decodeFlow("""
        {
          "id": "flow_1",
          "name": "Onboarding flow",
          "start_screen_id": "s1",
          "screens": [
            {
              "screen_id": "s1",
              "navigation_rules": [
                { "condition": "when_equals", "variable": "responses.plan", "value": "pro", "target": "s3" }
              ]
            },
            { "screen_id": "s2" },
            { "screen_id": "s3" }
          ]
        }
        """)
    }

    private func manager(_ flow: FlowConfig) -> FlowManager {
        FlowManager(flowConfig: flow, screens: [:])
    }

    // MARK: - set_response → responses → conditional navigation

    /// THE BUG: `.setResponse` was dropped, so `evaluateCondition` read an empty `responses` bag and
    /// the rule could never match. The flow fell through to sequential advance (s2) instead of the
    /// authored branch (s3).
    func testSetResponseMergesIntoResponsesAndDrivesConditionalNavigation() {
        let flowManager = manager(conditionalFlow)

        flowManager.handleAction(.setResponse(key: "plan", value: "pro"))
        XCTAssertEqual(flowManager.responses["plan"] as? String, "pro")

        flowManager.handleAction(.next)
        XCTAssertEqual(flowManager.currentScreenId, "s3", "the authored rule must win over sequential advance")
    }

    /// Without a matching response the same flow advances sequentially — the rule branch is real, not
    /// unconditional.
    func testUnsetResponseFallsThroughToSequentialAdvance() {
        let flowManager = manager(conditionalFlow)
        flowManager.handleAction(.next)
        XCTAssertEqual(flowManager.currentScreenId, "s2")
    }

    /// The accumulated responses must reach the host: `FlowResult.responses` was always `{}`.
    func testFlowResultCarriesTheAccumulatedResponses() {
        let flowManager = manager(conditionalFlow)
        var result: FlowResult?
        flowManager.onComplete = { result = $0 }

        flowManager.handleAction(.setResponse(key: "plan", value: "pro"))
        flowManager.handleAction(.setResponse(key: "seats", value: 3))
        flowManager.handleAction(.complete)

        XCTAssertEqual(result?.completed, true)
        XCTAssertEqual(result?.responses["plan"] as? String, "pro")
        XCTAssertEqual(result?.responses["seats"] as? Int, 3)
    }

    /// A nil value is not a response (Android: `action.value?.let { responses[key] = it }`).
    func testSetResponseWithNilValueStoresNothing() {
        let flowManager = manager(conditionalFlow)
        flowManager.handleAction(.setResponse(key: "plan", value: nil))
        XCTAssertTrue(flowManager.responses.isEmpty)
    }

    // MARK: - Platform verbs reach the ONE router

    /// THE BUG: a `open_url` / `deep_link` CTA inside a flow reached `default: break`. The action's
    /// only escape to the OS is `ScreenManager.urlOpener`, so an injected opener proves the flow path
    /// now runs the same router the single-screen path always used.
    func testOpenURLInAFlowReachesTheScreenRouter() {
        let flowManager = manager(conditionalFlow)
        let router = ScreenManager()
        let opened = expectation(description: "url opened")
        var openedURLs: [URL] = []
        router.urlOpener = { url in
            openedURLs.append(url)
            opened.fulfill()
        }
        flowManager.router = router

        flowManager.handleAction(.openURL(url: "https://example.com/pricing"))

        wait(for: [opened], timeout: 1.0)
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://example.com/pricing"])
    }

    func testDeepLinkInAFlowReachesTheScreenRouter() {
        // A custom-scheme deep link is only allowed when the HOST registers that scheme
        // (URLSafety.hostSchemes ← CFBundleURLTypes). Under XCTest `Bundle.main` is the test runner,
        // which registers nothing — so without this stand-in the URL is refused by policy and this
        // test fails for a reason that never occurs in a real app, masking what it actually asserts:
        // that a flow action reaches the router at all.
        let realHostSchemes = URLSafety.hostSchemes
        URLSafety.hostSchemes = ["myapp"]
        defer { URLSafety.hostSchemes = realHostSchemes }

        let flowManager = manager(conditionalFlow)
        let router = ScreenManager()
        let opened = expectation(description: "deep link opened")
        var openedURLs: [URL] = []
        router.urlOpener = { url in
            openedURLs.append(url)
            opened.fulfill()
        }
        flowManager.router = router

        flowManager.handleAction(.deepLink(url: "myapp://upgrade"))

        wait(for: [opened], timeout: 1.0)
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["myapp://upgrade"])
    }

    /// The host's `onScreenAction` veto now gates flow actions too — it only ever gated single-screen
    /// ones, because flow actions never reached the router at all.
    func testVetoedFlowActionOpensNothing() {
        let flowManager = manager(conditionalFlow)
        let host = VetoingScreenDelegate(allow: false)
        AppDNA.screenDelegate = host
        defer { AppDNA.screenDelegate = nil }

        let router = ScreenManager()
        var openedURLs: [URL] = []
        router.urlOpener = { openedURLs.append($0) }
        flowManager.router = router

        flowManager.handleAction(.openURL(url: "https://example.com"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(host.seenScreenIds, ["s1"], "the router must be told WHICH screen dispatched")
    }

    // MARK: - Host signals (names pinned to Android FlowManager.kt)

    /// `purchase` / `restore` / `show_message` are signals: the SDK cannot perform them, so it emits
    /// the event the host listens for. Names + prop keys are Android's, verbatim
    /// (`screens/FlowManager.kt:77,105,109`).
    func testPurchaseRestoreAndShowMessageEmitAndroidsSignals() {
        let flowManager = manager(conditionalFlow)
        var emitted: [(name: String, props: [String: Any])] = []
        flowManager.eventSink = { emitted.append((name: $0, props: $1)) }

        flowManager.handleAction(.purchase(productId: "pro_yearly"))
        flowManager.handleAction(.restore)
        flowManager.handleAction(.showMessage(id: "msg_1"))

        XCTAssertEqual(emitted.map(\.name), ["purchase_request", "restore_request", "message_request"])
        XCTAssertEqual(emitted[0].props["product_id"] as? String, "pro_yearly")
        XCTAssertTrue(emitted[1].props.isEmpty)
        XCTAssertEqual(emitted[2].props["message_id"] as? String, "msg_1")

        // The names are the constants the parity gate resolves — a rename must break here.
        XCTAssertEqual(purchaseRequestEvent, "purchase_request")
        XCTAssertEqual(restoreRequestEvent, "restore_request")
        XCTAssertEqual(messageRequestEvent, "message_request")
    }

    // MARK: - restart / complete

    /// Android FlowManager.kt:122-130 — `restart` re-enters the start screen and PRESERVES responses.
    func testRestartReturnsToTheStartScreenAndKeepsResponses() {
        let flowManager = manager(conditionalFlow)
        flowManager.handleAction(.setResponse(key: "plan", value: "free"))
        flowManager.handleAction(.next)
        XCTAssertEqual(flowManager.currentScreenId, "s2")

        flowManager.handleAction(.restart)

        XCTAssertEqual(flowManager.currentScreenId, "s1")
        XCTAssertTrue(flowManager.navigationStack.isEmpty)
        XCTAssertEqual(flowManager.responses["plan"] as? String, "free")
    }

    /// `complete` finishes the flow from any screen (it used to be inert).
    func testCompleteFinishesTheFlow() {
        let flowManager = manager(conditionalFlow)
        var result: FlowResult?
        flowManager.onComplete = { result = $0 }

        flowManager.handleAction(.complete)

        XCTAssertEqual(result?.completed, true)
        XCTAssertEqual(result?.lastScreenId, "s1")
    }

    /// `dismiss_paywall` is a no-op at flow level (the paywall host dismisses itself) — it must NOT
    /// end the flow (Android FlowManager.kt:69).
    func testDismissPaywallDoesNotEndTheFlow() {
        let flowManager = manager(conditionalFlow)
        var completions = 0
        flowManager.onComplete = { _ in completions += 1 }

        flowManager.handleAction(.dismissPaywall)

        XCTAssertEqual(completions, 0)
        XCTAssertEqual(flowManager.currentScreenId, "s1")
    }
}

// MARK: - Helpers

private final class VetoingScreenDelegate: AppDNAScreenDelegate {
    private let allow: Bool
    private(set) var seenScreenIds: [String] = []

    init(allow: Bool) { self.allow = allow }

    func onScreenAction(screenId: String, action: SectionAction) -> Bool {
        seenScreenIds.append(screenId)
        return allow
    }
}
