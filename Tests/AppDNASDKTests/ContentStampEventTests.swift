// ContentStampEventTests.swift
//
// SPEC-536 — every onboarding, paywall, purchase, in-app message and survey event names the content
// that was on screen: `content_version` (the served item's `version`) and, only while Serve instead
// has swapped the item, `content_source_id` (`served_from.id`).
//
// Each test drives the REAL manager (the config parsed through `RemoteConfigManager`'s own per-item
// parser, the events read off `EventTracker.eventSink`), so a stamp missing from one event site fails
// the test that names that event. Ids are synthetic.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UIKit
import SwiftUI
@testable import AppDNASDK

@MainActor
final class ContentStampEventTests: XCTestCase {

    // MARK: - Harness

    private var events: [SDKEvent] = []
    private var tracker: EventTracker!
    private var rcm: RemoteConfigManager!
    /// Managers hand their closures `[weak self]`; on a device the SDK holds them, here the test does.
    private var keepAlive: [AnyObject] = []

    override func setUp() {
        super.setUp()
        events = []
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        tracker = EventTracker(identityManager: identity)
        tracker.eventSink = { [weak self] e in self?.events.append(e) }
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
    }

    /// The SWAPPED marker the server writes while Serve instead is applied.
    private static let swapped: [String: Any] = ["id": "src_item_1", "version": 3]

    /// A presenter that records what it was asked to present instead of asking UIKit, so the presented
    /// SwiftUI root — and the manager's own closures inside it — are reachable without a window.
    private final class CapturingController: UIViewController {
        var captured: UIViewController?
        override func present(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            captured = vc
            completion?()
        }
    }

    private func props(_ name: String) -> [[String: Any]] {
        events.filter { $0.event_name == name }.map { ($0.properties ?? [:]).mapValues { $0.value } }
    }

    /// Every event named must exist, and each must carry exactly the expected content keys.
    private func assertStamped(
        _ names: [String], version: Int, source: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for name in names {
            let all = props(name)
            XCTAssertFalse(all.isEmpty, "no \(name) was emitted", file: file, line: line)
            for p in all {
                XCTAssertEqual(p["content_version"] as? Int, version, "\(name) content_version", file: file, line: line)
                if let source {
                    XCTAssertEqual(p["content_source_id"] as? String, source, "\(name) content_source_id", file: file, line: line)
                } else {
                    XCTAssertNil(p["content_source_id"], "\(name) has no source unless swapped", file: file, line: line)
                }
            }
        }
    }

