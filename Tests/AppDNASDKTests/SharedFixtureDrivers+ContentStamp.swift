// SharedFixtureDrivers+ContentStamp.swift
//
// iOS driver for `emit_surface_events` (content keys). Dispatched from
// `SharedFixtureTests.drive`'s default branch. Every event asserted is emitted by the REAL SDK:
//
//   onboarding_flow   each item parsed by `RemoteConfigManager`'s per-item onboarding parser, presented by
//                     `OnboardingFlowManager.present` (→ onboarding_flow_started); the step / completion /
//                     dismissal events through the manager's OWN closures on the presented
//                     `OnboardingFlowHost` (the closures the renderer calls on a device).
//   paywall           parsed by the per-item paywall parser, presented by `PaywallManager.present` with the
//                     fixture's placement and host custom data (→ paywall_view); closed through the presented
//                     `PaywallRenderer.onDismiss` (→ paywall_close).
//   paywall_purchase  the same presentation; the plan bought through `PaywallRenderer.onPlanSelected`, the
//                     manager's real purchase path, against a scripted billing bridge that answers success
//                     (the analog of Android's fake billing client).
//   in_app_message    parsed by the per-item message parser, shown by `MessageManager.onEvent` on the item's
//                     trigger event, clicked through the presented `MessageRenderer.onCTATap`, dismissed through
//                     the manager's own dismiss closure.
//   survey            parsed by the per-item survey parser, presented by `SurveyManager.present(surveyId:)`;
//                     answered, completed and dismissed through the manager's own renderer callbacks.
//
// Each item gets a fresh manager and config store. Only events named in the item's `drive` list are kept,
// as the fixture's contract says.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {

    /// Returns `true` when this file owns `fixture.action.kind` (and drove it).
    @MainActor
    func driveContentStampFixtures(_ f: Fixture, _ h: Harness) async -> Bool {
        guard f.action.kind == "emit_surface_events" else { return false }
        await runEmitSurfaceEvents(f, h)
        return true
    }

    /// Records what it is asked to present instead of asking UIKit, so the presented SwiftUI root — and the
    /// manager's closures inside it — are reachable without a window.
    final class ContentStampCapturingController: UIViewController {
        var captured: UIViewController?
        override func present(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            captured = vc
            completion?()
        }
    }

    /// A store that answers every purchase with success.
    final class ContentStampSucceedingBridge: BillingBridgeProtocol, @unchecked Sendable {
        let isConsumable: Bool
        init(isConsumable: Bool) { self.isConsumable = isConsumable }
        func purchase(productId: String, appAccountToken: UUID?) async throws -> PurchaseResult {
            PurchaseResult(
                productId: productId, transactionId: "txn_fixture_\(UUID().uuidString.prefix(8))", price: 9.99,
                currency: "USD", provider: "storekit2", isSubscription: false, isConsumable: isConsumable
            )
        }
        func restore(appAccountToken: UUID?) async throws -> [String] { [] }
        func getEntitlements(appAccountToken: UUID?) async -> [String] { [] }
    }

    @MainActor
    private func runEmitSurfaceEvents(_ f: Fixture, _ h: Harness) async {
        let action = f.action.raw
        guard let surface = action["surface"]?.stringValue,
              let items = f.setup.config?.objectValue?["items"]?.arrayValue else {
            return XCTFail("[\(f.id)] emit_surface_events needs action.surface and setup.config.items")
        }
        for item in items {
            guard let doc = item.foundation as? [String: Any], let id = doc["id"] as? String else {
                return XCTFail("[\(f.id)] every setup.config.items entry needs an id")
            }
            let drive = (action["drive"]?.objectValue?[id]?.arrayValue ?? []).compactMap(\.stringValue)
            let start = h.events.count
            let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixture.\(UUID().uuidString)")
            let rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)

            switch surface {
            case "onboarding_flow":
                await driveFlow(f, h, rcm: rcm, id: id, doc: doc, drive: drive)
            case "paywall", "paywall_purchase":
                await drivePaywall(f, h, rcm: rcm, id: id, doc: doc, drive: drive,
                                   purchase: surface == "paywall_purchase")
            case "in_app_message":
                await driveMessage(f, h, rcm: rcm, id: id, doc: doc, drive: drive)
            case "survey":
                await driveSurvey(f, h, rcm: rcm, id: id, doc: doc, drive: drive)
            default:
                return XCTFail("[\(f.id)] emit_surface_events: no iOS driver for surface '\(surface)'")
            }
            // Only the events this item's drive list names are part of the contract.
            let kept = h.events[start...].filter { drive.contains($0.event_name) }
            h.events = Array(h.events[..<start]) + kept
        }
    }

    @MainActor
    private func waitForEvent(_ h: Harness, _ name: String, after start: Int, count: Int = 1, timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while h.events[start...].filter({ $0.event_name == name }).count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Onboarding

    @MainActor
    private func driveFlow(_ f: Fixture, _ h: Harness, rcm: RemoteConfigManager, id: String, doc: [String: Any], drive: [String]) async {
        rcm._applyIndexedItemForTesting(indexPath: "onboarding_index", id: id, data: doc)
        let manager = OnboardingFlowManager(remoteConfigManager: rcm, eventTracker: h.tracker)
        let presenter = ContentStampCapturingController()
        guard manager.present(flowId: id, from: presenter, delegate: nil),
              let host = (presenter.captured as? UIHostingController<OnboardingFlowHost>)?.rootView else {
            return XCTFail("[\(f.id)] flow '\(id)' was not presented")
        }
        let stepId = host.flow.steps.first?.id ?? ""
        for name in drive {
            switch name {
            case "onboarding_flow_started": break  // emitted by present
            case "onboarding_step_viewed": host.onStepViewed(stepId, 0)
            case "onboarding_step_completed": host.onStepCompleted(stepId, 0, nil)
            case "onboarding_step_skipped": host.onStepSkipped(stepId, 0)
            case "onboarding_flow_completed": host.onFlowCompleted([:])
            case "onboarding_flow_dismissed": host.onFlowDismissed(stepId, 0)
            default: XCTFail("[\(f.id)] no onboarding driver step for '\(name)'")
            }
        }
        // The host's closures hold the manager weakly, as the SDK's own instance is held on a device.
        withExtendedLifetime(manager) {}
    }

    // MARK: - Paywall (+ purchase)

    @MainActor
    private func drivePaywall(
        _ f: Fixture, _ h: Harness, rcm: RemoteConfigManager, id: String, doc: [String: Any], drive: [String], purchase: Bool
    ) async {
        rcm._applyIndexedItemForTesting(indexPath: "paywall_index", id: id, data: doc)
        let consumable = f.action.raw["product_type"]?.stringValue == "consumable"
        let manager = PaywallManager(
            remoteConfigManager: rcm,
            billingBridge: ContentStampSucceedingBridge(isConsumable: consumable),
            billingPolicy: BillingOwnership.policy(for: .storeKit2, bridgeLinked: true),
            eventTracker: h.tracker
        )
        let start = h.events.count
        let presenter = ContentStampCapturingController()
        let customData = (f.action.raw["custom_data"]?.foundation as? [String: Any])
        manager.present(
            id: id, from: presenter,
            context: PaywallContext(placement: f.action.raw["placement"]?.stringValue ?? "fixture", customData: customData),
            delegate: nil
        )
        await waitForEvent(h, "paywall_view", after: start)
        guard let paywall = (presenter.captured as? UIHostingController<PaywallRenderer>)?.rootView else {
            return XCTFail("[\(f.id)] paywall '\(id)' was not presented")
        }
        for name in drive {
            switch name {
            case "paywall_view": break  // emitted by present
            case "paywall_close": paywall.onDismiss(.dismissed)
            case "purchase_started":
                guard purchase, let plan = paywall.config.plans?.first else {
                    return XCTFail("[\(f.id)] paywall '\(id)' has no plan to buy")
                }
                paywall.onPlanSelected(plan, [:])
            case "purchase_completed":
                await waitForEvent(h, "purchase_completed", after: start)
                // Let the post-purchase work the success path queues settle before the next item.
                await SharedFixtureTests.drainMainQueue()
            default: XCTFail("[\(f.id)] no paywall driver step for '\(name)'")
            }
        }
        withExtendedLifetime(manager) {}
    }

    // MARK: - In-app message

    @MainActor
    private func driveMessage(_ f: Fixture, _ h: Harness, rcm: RemoteConfigManager, id: String, doc: [String: Any], drive: [String]) async {
        defer { UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).shown") }
        rcm._parseMessageDocForTesting(id: id, data: doc)
        var shown: [UIViewController] = []
        var surface = MessageSurface.live
        surface.host = { UIViewController() }
        surface.show = { _, _, content in shown.append(content) }
        surface.close = { _, done in done() }
        surface.observeActivation = { _ in {} }
        let manager = MessageManager(remoteConfigManager: rcm, eventTracker: h.tracker, surface: surface)
        let trigger = (doc["trigger_rules"] as? [String: Any])?["event"] as? String ?? ""
        for name in drive {
            switch name {
            case "in_app_message_shown":
                manager.onEvent(eventName: trigger, properties: nil)
                await SharedFixtureTests.drainMainQueue()
            case "in_app_message_clicked":
                guard let renderer = (shown.last as? UIHostingController<MessageRenderer>)?.rootView else {
                    return XCTFail("[\(f.id)] message '\(id)' was not shown")
                }
                renderer.onCTATap()
                await SharedFixtureTests.drainMainQueue()
            case "in_app_message_dismissed":
                manager.dismissOnScreenForTesting()
                await SharedFixtureTests.drainMainQueue()
            default: XCTFail("[\(f.id)] no message driver step for '\(name)'")
            }
        }
        withExtendedLifetime(manager) {}
    }

    // MARK: - Survey

    @MainActor
    private func driveSurvey(_ f: Fixture, _ h: Harness, rcm: RemoteConfigManager, id: String, doc: [String: Any], drive: [String]) async {
        rcm._applyIndexedItemForTesting(indexPath: "survey_index", id: id, data: doc)
        let manager = SurveyManager(remoteConfigManager: rcm, eventTracker: h.tracker)
        manager.updateConfigs(rcm.getSurveyConfigs())
        var answered: ((String, SurveyQuestion, SurveyAnswer) -> Void)?
        var finish: ((SurveyResult) -> Void)?
        var questions: [SurveyQuestion] = []
        manager.presentForTesting = { config, onAnswered, completion in
            questions = config.questions ?? []
            answered = onAnswered
            finish = completion
        }
        let fixtureAnswers = (f.action.raw["answers"]?.foundation as? [String: Any]) ?? [:]
        var given: [SurveyAnswer] = []
        for name in drive {
            switch name {
            case "survey_shown":
                manager.present(surveyId: id)
            case "survey_question_answered":
                for q in questions {
                    guard let qid = q.id, let value = fixtureAnswers[qid] else { continue }
                    let answer = SurveyAnswer(question_id: qid, answer: value)
                    given.append(answer)
                    answered?(doc["name"] as? String ?? "", q, answer)
                }
            case "survey_completed": finish?(.completed(answers: given))
            case "survey_dismissed": finish?(.dismissed(answeredCount: given.count))
            default: XCTFail("[\(f.id)] no survey driver step for '\(name)'")
            }
        }
        await SharedFixtureTests.drainMainQueue()
        withExtendedLifetime(manager) {}
    }
}