    private func waitFor(_ name: String, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while props(name).isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - The helper

    func testHelperWritesVersionAlwaysAndSourceOnlyWhenSwapped() {
        XCTAssertEqual(ContentStamp.props(version: 7, servedFrom: nil) as NSDictionary, ["content_version": 7])
        XCTAssertEqual(
            ContentStamp.props(version: 7, servedFrom: ServedFrom(id: "src_item_1", version: 3)) as NSDictionary,
            ["content_version": 7, "content_source_id": "src_item_1"]
        )
        XCTAssertEqual(ContentStamp.props(version: nil, servedFrom: nil) as NSDictionary, [:])
        XCTAssertEqual(ContentStamp.props(version: 2, servedFrom: ServedFrom(id: "")) as NSDictionary, ["content_version": 2])
        // The stamp wins over a same-named key already in the properties.
        let merged = ContentStamp.stamped(["content_version": 999, "x": 1], ["content_version": 7])
        XCTAssertEqual(merged as NSDictionary, ["content_version": 7, "x": 1])
    }

    // MARK: - Models

    func testAllFourModelsDecodeVersionAndServedFromAndStayLenient() throws {
        func decode<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
            try JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
        let marker = #""served_from": {"id": "src_item_1", "version": 3}"#
        let flow = try decode(OnboardingFlowConfig.self, #"{"id": "fx_flow", "version": 7, \#(marker)}"#)
        let paywall = try decode(PaywallConfig.self, #"{"id": "fx_pw", "version": 7, \#(marker)}"#)
        let message = try decode(MessageConfig.self, #"{"name": "m", "version": 7, \#(marker)}"#)
        let survey = try decode(SurveyConfig.self, #"{"name": "s", "version": 7, \#(marker)}"#)
        for item in [flow, paywall, message, survey] as [ContentStampSource] {
            XCTAssertEqual(item.version, 7)
            XCTAssertEqual(item.served_from, ServedFrom(id: "src_item_1", version: 3))
        }
        // Absent → nil, and an old config still decodes.
        XCTAssertNil(try decode(MessageConfig.self, #"{"name": "m"}"#).served_from)
        XCTAssertNil(try decode(SurveyConfig.self, #"{"name": "s"}"#).version)
        // A malformed marker costs the marker, never the item.
        let bad = try decode(MessageConfig.self, #"{"name": "m", "version": 4, "served_from": "nope"}"#)
        XCTAssertEqual(bad.version, 4)
        XCTAssertNil(bad.served_from?.id)
        XCTAssertNil(try decode(OnboardingFlowConfig.self, #"{"id": "f", "served_from": 5}"#).served_from?.id)
    }

    // MARK: - Onboarding

    private func presentFlow(servedFrom: [String: Any]?) throws -> OnboardingFlowHost {
        var doc: [String: Any] = [
            "id": "fx_flow_cs",
            "version": 7,
            "steps": [
                ["id": "s1", "type": "welcome", "config": ["title": "One"]],
                ["id": "s2", "type": "welcome", "config": ["title": "Two"]],
            ],
        ]
        if let servedFrom { doc["served_from"] = servedFrom }
        rcm._applyIndexedItemForTesting(indexPath: "onboarding_index", id: "fx_flow_cs", data: doc)
        let manager = OnboardingFlowManager(remoteConfigManager: rcm, eventTracker: tracker)
        keepAlive.append(manager)
        let presenter = CapturingController()
        XCTAssertTrue(manager.present(flowId: "fx_flow_cs", from: presenter, delegate: nil))
        let hosting = try XCTUnwrap(presenter.captured as? UIHostingController<OnboardingFlowHost>)
        return hosting.rootView
    }

    func testOnboardingEventsCarryTheSwappedContent() throws {
        let host = try presentFlow(servedFrom: Self.swapped)
        host.onStepViewed("s1", 0)
        host.onStepCompleted("s1", 0, ["a": 1])
        host.onStepSkipped("s2", 1)
        host.onFlowCompleted(["s1": ["a": 1]])
        host.onFlowDismissed("s2", 1)
        XCTAssertEqual(host.contentStamp as NSDictionary, ["content_version": 7, "content_source_id": "src_item_1"],
                       "the renderer's own events (paywall stay/skip, permissions, chat, sheets) read this stamp")
        assertStamped([
            "onboarding_flow_started", "onboarding_step_viewed", "onboarding_step_completed",
            "onboarding_step_skipped", "onboarding_flow_completed", "onboarding_flow_dismissed",
        ], version: 7, source: "src_item_1")
        // The existing reader's key stays.
        XCTAssertEqual(props("onboarding_flow_started").first?["flow_version"] as? Int, 7)
    }

    func testOnboardingEventsWithoutSwapCarryOnlyTheVersion() throws {
        let host = try presentFlow(servedFrom: nil)
        host.onStepViewed("s1", 0)
        host.onFlowCompleted([:])
        assertStamped(["onboarding_flow_started", "onboarding_step_viewed", "onboarding_flow_completed"],
                      version: 7, source: nil)
    }

    // MARK: - Paywall + purchases

    private final class ScriptedBridge: BillingBridgeProtocol, @unchecked Sendable {
        var error: Error?
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
            if let error { throw error }
            return PurchaseResult(
                productId: productId, transactionId: "txn_cs_1", price: 9.99, currency: "USD",
                provider: "storekit2", isSubscription: false, isConsumable: false
            )
        }
        func restore(appAccountToken: UUID?) async throws -> [String] { [] }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
    }

    private func presentPaywall(
        servedFrom: [String: Any]?, bridge: BillingBridgeProtocol?, customData: [String: Any]? = nil
    ) async throws -> (PaywallManager, PaywallRenderer) {
        var doc: [String: Any] = [
            "id": "fx_pw_cs",
            "version": 7,
            "plans": [["id": "p1", "product_id": "fx.plan.monthly", "price": "9.99"]],
        ]
        if let servedFrom { doc["served_from"] = servedFrom }
        rcm._applyIndexedItemForTesting(indexPath: "paywall_index", id: "fx_pw_cs", data: doc)
        let manager = PaywallManager(
            remoteConfigManager: rcm,
            billingBridge: bridge,
            billingPolicy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true),
            eventTracker: tracker
        )
        let presenter = CapturingController()
        manager.present(
            id: "fx_pw_cs", from: presenter,
            context: PaywallContext(placement: "fx_place", customData: customData), delegate: nil
        )
        await waitFor("paywall_view")
        let hosting = try XCTUnwrap(presenter.captured as? UIHostingController<PaywallRenderer>)
        return (manager, hosting.rootView)
    }

    func testPaywallViewCloseAndPurchaseCarryTheSwappedContent() async throws {
        let bridge = ScriptedBridge()
        let (manager, paywall) = try await presentPaywall(
            servedFrom: Self.swapped, bridge: bridge,
            // A host may not relabel which content a view counts for.
            customData: ["content_version": 999, "content_source_id": "host_spoof", "campaign": "c1"]
        )
        let plan = try XCTUnwrap(paywall.config.plans?.first)
        paywall.onPlanSelected(plan, [:])
        await waitFor("purchase_completed")
        bridge.error = BillingError.userCancelled
        paywall.onPlanSelected(plan, [:])
        await waitFor("purchase_canceled")
        bridge.error = BillingError.productNotFound("fx.plan.monthly")
        paywall.onPlanSelected(plan, [:])
        await waitFor("purchase_failed")
        paywall.onDismiss(.dismissed)
        withExtendedLifetime(manager) {}

        assertStamped([
            "paywall_view", "paywall_close",
            "purchase_started", "purchase_completed", "purchase_canceled", "purchase_failed",
        ], version: 7, source: "src_item_1")
        XCTAssertEqual(props("paywall_view").first?["campaign"] as? String, "c1", "other custom data still lands")
    }

    func testPaywallWithoutSwapCarriesOnlyTheVersion() async throws {
        let (manager, paywall) = try await presentPaywall(servedFrom: nil, bridge: ScriptedBridge())
        paywall.onPlanSelected(try XCTUnwrap(paywall.config.plans?.first), [:])
        await waitFor("purchase_completed")
        withExtendedLifetime(manager) {}
        assertStamped(["paywall_view", "purchase_started", "purchase_completed"], version: 7, source: nil)
    }

    /// A purchase that did not start from a paywall carries no content keys.
    func testPurchaseWithoutAPaywallCarriesNoContentKeys() {
        PurchaseSuccessEvents.emit(tracker: tracker, paywallId: nil, result: PurchaseResult(
            productId: "fx.plan.monthly", transactionId: "txn_cs_2", price: 1, currency: "USD",
            provider: "storekit2", isSubscription: false, isConsumable: false
        ))
        let p = props("purchase_completed").first
        XCTAssertNotNil(p)
        XCTAssertNil(p?["content_version"])
        XCTAssertNil(p?["content_source_id"])
    }

    // MARK: - In-app messages

    func testMessageShownClickedDismissedCarryTheSwappedContent() async throws {
        let id = "fx_msg_cs_\(UUID().uuidString.prefix(6))"
        defer { UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).shown") }
        rcm._parseMessageDocForTesting(id: id, data: [
            "message_type": "modal",
            "content": ["title": "Synthetic", "body": "Synthetic body.", "cta_text": "OK"],
            "trigger_rules": ["event": "fx_evt_cs", "frequency": "every_time"],
            "version": 7,
            "served_from": Self.swapped,
        ])
        var shown: [UIViewController] = []
        var surface = MessageSurface.live
        surface.host = { UIViewController() }
        surface.show = { _, _, content in shown.append(content) }
        surface.close = { _, done in done() }
        surface.observeActivation = { _ in {} }
        let manager = MessageManager(remoteConfigManager: rcm, eventTracker: tracker, surface: surface)

        manager.onEvent(eventName: "fx_evt_cs", properties: nil)
        await SharedFixtureTests.drainMainQueue()
        let renderer = try XCTUnwrap((shown.first as? UIHostingController<MessageRenderer>)?.rootView)
        renderer.onCTATap()
        await SharedFixtureTests.drainMainQueue()
        manager.onEvent(eventName: "fx_evt_cs", properties: nil)
        await SharedFixtureTests.drainMainQueue()
        manager.dismissOnScreenForTesting()
        await SharedFixtureTests.drainMainQueue()

        assertStamped(["in_app_message_shown", "in_app_message_clicked", "in_app_message_dismissed"],
                      version: 7, source: "src_item_1")
    }

    // MARK: - Surveys

    private func surveyManager(servedFrom: [String: Any]?) -> SurveyManager {
        var doc: [String: Any] = [
            "name": "Synthetic NPS",
            "survey_type": "nps",
            "questions": [["id": "q1", "type": "nps", "text": "?"]],
            "follow_up_actions": ["on_negative": ["action": "trigger_winback", "message": "m"]],
            "version": 7,
        ]
        if let servedFrom { doc["served_from"] = servedFrom }
        rcm._applyIndexedItemForTesting(indexPath: "survey_index", id: "fx_srv_cs", data: doc)
        let manager = SurveyManager(remoteConfigManager: rcm, eventTracker: tracker)
        manager.updateConfigs(rcm.getSurveyConfigs())
        return manager
    }

    func testSurveyEventsCarryTheSwappedContent() throws {
        let manager = surveyManager(servedFrom: Self.swapped)
        var finish: ((SurveyResult) -> Void)?
        manager.presentForTesting = { config, onAnswered, completion in
            let question = config.questions!.first!
            onAnswered?(config.name ?? "", question, SurveyAnswer(question_id: "q1", answer: 2))
            finish = completion
        }
        manager.present(surveyId: "fx_srv_cs")
        try XCTUnwrap(finish)(.completed(answers: [SurveyAnswer(question_id: "q1", answer: 2)]))
        manager.present(surveyId: "fx_srv_cs")
        try XCTUnwrap(finish)(.dismissed(answeredCount: 0))

        assertStamped([
            "survey_shown", "survey_question_answered", "survey_completed",
            surveyFollowUpWinbackEvent, "survey_dismissed",
        ], version: 7, source: "src_item_1")
    }

    func testSurveyWithoutSwapCarriesOnlyTheVersion() throws {
        let manager = surveyManager(servedFrom: nil)
        var finish: ((SurveyResult) -> Void)?
        manager.presentForTesting = { _, _, completion in finish = completion }
        manager.present(surveyId: "fx_srv_cs")
        try XCTUnwrap(finish)(.completed(answers: [SurveyAnswer(question_id: "q1", answer: 10)]))
        assertStamped(["survey_shown", "survey_completed"], version: 7, source: nil)
    }
}
