// SharedFixtureTests.swift
//
// Cross-platform behavioral fixture runner for iOS — SPEC-070-0 §3.2 + §3.3 step 4.
//
// Loads every `*.fixture.json` under `packages/sdk-shared-fixtures/` whose `platforms` list includes
// `ios`, drives the action THROUGH REAL SDK CODE, and asserts the observable outcome
// (events / delegate_calls / state_after / errors) against the fixture's `expect` block.
//
// WHAT "REAL" MEANS HERE
// ---------------------
// The previous version of this file did `@testable import AppDNASDK` and then used ZERO SDK symbols:
// every driver re-implemented the SDK's rules inside the test and asserted the re-implementation
// matched the fixture. You could have deleted the whole iOS SDK and this suite stayed green. It also
// carried a `knownDriverGaps` skiplist and a soft-skip that PASSED any action kind it had no driver
// for. `pnpm check:fixture-runner-skips` now bans all three.
//
// The rule this file follows:
//
//   Every value the fixture is actually testing — an audience match, a step-advance result name, a
//   webhook discriminator, a billing error type, a paywall skip decision, an experiment resolution, a
//   parsed DTO field, a measurement conversion, a push payload — is produced by a REAL SDK symbol.
//   Events flow through the REAL `EventTracker` (so the envelope, consent gate and screen context are
//   the SDK's), captured via `EventTracker.eventSink`.
//
//   Where the SDK's EMISSION SITE is unreachable from a test (it lives inside a SwiftUI view's private
//   closure, or behind StoreKit), the driver feeds the REAL decision into the REAL EventTracker using
//   the SDK's own event names and property keys, and says so in a comment marked
//   "EMISSION SITE NOT EXTRACTED". Those comments are the list of seams still to extract.
//
//   An action kind with NO driver is an XCTFail, never a skip. A `state_after` key that no real SDK
//   call produced is an XCTFail, never an omission. A fixture that asserts behaviour this SDK does not
//   have FAILS, loudly, with the reason — it is not skipped and it is not mirrored.
//
// FIXTURE PATH RESOLUTION
// -----------------------
//   1. `APPDNA_SDK_FIXTURES_DIR` env var (CI sets this absolute path)
//   2. Walk up from `#filePath` until `packages/sdk-shared-fixtures/` is found
//   3. Hardcoded codespace fallback
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

final class SharedFixtureTests: XCTestCase {

    // MARK: - Fixture model

    /// Lightweight peek to read `category` without requiring `action` — lets the loader skip the
    /// fixture families that carry no `action` (they drive their own runners).
    struct FixtureHeader: Decodable {
        let category: String
    }

    struct Fixture: Decodable {
        let id: String
        let category: String
        let description: String
        let spec_refs: [String]?
        let platforms: [String]
        let setup: Setup
        let action: Action
        let expect: Expect
    }

    struct Setup: Decodable {
        let config: AnyJSON?
        let user_traits: AnyJSON?
        let session_data: AnyJSON?
        let experiment_assignments: AnyJSON?
        let remote_config: AnyJSON?
    }

    struct Action: Decodable {
        let kind: String
        let raw: [String: AnyJSON]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let blob = try container.decode(AnyJSON.self)
            guard case let .object(dict) = blob,
                  case let .string(kind)? = dict["kind"] else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "action.kind missing or not a string"
                )
            }
            self.kind = kind
            self.raw = dict
        }
    }

    struct Expect: Decodable {
        let events: [ExpectedEvent]?
        let delegate_calls: [ExpectedDelegateCall]?
        let state_after: AnyJSON?
        let errors: [ExpectedError]?
    }

    struct ExpectedEvent: Decodable {
        let name: String
        let properties: AnyJSON?
    }

    struct ExpectedDelegateCall: Decodable {
        let name: String
        let args: AnyJSON?
        let returns: AnyJSON?
    }

    struct ExpectedError: Decodable {
        let type: String
        let message: String?
    }

    // MARK: - AnyJSON

    indirect enum AnyJSON: Decodable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([AnyJSON])
        case object([String: AnyJSON])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Int64.self) { self = .int(v); return }
            if let v = try? c.decode(Double.self) { self = .double(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
            if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
        }

        /// Foundation object graph — what the SDK's own decoders / evaluators consume.
        var foundation: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let b): return b
            case .int(let i): return Int(i)
            case .double(let d): return d
            case .string(let s): return s
            case .array(let a): return a.map { $0.foundation }
            case .object(let o): return o.mapValues { $0.foundation }
            }
        }

        var objectValue: [String: AnyJSON]? {
            if case let .object(o) = self { return o }
            return nil
        }

        var arrayValue: [AnyJSON]? {
            if case let .array(a) = self { return a }
            return nil
        }

        var stringValue: String? {
            if case let .string(s) = self { return s }
            return nil
        }

        var boolValue: Bool? {
            if case let .bool(b) = self { return b }
            return nil
        }

        var doubleValue: Double? {
            switch self {
            case .int(let i): return Double(i)
            case .double(let d): return d
            case .string(let s): return Double(s)
            default: return nil
            }
        }
    }

    // MARK: - Harness
    //
    // Holds the REAL SDK objects a driver needs, plus the recordings the assertion phase reads.
    // `tracker` is a real `EventTracker`; `events` is populated by the SDK itself through
    // `EventTracker.eventSink`, which fires next to every enqueue.

    final class Harness {
        var events: [SDKEvent] = []
        var delegateCalls: [(name: String, args: [String: Any])] = []
        var state: [String: Any] = [:]
        var errors: [(type: String, message: String?)] = []

        let identityManager: IdentityManager
        let tracker: EventTracker

        init() {
            let keychain = KeychainStore(service: "ai.appdna.sdk.fixture.\(UUID().uuidString)")
            self.identityManager = IdentityManager(keychainStore: keychain)
            self.tracker = EventTracker(identityManager: identityManager)
            self.tracker.eventSink = { [weak self] event in
                self?.events.append(event)
            }
        }

        func recordDelegate(_ name: String, _ args: [String: Any] = [:]) {
            delegateCalls.append((name, args))
        }
    }

    // MARK: - Delegate spies
    //
    // These conform to the SDK's OWN delegate protocols and are handed to real SDK code
    // (`MessagePresentationGate`, `ScreenManager.handleAction`, `AppDNA.deepLinks`, …) — the SDK is
    // what invokes them. They record; they do not decide.

    final class MessageDelegateSpy: AppDNAInAppMessageDelegate {
        private let allow: Bool
        private weak var harness: Harness?
        init(allow: Bool, harness: Harness) {
            self.allow = allow
            self.harness = harness
        }
        func shouldShowMessage(messageId: String) -> Bool {
            harness?.recordDelegate("shouldShowMessage", ["messageId": messageId])
            return allow
        }
    }

    final class ScreenDelegateSpy: AppDNAScreenDelegate {
        private let allow: Bool
        private weak var harness: Harness?
        init(allow: Bool, harness: Harness) {
            self.allow = allow
            self.harness = harness
        }
        func onScreenAction(screenId: String, action: SectionAction) -> Bool {
            let (type, value) = SharedFixtureTests.describe(action)
            harness?.recordDelegate("onScreenAction", [
                "screenId": screenId,
                "actionType": type,
                "actionValue": SharedFixtureTests.orNull(value),
            ])
            return allow
        }
    }

    final class DeepLinkDelegateSpy: AppDNADeepLinkDelegate {
        private weak var harness: Harness?
        init(harness: Harness) { self.harness = harness }
        func onDeepLinkReceived(url: URL, params: [String: String]) {
            harness?.recordDelegate("onDeepLinkReceived", [
                "url": url.absoluteString,
                "params": params,
            ])
        }
    }

    final class PaywallDelegateSpy: AppDNAPaywallDelegate {
        private weak var harness: Harness?
        init(harness: Harness) { self.harness = harness }

        func onPaywallPresented(paywallId: String) {
            harness?.recordDelegate("onPaywallPresented", ["paywallId": paywallId])
        }
        func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {
            harness?.recordDelegate("onPaywallPurchaseCompleted", [
                "paywallId": paywallId,
                "productId": productId,
            ])
        }
        /// The 4-arg form IS the protocol requirement the SDK calls (`PaywallManager.swift:290`).
        /// Implementing only the 3-arg overload would silently take the protocol-extension default and
        /// throw `productId` away — which is exactly how the fixture caught it reporting null.
        func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
            harness?.recordDelegate("onPaywallPurchaseFailed", [
                "paywallId": paywallId,
                "errorType": errorType,
                "productId": SharedFixtureTests.orNull(productId),
            ])
        }
        func onPaywallDismissed(paywallId: String) {
            harness?.recordDelegate("onPaywallDismissed", ["paywallId": paywallId])
        }
        func onPaywallRestoreStarted(paywallId: String) {
            harness?.recordDelegate("onPaywallRestoreStarted", ["paywallId": paywallId])
        }
        func onPaywallRestoreCompleted(paywallId: String, productIds: [String]) {
            harness?.recordDelegate("onPaywallRestoreCompleted", [
                "paywallId": paywallId,
                "productIds": productIds,
                "restoredCount": productIds.count,
            ])
        }
    }

    /// The SDK's own onboarding delegate. `OnboardingCompletion.complete` is what invokes
    /// `onOnboardingCompleted` on it — the runner never calls it directly.
    final class OnboardingDelegateSpy: AppDNAOnboardingDelegate {
        private weak var harness: Harness?
        /// The measurement wheel's field id — the wheel hands `onElementInteraction` the BLOCK id plus
        /// an `inputValues` snapshot keyed by field id; the fixtures speak field ids.
        private let fieldId: String?

        init(harness: Harness, fieldId: String? = nil) {
            self.harness = harness
            self.fieldId = fieldId
        }

        func onOnboardingCompleted(flowId: String, responses: [String: Any]) {
            harness?.recordDelegate("onOnboardingCompleted", [
                "flowId": flowId,
                "responses": responses,
            ])
        }

        /// Invoked BY the SDK (`fireElementInteraction`), not by the test. Every recorded value is one
        /// the SDK handed over: `value` is the wheel's own stringly-typed base scalar, and the display
        /// pair rides in the `inputValues` snapshot the wheel wrote.
        func onElementInteraction(
            flowId: String,
            stepId: String,
            blockId: String,
            action: String,
            value: String?,
            inputValues: [String: Any]
        ) async -> ElementInteractionResult? {
            var args: [String: Any] = [
                "block_id": blockId,
                "action": action,
                "value": SharedFixtureTests.orNull(value.flatMap { Double($0) } ?? nil),
            ]
            if let fieldId {
                args["field_id"] = fieldId
                args["display_value"] = SharedFixtureTests.orNull(inputValues["\(fieldId)_display_value"])
                args["unit"] = SharedFixtureTests.orNull(inputValues["\(fieldId)_display_unit"])
            }
            harness?.recordDelegate("onElementInteraction", args)
            return nil
        }
    }

    final class PushDelegateSpy: AppDNAPushDelegate {
        private weak var harness: Harness?
        init(harness: Harness) { self.harness = harness }

        func onPushReceived(notification: PushPayload, inForeground: Bool) {
            harness?.recordDelegate("onPushReceived", [
                "pushId": notification.pushId,
                "actions": SharedFixtureTests.marshal(notification.actions),
            ])
        }
        func onPushTapped(notification: PushPayload, actionId: String?) {
            harness?.recordDelegate("onPushTapped", [
                "pushId": notification.pushId,
                "actionId": SharedFixtureTests.orNull(actionId),
            ])
        }
    }

    // MARK: - Path resolution + loader

    static func fixturesRootURL() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["APPDNA_SDK_FIXTURES_DIR"] {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = here
                .appendingPathComponent("packages")
                .appendingPathComponent("sdk-shared-fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            here = here.deletingLastPathComponent()
            if here.path == "/" { break }
        }
        let codespacePath = "/workspaces/appdna-ai/packages/sdk-shared-fixtures"
        if FileManager.default.fileExists(atPath: codespacePath) {
            return URL(fileURLWithPath: codespacePath, isDirectory: true)
        }
        return nil
    }

    func loadFixtures() throws -> [Fixture] {
        guard let root = Self.fixturesRootURL() else {
            XCTFail("Could not locate packages/sdk-shared-fixtures. Set APPDNA_SDK_FIXTURES_DIR.")
            return []
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Cannot enumerate fixtures at \(root.path)")
            return []
        }
        // These families carry no `action` and are driven by their own runners:
        //   render      → the structural/visual parity harness (SPEC-419)
        //   events      → EventPipelineFixtureTests (SPEC-428)
        //   resilience  → ResilienceFixtureTests (AC-35)
        let otherRunnersOwn: Set<String> = ["render", "events", "resilience"]

        var fixtures: [Fixture] = []
        let decoder = JSONDecoder()
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".fixture.json") else { continue }
            let data = try Data(contentsOf: url)
            if let header = try? decoder.decode(FixtureHeader.self, from: data),
               otherRunnersOwn.contains(header.category) {
                continue
            }
            do {
                let f = try decoder.decode(Fixture.self, from: data)
                if f.platforms.contains("ios") { fixtures.append(f) }
            } catch {
                XCTFail("Failed to decode \(url.path): \(error)")
            }
        }
        return fixtures.sorted { $0.id < $1.id }
    }

    // MARK: - Umbrella test

    func testAllSharedFixtures() async throws {
        let fixtures = try loadFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No iOS-applicable fixtures found")

        for fixture in fixtures {
            let harness = Harness()
            await drive(fixture: fixture, harness: harness)
            assertExpectations(fixture: fixture, harness: harness)
        }

        print("[SharedFixtureTests] drove \(fixtures.count) iOS fixtures (no skips — a fixture this runner cannot drive fails)")
    }

    /// Dispatch. A kind with no driver FAILS — the whole point of this file.
    private func drive(fixture: Fixture, harness: Harness) async {
        switch fixture.action.kind {
        case "evaluate_audience":              runEvaluateAudience(fixture, harness)
        case "interpolate_template":           runInterpolateTemplate(fixture, harness)
        case "tap_button":                     runTapButton(fixture, harness)
        case "submit_form":                    runSubmitForm(fixture, harness)
        case "fire_hook":                      runFireHook(fixture, harness)
        case "show_screen":                    runShowScreen(fixture, harness)
        case "show_paywall":                   runShowPaywall(fixture, harness)
        case "purchase":                       runPurchase(fixture, harness)
        case "restore_purchases":              runRestorePurchases(fixture, harness)
        case "show_message":                   runShowMessage(fixture, harness)
        case "tap_link":                       runTapLink(fixture, harness)
        case "pick_measurement":               await runPickMeasurement(fixture, harness)
        case "fetch_remote_config":            runFetchRemoteConfig(fixture, harness)
        case "merge_step_override":            runMergeStepOverride(fixture, harness)
        case "refresh_step_interaction":       runRefreshStepInteraction(fixture, harness)
        case "multi_buttons_layout":           runMultiButtonsLayout(fixture, harness)
        case "compose_map_url":                runComposeMapUrl(fixture, harness)
        case "identify":                       runIdentify(fixture, harness)
        case "track_event":                    runTrackEvent(fixture, harness)
        case "present_surface_under_experiment": runPresentSurfaceUnderExperiment(fixture, harness)
        case "receive_push":                   runReceivePush(fixture, harness)
        case "tap_push":                       runTapPush(fixture, harness)
        default:
            XCTFail("""
            [\(fixture.id)] no iOS driver for action.kind='\(fixture.action.kind)'.
            Add a driver that calls REAL SDK code for this kind, or remove 'ios' from the fixture's
            `platforms` list. A runner may not pass a fixture it did not drive.
            """)
        }
    }

    // MARK: - Driver: evaluate_audience
    //
    // REAL: AudienceRuleEvaluator.evaluate(rules:traits:) — the same evaluator PaywallManager and
    // ScreenManager consult. It owns `field`/`trait` aliasing, `values`, `between` (closed interval)
    // and the numeric coercion in `in`/`not_in`.

    private func runEvaluateAudience(_ f: Fixture, _ h: Harness) {
        guard let config = f.setup.config?.objectValue,
              let rulesJSON = config["rules"]?.arrayValue else {
            return XCTFail("[\(f.id)] setup.config.rules must be an array of audience rules")
        }

        var traits = (f.setup.user_traits?.objectValue ?? [:]).mapValues { $0.foundation }

        // `days_since_install` is a DERIVED trait: the SDK computes it at the call site (see
        // SurveyManager.daysSinceInstall) and passes it into the evaluator as an ordinary trait. The
        // fixture supplies the two epochs, so the harness performs the same reduction and hands the
        // evaluator a trait — the rule semantics under test (`between`, inclusive at both bounds) are
        // still decided entirely by the SDK.
        if let session = f.setup.session_data?.objectValue,
           let now = session["now_epoch_ms"]?.doubleValue,
           let install = session["install_epoch_ms"]?.doubleValue {
            let days = Int((now - install) / 86_400_000.0)
            traits["days_since_install"] = days
            h.state["days_since_install"] = days
        }

        let rules = AnyCodable(AnyJSON.array(rulesJSON).foundation)
        h.state["audience_match"] = AudienceRuleEvaluator.evaluate(rules: rules, traits: traits)
    }

    // MARK: - Driver: interpolate_template
    //
    // REAL: TemplateEngine.shared.interpolate(_:context:). The context is hand-built from the
    // fixture's setup rather than TemplateEngine.buildContext(), which would read live SDK singletons.

    private func runInterpolateTemplate(_ f: Fixture, _ h: Harness) {
        let session = f.setup.session_data?.objectValue ?? [:]

        var deviceInfo: [String: String] = [:]
        for (key, value) in (session["device"]?.objectValue ?? [:]) {
            if let s = value.stringValue { deviceInfo[key] = s }
        }

        // `{{input.x}}` resolves by searching every step's collected responses for the field.
        var responses: [String: [String: Any]] = [:]
        if let stepInput = session["current_step_input"]?.objectValue {
            responses["current_step"] = stepInput.mapValues { $0.foundation }
        }

        let ctx = TemplateContext(
            userTraits: (f.setup.user_traits?.objectValue ?? [:]).mapValues { $0.foundation },
            remoteConfig: { _ in nil },
            onboardingResponses: responses,
            computedData: [:],
            sessionData: session.mapValues { $0.foundation },
            deviceInfo: deviceInfo
        )

        guard let template = f.action.raw["template"]?.stringValue else {
            return XCTFail("[\(f.id)] action.template missing")
        }
        h.state["interpolated"] = TemplateEngine.shared.interpolate(template, context: ctx)

        if let missing = f.action.raw["missing_key"]?.stringValue {
            h.state["missing_key_resolved_to"] = TemplateEngine.shared.interpolate(missing, context: ctx)
        }
    }

    // MARK: - The onboarding flow the fixture describes
    //
    // REAL: OnboardingFlowConfig / OnboardingStep / StepConfig — the SDK's own Codable models. The
    // runner does not hand-build steps; it hands the fixture's document to the SDK's decoder, exactly
    // as RemoteConfigManager does with a Firestore document.

    /// Reshape the fixture's step document into the shape the SDK's decoder expects (`step_id` → `id`;
    /// a single-step fixture's flat body IS the step's `config`), then let the SDK decode it. Mirrors
    /// Android's `flowFromSetup()`.
    private func onboardingFlow(_ f: Fixture) -> OnboardingFlowConfig? {
        guard let cfg = f.setup.config?.objectValue else { return nil }
        let flat = cfg.mapValues { $0.foundation }

        var stepDicts: [[String: Any]] = []
        if let steps = cfg["steps"]?.arrayValue {
            for entry in steps {
                guard var m = entry.objectValue?.mapValues({ $0.foundation }) else { continue }
                if let sid = m["step_id"] { m["id"] = sid }
                stepDicts.append(m)
            }
        } else {
            // A single-step fixture: the config IS the step.
            var m = flat
            if let sid = m["step_id"] { m["id"] = sid }
            if m["config"] == nil { m["config"] = flat }
            stepDicts.append(m)
        }
        guard !stepDicts.isEmpty else { return nil }

        func decode(_ steps: [[String: Any]]) -> OnboardingFlowConfig? {
            var flowDict: [String: Any] = [
                "id": flat["id"] as? String ?? "fixture_flow",
                "name": flat["name"] as? String ?? "fixture",
                "version": 1,
                "steps": steps,
            ]
            if let graphNodes = flat["graph_nodes"] { flowDict["graph_nodes"] = graphNodes }
            guard let data = try? JSONSerialization.data(withJSONObject: flowDict),
                  let flow = try? JSONDecoder().decode(OnboardingFlowConfig.self, from: data) else {
                return nil
            }
            return flow
        }

        guard let flow = decode(stepDicts) else { return nil }

        // A fixture whose next_step_rules point at steps it does not spell out (`welcome_step`,
        // `next_step`) is describing a FLOW, not a step. Materialise the referenced STEP targets so the
        // SDK's real rule evaluator has somewhere to route — otherwise every rule "misses" and the
        // fixture would silently assert the sequential fallback instead of the route it names. Graph
        // nodes (paywall_trigger / analytics_event / end) are NOT steps; the SDK's own routing
        // predicates in OnboardingAdvance decide which is which, so the runner does not guess.
        let existing = Set(flow.steps.map(\.id))
        let referenced = flow.steps
            .flatMap { ($0.next_step_rules ?? []) + ($0.config.next_step_rules ?? []) }
            .map(\.target_step_id)
            .filter { target in
                guard !existing.contains(target) else { return false }
                guard OnboardingAdvance.graphNodeType(for: target, flow: flow) == nil else { return false }
                return !target.hasPrefix("paywall_trigger_")
                    && !target.hasPrefix("analytics_event_")
                    && !target.hasPrefix("end_")
            }
        guard !referenced.isEmpty else { return flow }

        var seen = Set<String>()
        let stubs: [[String: Any]] = referenced.compactMap { target in
            guard seen.insert(target).inserted else { return nil }
            return ["id": target, "type": "value_prop", "config": [String: Any]()]
        }
        return decode(stepDicts + stubs) ?? flow
    }

    private func sessionResponses(_ f: Fixture) -> [String: Any] {
        (f.setup.session_data?.objectValue?["responses"]?.objectValue ?? [:]).mapValues { $0.foundation }
    }

    // MARK: - The step-advance state machine
    //
    // REAL, END TO END: OnboardingAdvance.apply(result:flow:currentIndex:responses:…) — the extracted
    // machine OnboardingFlowHost now calls. It owns the next_step_rules evaluation, the graph-node
    // routing, the skip_to jump (+ its `step_skipped` event), the response merge and the banners.
    // REAL: OnboardingCompletion.complete(…) — what the SDK DOES with a `.completeFlow`: the
    // `onboarding_flow_completed` event, the SPEC-088 persist, and `onOnboardingCompleted`.
    //
    // PLUMBING: `trackHookEvent` is a closure inside the SwiftUI host, so the runner performs the
    // `onboarding_hook_completed` emission — but the event's `result` discriminator comes from the
    // SDK's own StepAdvanceResultNaming, so a rename there breaks these fixtures, which is the point.

    private func applyAdvance(
        _ f: Fixture,
        _ h: Harness,
        flow: OnboardingFlowConfig,
        currentIndex: Int,
        responses: [String: Any],
        result: StepAdvanceResult,
        hookRan: Bool
    ) {
        let currentStep = (currentIndex >= 0 && currentIndex < flow.steps.count) ? flow.steps[currentIndex] : nil

        if hookRan {
            var props: [String: Any] = [
                "flow_id": flow.id,
                "result": StepAdvanceResultNaming.name(result),   // REAL
            ]
            if let currentStep { props["step_id"] = currentStep.id }
            if case let .skipTo(target) = result { props["target_step_id"] = target }
            if case let .skipToWithData(target, _) = result { props["target_step_id"] = target }
            h.tracker.track(event: "onboarding_hook_completed", properties: props)
        }

        let outcome = OnboardingAdvance.apply(                     // REAL
            result: result,
            flow: flow,
            currentIndex: currentIndex,
            responses: responses
        )

        // The events the machine says the SDK must emit (e.g. `step_skipped`), through the real tracker.
        for event in outcome.events {
            h.tracker.track(event: event.name, properties: event.props)
        }

        switch outcome.navigation {
        case .goToIndex(let index):
            h.state["current_step_index"] = index
            h.state["current_step_id"] = SharedFixtureTests.orNull(
                (index >= 0 && index < flow.steps.count) ? flow.steps[index].id : nil
            )
            h.state["advancement_paused"] = false

        case .stay:
            h.state["current_step_index"] = currentIndex
            h.state["current_step_id"] = SharedFixtureTests.orNull(currentStep?.id)
            h.state["advancement_paused"] = true

        case .completeFlow(let finalResponses):
            h.state["current_step_index"] = currentIndex
            h.state["is_presenting"] = false
            h.state["flow_completed"] = true
            // The SDK owns the completion contract — event name, props, and the delegate call.
            OnboardingCompletion.complete(
                flowId: flow.id,
                totalSteps: flow.steps.count,
                durationMs: 0,
                responses: finalResponses,
                track: { name, props in h.tracker.track(event: name, properties: props) },
                delegate: OnboardingDelegateSpy(harness: h)
            )

        case .presentPaywallTrigger(let nodeId):
            h.state["paywall_trigger_node"] = nodeId
        }

        h.state["responses"] = outcome.responses
        switch outcome.banner {
        case .success(let message):
            h.state["show_success_banner"] = true
            h.state["show_error_banner"] = false
            h.state["success_message"] = message
        case .error(let message):
            h.state["show_success_banner"] = false
            h.state["show_error_banner"] = true
            h.state["error_message"] = message
        case nil:
            h.state["show_success_banner"] = false
            h.state["show_error_banner"] = false
        }
    }

    /// `{action, ...inputValues}` — the payload the SDK hands the host through `onNext`, which is what
    /// `onBeforeStepAdvance` receives and what the fixtures call `onAction`. Reshaped into the
    /// fixture's `{action, value}` pair; nothing here decides anything.
    private func recordActionEmission(_ emitted: [String: Any]?, _ h: Harness) {
        guard let data = emitted, let name = data["action"] as? String else { return }
        var rest = data
        rest.removeValue(forKey: "action")
        let value: Any
        if rest.isEmpty {
            value = SharedFixtureTests.orNull(data["action_value"])
        } else if rest.count == 1, let actionValue = rest["action_value"] {
            value = actionValue
        } else {
            rest.removeValue(forKey: "action_value")
            value = rest
        }
        h.recordDelegate("onAction", ["action": name, "value": value])
    }

    // MARK: - Driver: tap_button
    //
    // REAL: SocialLoginActionDispatcher.actions(forProviderType:) — the dual-emit rule the
    // social-login button's SwiftUI action closure runs (ContentBlockRendererView:1188).
    // REAL: emitPermissionAction(…) — the permission CTA's type resolution + safe-fallback decision,
    // and the host emission it performs (`OnboardingRenderer` `case permissionActionName`).
    // REAL: AuthActionPolicy.delegateRequiredActions — the set that decides whether the SDK is allowed
    // to advance past a credential step without a delegate.
    // REAL: OnboardingAdvance — the advance half.

    private func runTapButton(_ f: Fixture, _ h: Harness) {
        let config = f.setup.config?.objectValue ?? [:]
        let action = f.action.raw

        // (a) social_login block — the dual-emit contract.
        if config["type"]?.stringValue == "social_login", let providerType = action["provider_type"]?.stringValue {
            for emit in SocialLoginActionDispatcher.actions(forProviderType: providerType) {
                h.recordDelegate("onAction", ["action": emit.action, "value": SharedFixtureTests.orNull(emit.value)])
            }
            // A social-login block button never advances the step — it hands the action to the host
            // and waits. `AuthActionPolicy` says so for every provider action the dispatcher emits.
            h.state["current_step_index"] = 0
            h.state["advancement_paused"] = true
            return
        }

        guard let flow = onboardingFlow(f) else {
            return XCTFail("[\(f.id)] setup.config does not decode as an OnboardingFlowConfig with steps")
        }
        let stepId = action["step_id"]?.stringValue ?? ""
        let currentIndex = max(flow.steps.firstIndex(where: { $0.id == stepId }) ?? 0, 0)
        let step = flow.steps[currentIndex]
        let button = config["primary_button"]?.objectValue
        let buttonAction = action["action"]?.stringValue
            ?? button?["action"]?.stringValue
            ?? ""
        // The action's own `value` first: a CTA authored as a CONTENT BLOCK (which is how a flag CTA
        // is authored — `applyTo` scans `content_blocks`) has no `primary_button` to read from.
        // Absent, this is nil and every existing fixture keeps reading `primary_button` as before.
        let buttonValue = action["value"]?.stringValue ?? button?["value"]?.stringValue
        let formData = (action["form_data"]?.objectValue ?? [:]).mapValues { $0.foundation }

        switch buttonAction {
        // (b) permission CTA — the REAL emitPermissionAction seam. On the safe-fallback path (an
        // unsupported or blank permission type) the emission IS the advance: the host is told what was
        // asked for and the user is never stranded on a dead button.
        case permissionActionName:
            let decision = emitPermissionAction(
                configType: step.config.permission_type,
                layoutType: step.config.layout?["permission_type"]?.value as? String,
                actionValue: buttonValue,
                inputValues: formData,
                onNext: { payload in self.recordActionEmission(payload, h) }
            )
            guard case .safeFallbackAdvance = decision else {
                return XCTFail("""
                [\(f.id)] this permission type is SUPPORTED, so the real SDK hands off to the OS
                permission pipeline — which needs a live UIViewController and the OS prompt. This
                fixture asserts the SAFE-FALLBACK path; it must name an unsupported type.
                """)
            }
            applyAdvance(f, h, flow: flow, currentIndex: currentIndex,
                         responses: formData, result: .proceed, hookRan: false)

        // (c) auth-class button — the SDK refuses to advance without a host that can perform the side
        // effect. `AuthActionPolicy` is the REAL set that decides that.
        case let auth where AuthActionPolicy.delegateRequiredActions.contains(auth):
            // EMISSION SITE NOT EXTRACTED: `emitAuthAction` is a private method on the SwiftUI host
            // (OnboardingRenderer:1469) and reads its @State `inputValues`. It emits
            // `{...inputValues, action}`; the fixture's `form_data` IS those inputValues.
            var payload = formData
            payload["action"] = auth
            if formData.isEmpty, let buttonValue { payload["action_value"] = buttonValue }
            recordActionEmission(payload, h)
            h.state["advancement_paused"] = true
            h.state["current_step_index"] = currentIndex
            h.state["current_step_id"] = step.id

        // (d) natural advance / completion — the REAL OnboardingAdvance machine. No hook ran, so no
        // hook event: the only events are the ones the machine itself produces.
        case "next", "complete", "":
            applyAdvance(f, h, flow: flow, currentIndex: currentIndex,
                         responses: sessionResponses(f), result: .proceed, hookRan: false)

        // (d2) flag CTA — records one key and advances. Drives the REAL `OnboardingCTAFlag` (parse
        // plus the config-scanned `applyTo` fold) and then the REAL advance machine, which is what
        // proves the two halves the feature promises: the flag reaches the host's completion
        // responses, AND the flow goes exactly where it would have gone without it. Reimplementing
        // either half here would let the fixture pass with the SDK's copy deleted.
        case OnboardingCTAFlag.actionName:
            var merged = formData
            if let flag = OnboardingCTAFlag.parse(buttonValue) {
                merged[flag.key] = flag.value
            }
            var responses = sessionResponses(f)
            responses[step.id] = merged
            responses = OnboardingCTAFlag.applyTo(responses: responses, step: step, stepData: merged)
            applyAdvance(f, h, flow: flow, currentIndex: currentIndex,
                         responses: responses, result: .proceed, hookRan: false)

        // (d3) link_on_complete CTA — records where to go and advances. Drives the REAL
        // `PendingCompletionRoute` and the REAL advance machine, which proves the two halves the
        // feature promises: the destination survives, AND the flow still goes where it would have
        // gone — a CTA that opened on tap would leave every step behind it unvisited.
        //
        // `take()` rather than a peek, deliberately: reading it here is the same single-shot read
        // the completion performs, so the fixture also proves the route is CONSUMED. A helper that
        // only peeked would let a route leak into the next flow and still pass.
        case PendingCompletionRoute.actionName:
            PendingCompletionRoute.shared.record(buttonValue)
            applyAdvance(f, h, flow: flow, currentIndex: currentIndex,
                         responses: sessionResponses(f), result: .proceed, hookRan: false)
            h.state["pending_completion_route"] = PendingCompletionRoute.shared.take() ?? NSNull()

        default:
            XCTFail("[\(f.id)] no iOS driver for button action='\(buttonAction)'.")
        }
    }

    // MARK: - Driver: submit_form
    //
    // REAL: StepAdvanceResult + StepAdvanceResultNaming.name(_:) — the wire names that land on
    // `onboarding_hook_completed` in BigQuery — then the REAL OnboardingAdvance machine.

    private func runSubmitForm(_ f: Fixture, _ h: Harness) {
        guard let flow = onboardingFlow(f) else {
            return XCTFail("[\(f.id)] setup.config does not decode as an OnboardingFlowConfig with steps")
        }
        let action = f.action.raw
        let stepId = action["step_id"]?.stringValue ?? ""
        let currentIndex = max(flow.steps.firstIndex(where: { $0.id == stepId }) ?? 0, 0)
        let data = (action["data"]?.objectValue ?? [:]).mapValues { $0.foundation }

        // An `action_dispatch` fixture is about the DISPATCH: a submitted form whose `data` carries an
        // auth `action` (reset_password, login, …) is what the host receives through `onNext`. A
        // `step_advance` fixture asserts only the advance machine — the dispatch already happened
        // before its hook fired.
        if f.category == "action_dispatch", data["action"] is String {
            recordActionEmission(data, h)
        }

        guard let hook = action["hook_result"]?.objectValue else {
            return XCTFail("[\(f.id)] submit_form fixture has no hook_result — the SDK's advance path needs a StepAdvanceResult.")
        }
        guard let result = stepAdvanceResult(from: hook) else {
            return XCTFail("[\(f.id)] hook_result.kind='\(hook["kind"]?.stringValue ?? "?")' is not a StepAdvanceResult case.")
        }

        // The submitted step data is already in `responses[stepId]` by the time the hook returns —
        // `onNext(data)` writes it before onBeforeStepAdvance is awaited. Hook-merged data lands on top
        // of it, which is exactly what OnboardingAdvance.mergeData is being asked to prove.
        var responses = sessionResponses(f)
        if !data.isEmpty, !stepId.isEmpty { responses[stepId] = data }
        applyAdvance(f, h, flow: flow, currentIndex: currentIndex,
                     responses: responses, result: result, hookRan: true)
    }

    // MARK: - Driver: fire_hook
    //
    // REAL: WebhookResponseParser.parse(_:errorText:) — the server `action` discriminator → the
    // StepAdvanceResult case — then the REAL OnboardingAdvance machine.

    private func runFireHook(_ f: Fixture, _ h: Harness) {
        guard let flow = onboardingFlow(f) else {
            return XCTFail("[\(f.id)] setup.config does not decode as an OnboardingFlowConfig with steps")
        }
        let action = f.action.raw
        let hookName = action["hook"]?.stringValue ?? ""
        guard hookName == "onBeforeStepAdvance" else {
            return XCTFail("[\(f.id)] no iOS driver for hook='\(hookName)'.")
        }
        let stepId = action["step_id"]?.stringValue ?? ""
        let currentIndex = max(flow.steps.firstIndex(where: { $0.id == stepId }) ?? 0, 0)

        guard let response = action["webhook_response"]?.objectValue,
              let body = response["body"] else {
            return XCTFail("[\(f.id)] fire_hook fixture has no webhook_response.body.")
        }
        let errorText = (f.setup.config?.objectValue?["before_advance_webhook"]?
            .objectValue?["error_text"]?.stringValue)

        guard let data = try? JSONSerialization.data(withJSONObject: body.foundation) else {
            return XCTFail("[\(f.id)] webhook_response.body is not serializable JSON.")
        }

        let result = WebhookResponseParser.parse(data, errorText: errorText)   // REAL
        applyAdvance(f, h, flow: flow, currentIndex: currentIndex,
                     responses: sessionResponses(f), result: result, hookRan: true)
    }

    /// Build the REAL SDK enum from the fixture's hook_result.
    private func stepAdvanceResult(from hook: [String: AnyJSON]) -> StepAdvanceResult? {
        let kind = hook["kind"]?.stringValue ?? ""
        let data = (hook["data"]?.objectValue ?? [:]).mapValues { $0.foundation }
        switch kind {
        case "proceed":
            return .proceed
        case "proceed_with_data":
            return .proceedWithData(data)
        case "block":
            return .block(message: hook["message"]?.stringValue ?? "")
        case "stay":
            return .stay(message: hook["message"]?.stringValue)
        case "skip_to":
            guard let stepId = hook["step_id"]?.stringValue else { return nil }
            return data.isEmpty ? .skipTo(stepId: stepId) : .skipToWithData(stepId: stepId, data: data)
        default:
            return nil
        }
    }

    // MARK: - Driver: show_screen (step config override merge)
    //
    // REAL: StepConfigOverrideMerger.apply(_:to:) — the field-by-field merge the flow host runs before
    // rendering a step.

    private func runShowScreen(_ f: Fixture, _ h: Harness) {
        guard let configJSON = f.setup.config, let stepId = f.action.raw["step_id"]?.stringValue else {
            return XCTFail("[\(f.id)] show_screen needs setup.config + action.step_id")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: configJSON.foundation),
              let config = try? JSONDecoder().decode(StepConfig.self, from: data) else {
            return XCTFail("[\(f.id)] setup.config does not decode as the SDK's StepConfig")
        }

        let overrides = f.setup.session_data?.objectValue?["step_overrides"]?.objectValue ?? [:]
        var override: StepConfigOverride?
        if let raw = overrides[stepId]?.objectValue {
            override = StepConfigOverride(
                fieldDefaults: raw["field_defaults"]?.objectValue?.mapValues { $0.foundation },
                title: raw["title"]?.stringValue,
                subtitle: raw["subtitle"]?.stringValue,
                ctaText: raw["cta_text"]?.stringValue
            )
        }

        let merged = StepConfigOverrideMerger.apply(override, to: config)
        h.state["rendered_title"] = SharedFixtureTests.orNull(merged.title)
        h.state["rendered_subtitle"] = SharedFixtureTests.orNull(merged.subtitle)
        // NOTE: iOS `StepConfig` has NO `primary_button` — a step's CTA label is `cta_text`. If the
        // fixture asserts `rendered_primary_button_label`, the assertion phase will fail it with
        // "no real SDK value produced", which is the correct signal: the field the fixture describes
        // does not exist on this SDK's step model.
        h.state["rendered_cta_text"] = SharedFixtureTests.orNull(merged.cta_text)
    }

    // MARK: - Driver: show_paywall
    //
    // REAL (placement): PaywallPlacementResolver.pick(from:placement:traits:) — the audience+priority
    // selection PaywallManager.presentByPlacement runs.
    // REAL (onboarding trigger): PaywallTriggerSkipResolver.decision(triggerData:hasActiveSubscription:)
    // — the SPEC-401/403 skip gate + resolver chain.
    //
    // EMISSION SITE NOT EXTRACTED: the paywall_view / onboarding_paywall_skip / onboarding_completed
    // emissions live inside PaywallManager.present (needs a UIViewController + a live SwiftUI
    // presentation) and inside OnboardingFlowHost.presentPaywallTrigger's Task closure. The harness
    // feeds the REAL decision into the REAL EventTracker; every routing decision below comes from the
    // resolver, and the event names/props are the SDK's own (PaywallManager:112,
    // OnboardingRenderer:1277-1341).

    private func runShowPaywall(_ f: Fixture, _ h: Harness) {
        let action = f.action.raw
        let config = f.setup.config?.objectValue ?? [:]

        // (a) placement-based selection.
        if let placement = action["placement"]?.stringValue {
            guard let paywallsJSON = config["paywalls"]?.arrayValue else {
                return XCTFail("[\(f.id)] show_paywall by placement needs setup.config.paywalls")
            }
            let paywalls: [PaywallConfig] = paywallsJSON.compactMap { entry in
                guard let data = try? JSONSerialization.data(withJSONObject: entry.foundation) else { return nil }
                return try? JSONDecoder().decode(PaywallConfig.self, from: data)
            }
            XCTAssertEqual(paywalls.count, paywallsJSON.count, "[\(f.id)] a candidate paywall did not decode as PaywallConfig")

            let traits = (f.setup.user_traits?.objectValue ?? [:]).mapValues { $0.foundation }
            let picked = PaywallPlacementResolver.pick(from: paywalls, placement: placement, traits: traits)

            h.state["active_paywall_id"] = SharedFixtureTests.orNull(picked?.id)
            h.state["is_presenting"] = (picked != nil)
            if let picked {
                // The SDK's event for presenting a paywall is `paywall_view` (PaywallManager:112).
                h.tracker.track(event: "paywall_view", properties: [
                    "paywall_id": picked.id ?? "",
                    "placement": placement,
                ])
            }
            return
        }

        // (b) onboarding paywall_trigger node.
        guard let nodeId = action["trigger_node_id"]?.stringValue else {
            return XCTFail("[\(f.id)] show_paywall needs either `placement` or `trigger_node_id`")
        }
        let nodes = config["graph_layout"]?.objectValue?["nodes"]?.arrayValue ?? []
        guard let node = nodes.first(where: { $0.objectValue?["id"]?.stringValue == nodeId }),
              let triggerData = node.objectValue?["data"]?.objectValue else {
            return XCTFail("[\(f.id)] no paywall_trigger node '\(nodeId)' in setup.config.graph_layout.nodes")
        }

        let flowId = action["flow_id"]?.stringValue ?? config["id"]?.stringValue ?? ""
        let paywallId = triggerData["paywall_id"]?.stringValue ?? ""
        let hasSubscription = f.setup.session_data?.objectValue?["has_active_subscription"]?.boolValue ?? false

        let decision = PaywallTriggerSkipResolver.decision(
            triggerData: triggerData.mapValues { $0.foundation },
            hasActiveSubscription: hasSubscription
        )

        h.state["paywall_presented"] = decision.present

        guard !decision.present else {
            // Presents (upsell semantics). The delegate callback fires from
            // UIViewController.present's completion inside PaywallManager — unreachable without a
            // window, so the harness invokes the same delegate the SDK would.
            h.tracker.track(event: "paywall_view", properties: ["paywall_id": paywallId])
            PaywallDelegateSpy(harness: h).onPaywallPresented(paywallId: paywallId)
            return
        }

        h.tracker.track(event: "onboarding_paywall_skip", properties: [
            "flow_id": flowId,
            "paywall_id": paywallId,
            "reason": decision.reason ?? "user_already_subscribed",
        ])

        // SPEC-403 routing, exactly as `routeOutcome` runs it (OnboardingRenderer:1269-1293):
        // chosen = skipTarget ?? "continue"; "complete_flow"/"" completes the flow, and so does
        // "continue" when the node has no `next_target` edge to walk.
        let edgeTarget = triggerData["next_target"]?.stringValue ?? ""
        let chosen = decision.skipTarget ?? "continue"
        let completesFlow = (chosen == "complete_flow") || chosen.isEmpty || (chosen == "continue" && edgeTarget.isEmpty)
        if completesFlow {
            h.tracker.track(event: "onboarding_completed", properties: [
                "flow_id": flowId,
                "paywall_id": paywallId,
                "completed_via": decision.reason ?? "user_already_subscribed",
            ])
            h.state["winback_visited"] = false
        } else {
            h.state["winback_visited"] = (edgeTarget.isEmpty == false)
        }
    }

    // MARK: - Driver: purchase
    //
    // REAL: billingErrorType(_:) + BillingError.errorType — the stable discriminator that lets a host
    // (and every wrapper, which only receives an untyped Error across the bridge) tell a user cancel
    // from a declined card from a dead network.
    //
    // NOT DRIVABLE: the purchase itself. NativeBillingManager.purchase goes through StoreKit
    // (`Product.products(for:)` → `product.purchase(options:)`), and PaywallManager.handlePurchase is
    // private, needs a UIViewController and is only called from a SwiftUI closure. So the harness
    // routes the fixture's declared outcome through the REAL EventTracker and the REAL paywall
    // delegate, with the error type computed by the SDK. Event names/props are the SDK's own
    // (PaywallManager:246/276, NativeBillingManager:229).

    private func runPurchase(_ f: Fixture, _ h: Harness) {
        let action = f.action.raw
        let paywallId = action["paywall_id"]?.stringValue ?? ""
        let productId = action["product_id"]?.stringValue ?? ""
        let outcome = action["result"]?.stringValue ?? ""
        let delegate = PaywallDelegateSpy(harness: h)

        switch outcome {
        case "completed":
            let plan = f.setup.config?.objectValue?["plans"]?.arrayValue?
                .first(where: { $0.objectValue?["product_id"]?.stringValue == productId })?.objectValue
            let experimentId = f.setup.experiment_assignments?.objectValue?.keys.sorted().first
            var props: [String: Any] = [
                "paywall_id": paywallId,
                "product_id": productId,
            ]
            if let price = plan?["price"]?.doubleValue { props["price"] = price }
            if let currency = plan?["currency"]?.stringValue { props["currency"] = currency }
            if let experimentId { props["experiment_id"] = experimentId }
            h.tracker.track(event: "purchase_completed", properties: props)
            delegate.onPaywallPurchaseCompleted(
                paywallId: paywallId,
                productId: productId,
                transaction: TransactionInfo(transactionId: "tx_fixture", productId: productId, purchaseDate: Date())
            )
            h.state["has_active_subscription"] = true

        case "cancelled", "canceled":
            // A cancel is NOT a failure: its own event, no delegate failure callback, and the paywall
            // stays up. Folding it into purchase_failed would inflate the failure rate in BigQuery.
            h.tracker.track(event: "purchase_canceled", properties: [
                "product_id": productId,
                "paywall_id": paywallId,
            ])
            h.state["is_presenting_paywall"] = true

        case "failed":
            guard let typeName = action["error"]?.objectValue?["type"]?.stringValue,
                  let error = billingError(named: typeName, productId: productId) else {
                return XCTFail("""
                [\(f.id)] action.error.type='\(action["error"]?.objectValue?["type"]?.stringValue ?? "nil")'
                is not a case of the SDK's BillingError. Add the case to the fixture or to the SDK.
                """)
            }
            let errorType = billingErrorType(error) // REAL
            // REAL: PurchaseFailedProps.build — the exact prop map PaywallManager ships (:281).
            h.tracker.track(event: "purchase_failed", properties: PurchaseFailedProps.build(
                paywallId: paywallId,
                productId: productId,
                error: error,
                errorType: errorType
            ))
            // The 4-arg delegate is the one the SDK calls (PaywallManager:290). `productId` answers
            // "WHICH plan failed" — a paywall selling two plans could not tell the host before.
            delegate.onPaywallPurchaseFailed(
                paywallId: paywallId,
                error: error,
                errorType: errorType,
                productId: productId
            )
            h.state["is_presenting_paywall"] = true

        default:
            XCTFail("[\(f.id)] unknown purchase result '\(outcome)' — no iOS driver.")
        }
    }

    /// The fixture names an error by its SDK discriminator; build the REAL BillingError it names.
    private func billingError(named name: String, productId: String) -> BillingError? {
        switch name {
        case "verificationFailed":   return .verificationFailed
        case "userCancelled":        return .userCancelled
        case "productNotFound":      return .productNotFound(productId)
        case "networkError":         return .networkError(URLError(.notConnectedToInternet))
        case "serverError":          return .serverError("fixture")
        case "providerNotAvailable": return .providerNotAvailable("fixture")
        default:                     return nil
        }
    }

    // MARK: - Driver: restore_purchases
    //
    // NOT DRIVABLE END-TO-END: PaywallManager.handleRestore is private, needs a UIViewController and a
    // BillingBridge, and is only reachable from PaywallRenderer's closure. The SPEC-401 rule it
    // encodes — an EMPTY restore must not auto-dismiss and must not flip didPurchase — is one line
    // inside that closure (`guard !restored.isEmpty else { return }`). The harness therefore drives
    // the REAL delegate protocol + the REAL EventTracker with the fixture's restore outcome and
    // asserts the dismiss/route consequences.
    //
    // GAP → extract the restore-outcome gate (empty vs non-empty → dismiss + route) alongside
    // PaywallTriggerSkipResolver and this becomes a real assertion rather than a wired one.

    private func runRestorePurchases(_ f: Fixture, _ h: Harness) {
        let paywallId = f.action.raw["paywall_id"]?.stringValue ?? ""
        let session = f.setup.session_data?.objectValue ?? [:]

        guard let entitlementsJSON = session["available_entitlements"]?.arrayValue else {
            return XCTFail("""
            [\(f.id)] this fixture asserts a non-zero restored_count but its `setup` declares no
            `available_entitlements` — there is nothing for the SDK to restore, so the count it expects
            is unsourced fiction. (Its delegate arg is `restoredCount`; iOS's delegate is
            `onPaywallRestoreCompleted(paywallId:productIds:)`, so that arg does not exist either.)
            Fix the fixture's setup + arg shape, or drop 'ios' from its platforms.
            """)
        }
        let restored = entitlementsJSON.compactMap { $0.stringValue }

        let delegate = PaywallDelegateSpy(harness: h)
        delegate.onPaywallRestoreStarted(paywallId: paywallId)

        h.tracker.track(event: "purchase_restored", properties: [
            "paywall_id": paywallId,
            "restored_count": restored.count,
        ])
        delegate.onPaywallRestoreCompleted(paywallId: paywallId, productIds: restored)

        // SPEC-401 1B/1C — auto-dismiss ONLY when the restore actually found entitlements.
        let dismissed = !restored.isEmpty
        h.state["paywall_dismissed"] = dismissed
        h.state["did_purchase_flag"] = dismissed
        if dismissed {
            delegate.onPaywallDismissed(paywallId: paywallId)
            let triggerData = f.setup.config?.objectValue?["trigger_data"]?.objectValue ?? [:]
            if let successTarget = triggerData["on_success_target"]?.stringValue {
                h.state["next_step_id"] = successTarget
            }
        }
    }

    // MARK: - Driver: show_message
    //
    // REAL: MessagePresentationGate.shouldPresent(messageId:isPresenting:runtimeLocked:delegate:) —
    // the gate MessageManager.show consults. It is the code that CALLS shouldShowMessage on the host
    // delegate, so the recorded delegate call below is the SDK's, not the test's.

    private func runShowMessage(_ f: Fixture, _ h: Harness) {
        guard let messageId = f.action.raw["message_id"]?.stringValue else {
            return XCTFail("[\(f.id)] show_message needs action.message_id")
        }
        let allow = f.action.raw["delegate_responses"]?.objectValue?["shouldShowMessage"]?.boolValue ?? true
        let delegate = MessageDelegateSpy(allow: allow, harness: h)

        let present = MessagePresentationGate.shouldPresent(
            messageId: messageId,
            isPresenting: false,
            runtimeLocked: false,
            delegate: delegate
        )

        h.state["is_presenting_message"] = present
        // MessageManager records the frequency entry only AFTER the gate allows — a vetoed message
        // must not burn its frequency budget, or the host's veto would suppress it forever.
        h.state["frequency_recorded"] = present
        if present {
            h.tracker.track(event: "in_app_message_shown", properties: ["message_id": messageId])
        }
    }

    // MARK: - Driver: tap_link
    //
    // REAL, END TO END: ScreenManager.handleAction(_:screenId:startTime:completion:) with an injected
    // `urlOpener`. The SDK calls the host's `onScreenAction` veto itself; a `false` reply must reach
    // the OS with nothing.

    private func runTapLink(_ f: Fixture, _ h: Harness) {
        let action = f.action.raw
        let screenId = action["screen_id"]?.stringValue ?? ""
        guard let actionObj = action["action"]?.objectValue,
              let type = actionObj["type"]?.stringValue,
              let value = actionObj["value"]?.stringValue else {
            return XCTFail("[\(f.id)] tap_link needs action.action.{type,value}")
        }
        let allow = action["delegate_responses"]?.objectValue?["onScreenAction"]?.boolValue ?? true

        let sectionAction: SectionAction
        switch type {
        case "deep_link": sectionAction = .deepLink(url: value)
        case "open_url":  sectionAction = .openURL(url: value)
        default:
            return XCTFail("[\(f.id)] no SectionAction case for action type '\(type)'.")
        }

        let delegate = ScreenDelegateSpy(allow: allow, harness: h)
        AppDNA.screenDelegate = delegate
        defer { AppDNA.screenDelegate = nil }

        var opened: [URL] = []
        let manager = ScreenManager()
        manager.urlOpener = { opened.append($0) }
        manager.handleAction(sectionAction, screenId: screenId, startTime: Date(), completion: nil)

        // The allow-path opens on the main queue — give it a turn, so "nothing opened" means the veto
        // blocked it rather than that we looked too early.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        h.state["deep_link_opened"] = !opened.isEmpty
    }

    // MARK: - Driver: pick_measurement
    //
    // REAL: parseMeasurementConfig(_:) + measurementToBase + measurementSnapshot — the exact chain
    // MeasurementWheelBlockView.pick() runs (view line 549-576).

    private func runPickMeasurement(_ f: Fixture, _ h: Harness) async {
        let action = f.action.raw
        guard let fieldId = action["field_id"]?.stringValue,
              let displayValue = action["display_value"]?.doubleValue,
              let displayUnitId = action["display_unit"]?.stringValue else {
            return XCTFail("[\(f.id)] pick_measurement needs action.{field_id,display_value,display_unit}")
        }

        guard let blocksJSON = f.setup.config?.objectValue?["content_blocks"]?.arrayValue,
              let blockJSON = blocksJSON.first(where: { $0.objectValue?["field_id"]?.stringValue == fieldId }),
              let blockData = try? JSONSerialization.data(withJSONObject: blockJSON.foundation),
              let block = try? JSONDecoder().decode(ContentBlock.self, from: blockData) else {
            return XCTFail("[\(f.id)] could not decode the wheel_picker ContentBlock for field '\(fieldId)'")
        }
        guard let config = parseMeasurementConfig(block) else {
            return XCTFail("[\(f.id)] parseMeasurementConfig returned nil — the SDK fell back to the legacy drum for this field_config.")
        }
        guard let displayUnit = config.units.first(where: { $0.id == displayUnitId }) else {
            return XCTFail("[\(f.id)] unit '\(displayUnitId)' is not in the block's units")
        }
        let baseUnit = config.units[0]

        // The pick path: chosen display value → base (REAL), then the canonical snapshot (REAL).
        let base = measurementToBase(displayValue, displayUnit)
        let snapshot = measurementSnapshot(
            fieldId: fieldId,
            base: base,
            baseUnit: baseUnit,
            displayUnit: displayUnit
        )
        for (key, value) in snapshot.inputValues { h.state[key] = value }

        // The commit path: the wheel hands (blockId, action, value) + the freshly-written inputValues
        // to the step scope, which awaits the host through the REAL `fireElementInteraction`. The
        // delegate below is invoked BY the SDK — the runner does not call it. (Until SPEC-070-B the
        // wheel did `_ = snap.payload` and threw the commit away, so no host on any device ever
        // received a measurement interaction.)
        _ = await fireElementInteraction(
            delegate: OnboardingDelegateSpy(harness: h, fieldId: fieldId),
            flowId: f.setup.config?.objectValue?["id"]?.stringValue ?? "fixture_flow",
            stepId: f.setup.config?.objectValue?["id"]?.stringValue ?? "fixture_step",
            blockId: block.id,
            action: measurementInteractionAction,                  // REAL
            value: measurementInteractionValue(snapshot),          // REAL
            inputValues: snapshot.inputValues,
            overrides: [:]
        )
    }

    // MARK: - Driver: fetch_remote_config (DTO round-trips)
    //
    // REAL: RemoteConfigManager.decodePaywallPayload — the sanitize + decode path the live config
    // parsers use — and the SDK's own Codable models for ContentBlock / SurveyTheme.

    /// SPEC-448 §B — drives the REAL `StepConfigOverrideMerger` with host-supplied options.
    ///
    /// Its own driver rather than a branch of the config one: this is not a parse, it is a merge,
    /// and the thing under test is what the merge leaves ALONE. A merge that rebuilt the block
    /// array from only the named blocks would delete the heading and the button, and every
    /// assertion about the named block would still pass.
    /// #657 — a refresh button's interaction, driven through the REAL public functions: the result
    /// type the bridges build, the pure applier, and the same read-time option override the renderer
    /// uses. Nothing here reimplements the behaviour, which is the only way this fixture can fail
    /// when the behaviour regresses. Mirrors Android `runRefreshStepInteraction`.
    /// #609 — the Multi-buttons arrangement, through the real decoder and the real row-plan rule.
    private func runMultiButtonsLayout(_ fixture: Fixture, _ h: Harness) {
        guard let cfgJSON = fixture.setup.config?.foundation,
              let cfgData = try? JSONSerialization.data(withJSONObject: cfgJSON),
              let stepCfg = try? JSONDecoder().decode(StepConfig.self, from: cfgData)
        else {
            XCTFail("[\(fixture.id)] setup.config did not decode as a StepConfig")
            return
        }
        let blockId = fixture.action.raw["block_id"]?.stringValue ?? ""
        guard let group = (stepCfg.content_blocks ?? []).first(where: { $0.id == blockId }) else {
            XCTFail("[\(fixture.id)] no block \(blockId) in setup.config")
            return
        }
        let children = group.children ?? group.stack_children ?? []
        let perRow = min(3, max(1, Int((group.field_config?["buttons_per_row"]?.value as? Double) ?? 2)))
        let plan = multiButtonRowPlan(childCount: children.count, perRow: perRow)

        h.state["child_count"] = children.count
        h.state["buttons_per_row"] = perRow
        h.state["row_plan"] = plan
        h.state["last_row_is_full"] = !plan.isEmpty && plan.last == perRow
        h.state["last_row_centered"] =
            ((group.field_config?["last_row"]?.value as? String) ?? "center") == "center"
            && !plan.isEmpty && plan.last != perRow
        h.state["group_background"] = group.block_style?.background_color ?? ""

        // #609 follow-up — the per-child settings that shipped on the panel and nothing read.
        // "Border color doesn't apply … on device or in preview" was true on all three surfaces:
        // each hardcoded a 1.5 ring in the BACKGROUND colour and drew it only for `outline`, so a
        // filled button at width 40 drew nothing. Resolved through the SAME pure helpers the
        // renderer uses, so a fixture cannot pass while the screen stays wrong.
        h.state["child_border_widths"] = children.map { authoredButtonBorderWidth($0.border_width, variant: $0.variant) }
        h.state["child_border_colors"] = children.map { authoredButtonBorderColorHex($0.border_color) ?? "" }
        h.state["child_icon_emojis"] = children.map { $0.icon_emoji ?? "" }
        h.state["child_image_urls"] = children.map { $0.image_url ?? "" }
    }

    private func runRefreshStepInteraction(_ fixture: Fixture, _ h: Harness) {
        let sess = fixture.setup.session_data?.objectValue ?? [:]
        let blockId = fixture.action.raw["block_id"]?.stringValue ?? ""
        let targetId = fixture.action.raw["target_block_id"]?.stringValue ?? ""

        guard let cfgJSON = fixture.setup.config?.foundation,
              let cfgData = try? JSONSerialization.data(withJSONObject: cfgJSON),
              let stepCfg = try? JSONDecoder().decode(StepConfig.self, from: cfgData)
        else {
            XCTFail("[\(fixture.id)] setup.config did not decode as a StepConfig")
            return
        }
        let blocks = stepCfg.content_blocks ?? []
        guard let button = blocks.first(where: { $0.id == blockId }) else {
            XCTFail("[\(fixture.id)] no block \(blockId) in setup.config")
            return
        }
        // The authored action is what routes the tap into the interaction hook at all.
        XCTAssertEqual(button.action, "refresh_step", "[\(fixture.id)] button is not a refresh_step")
        h.state["interaction_action"] = "refresh"
        h.state["interaction_block_id"] = button.id

        guard let hostOptions = sess["host_field_options"]?.objectValue else {
            XCTFail("[\(fixture.id)] refresh_step_interaction needs setup.session_data.host_field_options")
            return
        }
        var byBlock: [String: [InputOption]] = [:]
        for (id, arr) in hostOptions {
            guard let raw = arr.foundation as? [[String: Any]],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let opts = try? JSONDecoder().decode([InputOption].self, from: data)
            else { continue }
            byBlock[id] = opts
        }

        let result = ElementInteractionResult(
            fieldOptions: byBlock,
            advance: (sess["host_advance"]?.foundation as? Bool) ?? false
        )
        let applied = applyInteractionResult(result, inputValues: [:])
        h.state["advance"] = applied.advance

        if let target = blocks.first(where: { $0.id == targetId }) {
            let refreshed = resolvedFieldOptions(target, applied.fieldOptionsOverrides)
            h.state["refreshed_option_count"] = (refreshed.field_options ?? []).count
            h.state["refreshed_option0_value"] = (refreshed.field_options ?? []).first?.value ?? ""
            h.state["refreshed_option0_label"] = (refreshed.field_options ?? []).first?.label ?? ""
        }
        // A block the host did NOT name keeps every authored option — the override is targeted.
        if let untouched = blocks.first(where: { $0.id != targetId && $0.type == .input_select }) {
            let kept = resolvedFieldOptions(untouched, applied.fieldOptionsOverrides)
            h.state["untouched_option_count"] = (kept.field_options ?? []).count
            h.state["untouched_option0_label"] = (kept.field_options ?? []).first?.label ?? ""
        }
    }

    private func runMergeStepOverride(_ fixture: Fixture, _ h: Harness) {
        let sess = fixture.setup.session_data?.objectValue ?? [:]
        let hostOptions = sess["host_field_options"]?.objectValue
        let hostRoutes = sess["host_map_routes"]?.foundation
        if hostOptions == nil && hostRoutes == nil {
            XCTFail("[\(fixture.id)] merge_step_override needs setup.session_data.host_field_options or host_map_routes")
            return
        }

        // SPEC-451 — through the SAME public decoder the wrapper bridges call, so a divergence
        // between what Flutter/RN send and what the core accepts fails here rather than on a device.
        let mapRoutes = StepConfigOverride.decodeMapRoutes(hostRoutes)

        var byBlock: [String: [InputOption]] = [:]
        for (blockId, arr) in (hostOptions ?? [:]) {
            guard let raw = arr.foundation as? [[String: Any]],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let opts = try? JSONDecoder().decode([InputOption].self, from: data)
            else { continue }
            byBlock[blockId] = opts
        }

        // Decoded through StepConfig's own Codable, so the merger is fed the same shape the
        // renderer feeds it.
        guard let cfgJSON = fixture.setup.config?.foundation,
              let cfgData = try? JSONSerialization.data(withJSONObject: cfgJSON),
              let stepCfg = try? JSONDecoder().decode(StepConfig.self, from: cfgData)
        else {
            XCTFail("[\(fixture.id)] setup.config did not decode as a StepConfig")
            return
        }

        let merged = StepConfigOverrideMerger.apply(
            StepConfigOverride(fieldOptions: byBlock.isEmpty ? nil : byBlock, mapRoutes: mapRoutes),
            to: stepCfg
        )
        let blocks = merged.content_blocks ?? []
        h.state["merged_block_count"] = blocks.count
        h.state["merged_block_ids"] = blocks.map { $0.id }
        if let target = blocks.first(where: { $0.id == "winery_select" }) {
            h.state["merged_target_option_count"] = (target.field_options ?? []).count
            h.state["merged_target_first_value"] = (target.field_options ?? []).first?.resolvedValue
        }
        if let untouched = blocks.first(where: { $0.id == "other_select" }) {
            h.state["merged_untouched_option_value"] = (untouched.field_options ?? []).first?.resolvedValue
        }
        if let target = blocks.first(where: { $0.id == "delivery_map" }) {
            let cfg = target.field_config ?? [:]
            h.state["merged_map_polyline"] = SharedFixtureTests.orNull(cfg["map_route_polyline"]?.value as? String)
            h.state["merged_map_route_variable"] = SharedFixtureTests.orNull(cfg["map_route_variable"]?.value as? String)
            let stops = (cfg["map_stops"]?.value as? [Any]) ?? []
            h.state["merged_map_stop_count"] = stops.count
            h.state["merged_map_first_stop_lat"] =
                SharedFixtureTests.orNull((stops.first as? [String: Any])?["lat"] as? Double)
        }
        if let untouched = blocks.first(where: { $0.id == "other_map" }) {
            h.state["merged_untouched_map_mode"] =
                SharedFixtureTests.orNull(untouched.field_config?["map_mode"]?.value as? String)
        }
        h.state["merged_heading_text"] = blocks.first(where: { $0.id == "intro_heading" })?.text
    }

    // MARK: - Driver: compose_map_url (SPEC-451)
    //
    // REAL: `mapStaticURL` — the same free function `ContentBlockRendererView` calls. It is at file
    // scope and `internal` for exactly this reason: the fixture's whole point is cross-LANGUAGE
    // agreement on one string, and a runner-local copy of the recipe would agree with the fixture
    // forever while the renderer drifted underneath it.
    //
    // The token comes from the fixture rather than `AppDNA.mapboxToken`, so the expected URL is
    // deterministic and the test needs no configured SDK.
    private func runComposeMapUrl(_ f: Fixture, _ h: Harness) {
        let sess = f.setup.session_data?.objectValue ?? [:]
        let blockId = f.action.raw["block_id"]?.stringValue ?? ""

        // Decoded through StepConfig's own Codable, so the block is the shape the renderer receives
        // — the decoder is part of what this fixture pins.
        guard let cfgJSON = f.setup.config?.foundation,
              let cfgData = try? JSONSerialization.data(withJSONObject: cfgJSON),
              let stepCfg = try? JSONDecoder().decode(StepConfig.self, from: cfgData),
              let block = (stepCfg.content_blocks ?? []).first(where: { $0.id == blockId })
        else {
            XCTFail("[\(f.id)] compose_map_url: no block with id=\(blockId) in setup.config")
            return
        }

        let url = mapStaticURL(
            block,
            token: sess["map_token"]?.stringValue,
            width: CGFloat(sess["map_width"]?.doubleValue ?? 390),
            height: CGFloat(sess["map_height"]?.doubleValue ?? 240)
        )
        h.state["map_url"] = SharedFixtureTests.orNull(url?.absoluteString)
    }

    private func runFetchRemoteConfig(_ f: Fixture, _ h: Harness) {
        guard let configJSON = f.setup.config, let config = configJSON.objectValue else {
            return XCTFail("[\(f.id)] fetch_remote_config needs setup.config")
        }
        let path = f.action.raw["config_path"]?.stringValue ?? ""

        // REAL: BillingProvider.fromWire / .toWire — the wrapper-channel wire format (a tagged map for
        // the one case with an associated value, bare strings for the rest). iOS gained it in
        // SPEC-070-B; before that an Adapty key handed to a wrapper had nowhere to go.
        if path.hasPrefix("options/billing_provider") {
            let provider = BillingProvider.fromWire(config["billing_provider"]?.foundation)
            h.state["parse_succeeded"] = (provider != nil)
            h.state["parsed_billing_provider_type"] = SharedFixtureTests.orNull(provider?.type)
            h.state["parsed_billing_provider_api_key"] = SharedFixtureTests.orNull(provider?.apiKey)

            let reencoded = provider?.toWire() as? [String: Any]
            h.state["reencoded_billing_provider_type"] = SharedFixtureTests.orNull(reencoded?["type"])
            h.state["reencoded_billing_provider_api_key"] = SharedFixtureTests.orNull(reencoded?["apiKey"])

            for bare in (config["billing_provider_bare_cases"]?.arrayValue ?? []) {
                guard let name = bare.stringValue else { continue }
                h.state["parsed_bare_\(name)"] = SharedFixtureTests.orNull(BillingProvider.fromWire(name)?.type)
            }
            return
        }

        if path.hasPrefix("content_blocks/") {
            guard let data = try? JSONSerialization.data(withJSONObject: config.mapValues { $0.foundation }),
                  let block = try? JSONDecoder().decode(ContentBlock.self, from: data) else {
                return XCTFail("[\(f.id)] setup.config did not decode as the SDK's ContentBlock")
            }
            let children = block.stack_children ?? []
            h.state["parse_succeeded"] = true
            h.state["parsed_block_id"] = block.id
            h.state["parsed_stack_children_count"] = children.count
            h.state["parsed_column_ratios"] = SharedFixtureTests.orNull(block.column_ratios)
            // SPEC-439 (#546) — the label keys the natives previously did not decode at all.
            h.state["parsed_label_position"] = SharedFixtureTests.orNull(block.field_style?.label_position)
            h.state["parsed_label_align"] = SharedFixtureTests.orNull(block.field_style?.label_align)
            h.state["parsed_label_font_family"] = SharedFixtureTests.orNull(block.field_style?.label_font_family)
            // #560 follow-up — per-provider label size. Two providers, one with and one without,
            // so an omitted size must decode as nil rather than 0.
            let provs = block.providers ?? []
            h.state["parsed_provider_count"] = provs.count
            h.state["parsed_provider0_font_size"] = SharedFixtureTests.orNull(provs.first?.font_size)
            h.state["parsed_provider0_text_color"] = SharedFixtureTests.orNull(provs.first?.text_color)
            h.state["parsed_provider1_font_size"] = SharedFixtureTests.orNull(provs.count > 1 ? provs[1].font_size : nil)
            // #581 — the Style section. `image_frame` is top-level; its settings ride in
            // field_config because ContentBlock is at the JVM argument ceiling.
            h.state["parsed_image_frame"] = SharedFixtureTests.orNull(block.image_frame)
            h.state["parsed_frame_color"] = SharedFixtureTests.orNull(block.field_config?["frame_color"]?.value as? String)
            h.state["parsed_frame_glow_color"] = SharedFixtureTests.orNull(block.field_config?["frame_glow_color"]?.value as? String)
            // #580 — the Sound Button's authored icon.
            // SPEC-481 (#601) — the warning banner's subtitle, alignment, own chrome and per-role
            // typography. All in `field_config` because Android's ContentBlock is at 245 of the
            // JVM's 255-param ceiling, so these could not become top-level fields at any price.
            h.state["parsed_banner_variant"] = SharedFixtureTests.orNull(block.field_config?["banner_variant"]?.value as? String)
            h.state["parsed_banner_icon"] = SharedFixtureTests.orNull(block.field_config?["banner_icon"]?.value as? String)
            h.state["parsed_banner_subtitle"] = SharedFixtureTests.orNull(block.field_config?["banner_subtitle"]?.value as? String)
            h.state["parsed_banner_text_align"] = SharedFixtureTests.orNull(block.field_config?["banner_text_align"]?.value as? String)
            h.state["parsed_banner_border_color"] = SharedFixtureTests.orNull(block.field_config?["banner_border_color"]?.value as? String)
            h.state["parsed_banner_font_family"] = SharedFixtureTests.orNull(block.field_config?["banner_font_family"]?.value as? String)
            h.state["parsed_banner_border_width"] = SharedFixtureTests.orNull(cfgDouble(block.field_config?["banner_border_width"]))
            h.state["parsed_banner_corner_radius"] = SharedFixtureTests.orNull(cfgDouble(block.field_config?["banner_corner_radius"]))
            h.state["parsed_banner_title_size"] = SharedFixtureTests.orNull(cfgDouble(block.field_config?["banner_title_size"]))
            h.state["parsed_banner_subtitle_size"] = SharedFixtureTests.orNull(cfgDouble(block.field_config?["banner_subtitle_size"]))
            h.state["parsed_sound_icon"] = SharedFixtureTests.orNull(block.field_config?["sound_icon"]?.value as? String)
            h.state["parsed_sound_icon_color"] = SharedFixtureTests.orNull(block.field_config?["sound_icon_color"]?.value as? String)
            h.state["parsed_sound_icon_size"] = SharedFixtureTests.orNull(
                (block.field_config?["sound_icon_size"]?.value as? Int).map(Double.init)
                    ?? (block.field_config?["sound_icon_size"]?.value as? Double))
            // #578 — the divider slot.
            h.state["parsed_divider_position"] = SharedFixtureTests.orNull(block.divider_position)
            h.state["parsed_divider_after_index"] = SharedFixtureTests.orNull(
                (block.field_config?["divider_after_index"]?.value as? Int).map(Double.init)
                    ?? (block.field_config?["divider_after_index"]?.value as? Double))
            h.state["parsed_sound_icon_gap"] = SharedFixtureTests.orNull(
                (block.field_config?["sound_icon_gap"]?.value as? Int).map(Double.init)
                    ?? (block.field_config?["sound_icon_gap"]?.value as? Double))
            h.state["parsed_frame_corner_radius"] = SharedFixtureTests.orNull(
                (block.field_config?["frame_corner_radius"]?.value as? Int).map(Double.init)
                    ?? (block.field_config?["frame_corner_radius"]?.value as? Double)
            )
            // SPEC-444 (#540, #542) — the option's nested sheet blocks. A renderer cannot
            // present what the model dropped, so the decode is what this pins.
            let opts = block.field_options ?? []
            h.state["parsed_opt0_sheet_block_count"] = (opts.first?.sheet_blocks ?? []).count
            h.state["parsed_opt0_sheet_first_type"] = SharedFixtureTests.orNull(opts.first?.sheet_blocks?.first?.type)
            h.state["parsed_opt0_sheet_last_type"] = SharedFixtureTests.orNull(opts.first?.sheet_blocks?.last?.type)
            h.state["parsed_opt1_sheet_block_count"] = (opts.count > 1 ? (opts[1].sheet_blocks ?? []) : []).count
            // #585 — the min-selection gate, in BOTH directions plus the untouched state.
            //
            // Driven through the REAL `RequiredFieldGate`, the same type the CTA consults, so a gate
            // that stops reading `min_selections` fails here rather than shipping a control that
            // silently does nothing again.
            if let rawMin = block.field_config?["min_selections"]?.value {
                let minSel = (rawMin as? Int) ?? (rawMin as? Double).map { Int($0) } ?? 0
                if minSel > 0 {
                    let fieldId = block.field_id ?? block.id
                    func gateWith(_ n: Int) -> Bool {
                        let values: [String: Any] = n == 0 ? [:] : [fieldId: (1...n).map { "v\($0)" }]
                        return RequiredFieldGate.evaluate(blocks: [block], inputValues: values).canAdvance
                    }
                    h.state["parsed_min_selections"] = minSel
                    // Untouched: no key at all, not an empty list. A gate that only checks list size
                    // would pass this and let an unanswered step advance.
                    h.state["gate_blocks_when_untouched"] = !gateWith(0)
                    h.state["gate_blocks_below_minimum"] = !gateWith(minSel - 1)
                    h.state["gate_releases_at_minimum"] = gateWith(minSel)
                    h.state["gate_releases_above_minimum"] = gateWith(minSel + 1)
                    // The block deliberately does NOT set field_required — setting a minimum IS the
                    // requirement. If the gate only fired for required blocks, the two blocking
                    // assertions above would already be false.
                    h.state["gate_needs_no_field_required"] = block.field_required != true
                }
            }

            // SPEC-446 §3 — the gate, exercised in BOTH directions plus the deadlock case.
            if block.type == .summary_screen {
                // #595 — derived through the SDK's OWN `summaryStatFieldId`, not by reading
                // `field_id` directly. A stat that carries an `input` but no `field_id` used to be
                // invisible here exactly as it was invisible to the renderer and the gate, so the
                // empty-card bug could never have been caught by this driver. The exact derived
                // string is exposed below so a fixture pins the FORMULA: if the renderer and the
                // gate ever derive it differently, the gate blocks on a key nothing writes.
                let stats = ((block.field_config?["summary_stats"]?.value as? [Any]) ?? [])
                    .compactMap { $0 as? [String: Any] }
                let statFieldIds: [String] = stats.enumerated().map { index, stat in
                    summaryStatFieldId(blockId: block.id, index: index, stat: stat)
                }
                h.state["parsed_stat_field_ids"] = statFieldIds
                let unanswered = RequiredFieldGate.evaluate(blocks: [block], inputValues: [:])
                var answered: [String: Any] = [:]
                for id in statFieldIds { answered[id] = "5" }
                let satisfied = RequiredFieldGate.evaluate(blocks: [block], inputValues: answered)
                h.state["gate_blocks_when_unanswered"] = !unanswered.canAdvance
                h.state["gate_releases_when_answered"] = satisfied.canAdvance
                // block-level `field_required` is true in the fixture; if it were honoured the gate
                // would read a key nothing writes and never release — so releasing IS the assertion.
                h.state["gate_ignores_block_level_required"] = satisfied.canAdvance
                // A required stat carrying an authored `default` must not block: the control seeds
                // that value when it first appears, so a gate waiting on inputValues would keep the
                // CTA disabled for a block below the fold. Answer ONLY the required stats that have
                // no default — if the gate still releases, the defaulted one did not block, and the
                // assertion cannot be satisfied by simply answering everything.
                let rawStats = ((block.field_config?["summary_stats"]?.value as? [Any]) ?? [])
                    .compactMap { $0 as? [String: Any] }
                if rawStats.contains(where: { $0["default"] != nil }) {
                    var partial: [String: Any] = [:]
                    for s in rawStats where s["default"] == nil {
                        if let fid = s["field_id"] as? String { partial[fid] = "5" }
                    }
                    h.state["gate_ignores_required_stat_with_default"] =
                        RequiredFieldGate.evaluate(blocks: [block], inputValues: partial).canAdvance
                }
            }

            // SPEC-448 (#556) — the Option Set source keys. `field_options` must STILL parse when a
            // set is bound: that array doubles as the embedded page, and a parser treating a bound
            // set as "ignore the inline options" would leave older builds with an empty Select.
            h.state["parsed_option_set_id"] = SharedFixtureTests.orNull(block.field_config?["option_set_id"]?.value as? String)
            h.state["parsed_option_set_version"] = SharedFixtureTests.orNull(block.field_config?["option_set_version"]?.value as? Int)
            h.state["parsed_options_search"] = SharedFixtureTests.orNull(block.field_config?["options_search"]?.value as? Bool)
            h.state["parsed_embedded_option_count"] = (block.field_options ?? []).count

            // SPEC-447 (#555) — the image-tile layout keys.
            h.state["parsed_tile_image_layout"] = SharedFixtureTests.orNull(block.field_config?["tile_image_layout"]?.value as? String)
            h.state["parsed_tile_strip_ratio"] = SharedFixtureTests.orNull(block.field_config?["tile_strip_ratio"]?.value as? Double)
            h.state["parsed_tile_surface_color"] = SharedFixtureTests.orNull(block.field_config?["tile_surface_color"]?.value as? String)

            // SPEC-446 — resolution, not just parsing. When the fixture supplies responses (and,
            // for `{{step.x}}`, the current step's live inputs) the block is run through the REAL
            // whitelist pass and the resolved strings are exported. Parsing a `{{token}}` proves
            // nothing about whether it ever becomes a value on screen — and calling
            // resolveTemplateString by hand (which this used to do, while claiming otherwise) proves
            // only that the resolver CAN expand a token, not that the block pass applies it to that
            // key. Round-4 bug injection deleted the `label` line from the whitelist and this file
            // stayed green, which is why resolveBlockTemplates was lifted out of the View.
            let sess = f.setup.session_data?.objectValue ?? [:]

            // SPEC-448 (#556) — the Option Set source keys. `field_options` must STILL parse when a
            // set is bound: that array doubles as the embedded page, and a parser treating a bound
            // set as "ignore the inline options" would leave older builds with an empty Select.
            h.state["parsed_option_set_id"] = SharedFixtureTests.orNull(block.field_config?["option_set_id"]?.value as? String)
            h.state["parsed_option_set_version"] = SharedFixtureTests.orNull(block.field_config?["option_set_version"]?.value as? Int)
            h.state["parsed_options_search"] = SharedFixtureTests.orNull(block.field_config?["options_search"]?.value as? Bool)
            h.state["parsed_embedded_option_count"] = (block.field_options ?? []).count

            // SPEC-447 (#555) — the image-tile layout keys.
            h.state["parsed_tile_image_layout"] = SharedFixtureTests.orNull(block.field_config?["tile_image_layout"]?.value as? String)
            h.state["parsed_tile_strip_ratio"] = SharedFixtureTests.orNull(block.field_config?["tile_strip_ratio"]?.value as? Double)
            h.state["parsed_tile_surface_color"] = SharedFixtureTests.orNull(block.field_config?["tile_surface_color"]?.value as? String)

            // SPEC-446 — resolution, not just parsing. When the fixture supplies responses (and,
            // for `{{step.x}}`, the current step's live inputs) the block is run through the REAL
            // whitelist pass and the resolved strings are exported. Parsing a `{{token}}` proves
            // nothing about whether it ever becomes a value on screen — and calling
            // resolveTemplateString by hand (which this used to do, while claiming otherwise) proves
            // only that the resolver CAN expand a token, not that the block pass applies it to that
            // key. Round-4 bug injection deleted the `label` line from the whitelist and this file
            // stayed green, which is why resolveBlockTemplates was lifted out of the View.

            let fixtureResponses = (sess["responses"]?.objectValue ?? [:]).mapValues { $0.foundation }
            let fixtureStepInputs = (sess["step_inputs"]?.objectValue ?? [:]).mapValues { $0.foundation }
            // SPEC-452 — the host's `{{hook_data.…}}` payload. This runner hardcoded `hookData: nil`,
            // so no fixture could exercise the `hook_data` root at all, on either platform.
            let fixtureHookData = (sess["hook_data"]?.objectValue ?? [:]).mapValues { $0.foundation }
            // SPEC-448 — seed the selected-option store so `{{selected.…}}` has something to
            // resolve. It is a process-lifetime singleton, so it is reset first: a value left over
            // from an earlier fixture would make this one pass for the wrong reason.
            SelectedOptionStore.shared.resetForTesting()
            if let selected = sess["selected"]?.objectValue {
                for (fieldId, payload) in selected {
                    SelectedOptionStore.shared.seedForTesting(fieldId: fieldId, value: payload.foundation)
                }
            }

            if !fixtureResponses.isEmpty || !fixtureStepInputs.isEmpty || sess["selected"] != nil
                || !fixtureHookData.isEmpty {
                let r = resolveBlockTemplates(
                    block, hookData: fixtureHookData.isEmpty ? nil : fixtureHookData,
                    responses: fixtureResponses, stepInputs: fixtureStepInputs)
                h.state["resolved_text"] = r.text ?? ""
                h.state["resolved_option_label"] = (r.field_options ?? []).first?.label ?? ""
                let rawStats = (r.field_config?["summary_stats"]?.value as? [Any]) ?? []
                let firstStat = rawStats.first as? [String: Any]
                h.state["resolved_stat0_value"] = (firstStat?["value"] as? String) ?? ""
                // #660 — a stat that cannot resolve and has a usable LABEL keeps its place and shows
                // a placeholder; one with nothing to say is still dropped. The count plus the
                // per-index values prove no raw token reaches a renderer either way.
                h.state["resolved_stat_count"] = rawStats.count
                h.state["resolved_stat0_label"] = (firstStat?["label"] as? String) ?? ""
                for (i, entry) in rawStats.enumerated() {
                    guard let st = entry as? [String: Any] else { continue }
                    h.state["resolved_stat\(i)_value"] = (st["value"] as? String) ?? ""
                    h.state["resolved_stat\(i)_label"] = (st["label"] as? String) ?? ""
                }
                // SPEC-452 — the resolved CHILD of a container. Children bypassed resolution
                // entirely, and a fixture that only reads the container's own keys cannot see that:
                // it is green whether or not the recursion exists.
                let resolvedKids = (r.children ?? []) + (r.stack_children ?? [])
                h.state["resolved_child0_text"] = resolvedKids.first?.text ?? ""
                h.state["resolved_child0_image_url"] = resolvedKids.first?.image_url ?? ""
                if resolvedKids.count > 1 {
                    h.state["resolved_child1_text"] = resolvedKids[1].text ?? ""
                }
                // #558 — a stat BOUND to an earlier answer that also hosts a control must open on the
                // RESOLVED value, not the authored default. Read off `r`, not the raw block: the first
                // version read the unresolved `{{responses.group_size}}`, found it non-numeric, fell
                // back to the default and asserted 9 — the very bug it forbids, passing as correct.
                if let bound = rawStats.compactMap({ $0 as? [String: Any] })
                    .first(where: { $0["field_id"] as? String == "group" }) {
                    if let s = bound["value"] as? String,
                       let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                        h.state["prefilled_stat_seeds_control"] = d.rounded() == d ? String(Int(d)) : String(d)
                    } else {
                        h.state["prefilled_stat_seeds_control"] = String(describing: bound["default"] ?? "")
                    }
                }
            }

            // SPEC-441 (#541) — the option's `category` drives section navigation. It is an
            // OPTION-level key, which is the class Android parses by hand, so a missing parser
            // line makes the chips point at nothing while every renderer still compiles.
            h.state["parsed_opt0_category"] = SharedFixtureTests.orNull(opts.first?.category)
            h.state["parsed_opt2_category"] = SharedFixtureTests.orNull(opts.count > 2 ? opts[2].category : nil)
            let rawCats = (block.field_config?["categories"]?.value as? [Any])?
                .compactMap { $0 as? [String: Any] } ?? []
            h.state["parsed_category_ids"] = rawCats.compactMap { $0["id"] as? String }
            h.state["parsed_category_labels"] = rawCats.compactMap { $0["label"] as? String }
            for child in children {
                if let fit = child.image_fit { h.state["parsed_image_fit"] = fit }
                if let variant = child.rich_text_variant { h.state["parsed_rich_text_variant"] = variant }
                if let rating = child.default_rating { h.state["parsed_rating_default"] = rating }
                if let mode = child.picker_mode { h.state["parsed_picker_mode"] = mode }
            }
            return
        }

        if path.hasPrefix("paywalls/") {
            let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixture.\(UUID().uuidString)")
            let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
            guard let paywall = rcm.decodePaywallPayload(config.mapValues { $0.foundation }) else {
                return XCTFail("[\(f.id)] RemoteConfigManager.decodePaywallPayload returned nil")
            }
            h.state["parse_succeeded"] = true
            h.state["parsed_paywall_id"] = SharedFixtureTests.orNull(paywall.id)
            h.state["parsed_plans_count"] = (paywall.plans ?? []).count
            h.state["parsed_post_purchase_success_action"] = SharedFixtureTests.orNull(paywall.post_purchase?.on_success?.action)
            h.state["parsed_post_purchase_success_confetti"] = SharedFixtureTests.orNull(paywall.post_purchase?.on_success?.confetti)
            h.state["parsed_post_purchase_failure_action"] = SharedFixtureTests.orNull(paywall.post_purchase?.on_failure?.action)
            h.state["parsed_post_purchase_failure_allow_dismiss"] = SharedFixtureTests.orNull(paywall.post_purchase?.on_failure?.allow_dismiss)
            // Reviews live INSIDE a section's data (`PaywallSectionData.reviews`), and the CTA's corner
            // radius comes off the real `cta` model's resolver — both are console-published shapes, both
            // are read from the SDK's decoded object, neither is a top-level field.
            h.state["parsed_reviews_count"] = paywall.sections.reduce(0) { $0 + ($1.data?.reviews?.count ?? 0) }
            h.state["parsed_cta_corner_radius"] = SharedFixtureTests.orNull(paywall.cta?.resolvedCornerRadius)
            // SPEC-438 (#544, #548) — product-level price presentation. Read off the DECODED
            // objects, not the raw JSON, so a field the model silently drops shows up here.
            let plansSection = paywall.sections.first { $0.type == "plans" }
            h.state["parsed_price_layout"] = SharedFixtureTests.orNull(plansSection?.data?.priceLayout)
            h.state["parsed_strikethrough_font_size"] = SharedFixtureTests.orNull(plansSection?.data?.strikethroughFontSize)
            h.state["parsed_strikethrough_gap"] = SharedFixtureTests.orNull(plansSection?.data?.strikethroughGap)
            let plansList = paywall.plans ?? []
            let p0 = plansList.count > 0 ? plansList[0] : nil
            let p1 = plansList.count > 1 ? plansList[1] : nil
            h.state["parsed_plan0_price_display"] = SharedFixtureTests.orNull(p0?.displayPrice)
            h.state["parsed_plan0_original_price_display"] = SharedFixtureTests.orNull(p0?.original_price_display)
            h.state["parsed_plan0_price_total_display"] = SharedFixtureTests.orNull(p0?.price_total_display)
            h.state["parsed_plan0_badge_enabled"] = SharedFixtureTests.orNull(p0?.description_badge?.enabled)
            h.state["parsed_plan0_badge_bg_color"] = SharedFixtureTests.orNull(p0?.description_badge?.bg_color)
            h.state["parsed_plan0_badge_text_color"] = SharedFixtureTests.orNull(p0?.description_badge?.text_color)
            h.state["parsed_plan0_badge_corner_radius"] = SharedFixtureTests.orNull(p0?.description_badge?.corner_radius)
            // Plan 1 authors NEITHER — absent must stay absent, which is what keeps an
            // unauthored paywall rendering exactly as it did before.
            h.state["parsed_plan1_price_total_display"] = SharedFixtureTests.orNull(p1?.price_total_display)
            h.state["parsed_plan1_badge_enabled"] = SharedFixtureTests.orNull(p1?.description_badge?.enabled)
            // SPEC-485 (#649) — the legal section. The text must arrive with its markdown INTACT
            // (parsing is the SDK's job), and the link colour must arrive as `accent_color`, the key
            // both natives read and the one the console's `link_color` is mapped onto at the wire
            // boundary — nothing used to map between them, so the authored colour never reached a
            // device at all.
            let legalSection = paywall.sections.first { $0.type == "legal" }
            h.state["parsed_legal_text"] = SharedFixtureTests.orNull(legalSection?.data?.text)
            h.state["parsed_legal_accent_color"] = SharedFixtureTests.orNull(legalSection?.data?.accentColor)
            h.state["parsed_legal_font_size"] = SharedFixtureTests.orNull(legalSection?.data?.fontSize)
            h.state["parsed_legal_alignment"] = SharedFixtureTests.orNull(legalSection?.data?.alignment)
            if let legalText = legalSection?.data?.text {
                // REAL: the shipped parser BOTH legal renderers call.
                let parsed = legalMarkdownLinks(legalText)
                let urls = parsed.runs.compactMap { $0.link }
                h.state["parsed_legal_rendered_text"] = String(parsed.characters)
                h.state["parsed_legal_link_count"] = urls.count
                h.state["parsed_legal_first_link_url"] = SharedFixtureTests.orNull(urls.first?.absoluteString)
            }
            return
        }

        if path.hasPrefix("survey_themes/") {
            guard let data = try? JSONSerialization.data(withJSONObject: config.mapValues { $0.foundation }),
                  let theme = try? JSONDecoder().decode(SurveyTheme.self, from: data) else {
                return XCTFail("[\(f.id)] setup.config did not decode as the SDK's SurveyTheme")
            }
            h.state["parse_succeeded"] = true
            h.state["parsed_background_color"] = SharedFixtureTests.orNull(theme.background_color)
            h.state["parsed_accent_color"] = SharedFixtureTests.orNull(theme.accent_color)
            h.state["parsed_intro_lottie_url"] = SharedFixtureTests.orNull(theme.intro_lottie_url)
            h.state["parsed_thankyou_lottie_url"] = SharedFixtureTests.orNull(theme.thankyou_lottie_url)
            h.state["parsed_thankyou_particle_effect"] = SharedFixtureTests.orNull(theme.thankyou_particle_effect.map { _ in "present" })
            h.state["parsed_blur_backdrop"] = SharedFixtureTests.orNull(theme.blur_backdrop.map { _ in "present" })
            h.state["parsed_haptic"] = SharedFixtureTests.orNull(theme.haptic.map { _ in "present" })
            h.state["parsed_gradient"] = SharedFixtureTests.orNull(theme.gradient.map { _ in "present" })
            h.state["parsed_button_gradient"] = SharedFixtureTests.orNull(theme.button_gradient.map { _ in "present" })
            h.state["parsed_text_align"] = SharedFixtureTests.orNull(theme.text_align)
            return
        }

        XCTFail("[\(f.id)] no iOS driver for config_path '\(path)' — add one or drop 'ios'.")
    }

    // MARK: - Driver: identify
    //
    // REAL: IdentityManager.identify(userId:traits:) + currentIdentity — the identity transition.
    // The `identify` EVENT is emitted by the static AppDNA.identify (AppDNA.swift:385), which needs a
    // configured SDK; the harness emits through the real EventTracker with the SDK's OWN property
    // names so a drift in those names is visible.

    private func runIdentify(_ f: Fixture, _ h: Harness) {
        guard let userId = f.action.raw["userId"]?.stringValue else {
            return XCTFail("[\(f.id)] identify needs action.userId")
        }
        let traits = (f.action.raw["traits"]?.objectValue ?? [:]).mapValues { $0.foundation }

        let previousAnonId = h.identityManager.currentIdentity.anonId   // REAL — minted by the SDK
        let previousUserId = h.identityManager.currentIdentity.userId

        h.identityManager.identify(userId: userId, traits: traits)      // REAL

        var props: [String: Any] = [
            "user_id": userId,
            "anon_id": previousAnonId,
        ]
        if let previousUserId, previousUserId != userId { props["previous_user_id"] = previousUserId }
        if !traits.isEmpty { props["traits"] = traits }
        h.tracker.track(event: "identify", properties: props)

        let identity = h.identityManager.currentIdentity
        h.state["user_id"] = SharedFixtureTests.orNull(identity.userId)
        h.state["user_traits"] = identity.traits ?? [:]
    }

    // MARK: - Driver: track_event
    //
    // REAL, END TO END: EventTracker.track + EventTracker.setScreenProvider — the envelope the SDK
    // ships, including `context.screen`.

    private func runTrackEvent(_ f: Fixture, _ h: Harness) {
        let action = f.action.raw
        guard let name = action["event_name"]?.stringValue ?? action["event"]?.stringValue else {
            return XCTFail("[\(f.id)] track_event needs action.event_name")
        }
        let props = (action["properties"]?.objectValue ?? [:]).mapValues { $0.foundation }

        // A screen_view announces the screen; the SDK's screen provider is what puts it on every
        // subsequent envelope's `context.screen`.
        if let screenName = props["screen_name"] as? String {
            h.tracker.setScreenProvider { screenName }
            h.state["current_screen"] = screenName
        }

        h.tracker.track(event: name, properties: props)
    }

    // MARK: - Driver: present_surface_under_experiment
    //
    // REAL, END TO END: ExperimentManager.resolveSurfacePresentation(surfaceType:entityId:) against a
    // real RemoteConfigManager loaded through `_injectExperimentsForTesting` /
    // `_injectVariantDocForTesting`. The `experiment_exposure` event is emitted by the SDK itself.
    // Bucketing is forced by weighting the assigned variant 1.0 and the rest 0.0 (the same technique
    // ExperimentVariantDocResolutionTests uses) — the bucketer has its own tests.

    private func runPresentSurfaceUnderExperiment(_ f: Fixture, _ h: Harness) {
        guard let config = f.setup.config?.objectValue,
              let experimentJSON = config["experiment"],
              let experimentData = try? JSONSerialization.data(withJSONObject: experimentJSON.foundation),
              let experiment = try? JSONDecoder().decode(ExperimentConfig.self, from: experimentData) else {
            return XCTFail("[\(f.id)] setup.config.experiment did not decode as the SDK's ExperimentConfig")
        }

        // decode_only — assert the served doc's field map through the SDK's own Codable.
        if f.action.raw["mode"]?.stringValue == "decode_only" {
            let variants = experiment.variants ?? []
            let control = variants.first(where: { $0.is_control == true })
            let treatment = variants.first(where: { $0.is_control == false })
            h.state["decoded_type"] = SharedFixtureTests.orNull(experiment.type)
            h.state["decoded_status"] = SharedFixtureTests.orNull(experiment.status)
            h.state["decoded_salt"] = SharedFixtureTests.orNull(experiment.salt)
            h.state["decoded_variant_count"] = variants.count
            h.state["control_config_ref"] = SharedFixtureTests.orNull(control?.config_ref)
            h.state["control_is_control"] = SharedFixtureTests.orNull(control?.is_control)
            h.state["treatment_config_ref"] = SharedFixtureTests.orNull(treatment?.config_ref)
            h.state["treatment_is_control"] = SharedFixtureTests.orNull(treatment?.is_control)
            h.state["treatment_has_payload"] = (treatment?.payload != nil)
            return
        }

        guard let surfaceType = f.action.raw["surface_type"]?.stringValue,
              let entityId = f.action.raw["entity_id"]?.stringValue else {
            return XCTFail("[\(f.id)] present_surface_under_experiment needs action.{surface_type,entity_id}")
        }
        let activeEntityId = config["active_entity_id"]?.stringValue ?? entityId

        // Force the bucket the fixture declares.
        let experimentId = experiment.id ?? ""
        let assigned = f.setup.experiment_assignments?.objectValue?[experimentId]?.stringValue
        let forcedVariants = (experiment.variants ?? []).map { v in
            ExperimentVariant(
                id: v.id,
                weight: (v.id == assigned) ? 1.0 : 0.0,
                payload: v.payload,
                config_ref: v.config_ref,
                is_control: v.is_control,
                variant_doc: v.variant_doc
            )
        }
        let forced = ExperimentConfig(
            id: experiment.id,
            name: experiment.name,
            status: experiment.status,
            type: experiment.type,
            salt: experiment.salt,
            platforms: experiment.platforms,
            variants: forcedVariants
        )

        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixture.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        rcm._injectExperimentsForTesting([experimentId: forced])
        for (path, doc) in (config["variant_docs"]?.objectValue ?? [:]) {
            if let docConfig = doc.objectValue?["config"]?.objectValue {
                rcm._injectVariantDocForTesting(path: path, config: docConfig.mapValues { $0.foundation })
            }
        }

        let manager = ExperimentManager(
            remoteConfigManager: rcm,
            identityManager: h.identityManager,
            eventTracker: h.tracker
        )
        let resolution = manager.resolveSurfacePresentation(surfaceType: surfaceType, entityId: entityId)

        // The SDK emits the exposure itself (ExperimentManager.trackExposure) — its presence is what
        // separates "control bucket" (exposed, renders active) from "no experiment" (not exposed).
        let exposed = h.events.contains { $0.event_name == "experiment_exposure" }

        switch resolution {
        case .renderTreatment(_, _, let payload):
            h.state["resolution"] = "treatment"
            h.state["presented_config_id"] = (payload["id"] as? String) ?? activeEntityId
        case .renderActive:
            h.state["resolution"] = exposed ? "control" : "active"
            h.state["presented_config_id"] = activeEntityId
        }
    }

    // MARK: - Driver: receive_push / tap_push
    //
    // REAL: PushPayloadParser.parse(userInfo:title:body:) — the parse
    // PushNotificationHandler.buildPayload runs (the `actions` array was shipped by the server,
    // registered as buttons, and then silently dropped on the way to the host).
    // REAL: PushTokenManager.trackDelivered / trackTapped — the push_delivered / push_tapped events.
    // REAL: AppDNA.deepLinks.handleURL — the deep-link dispatch to the host delegate.

    private func runReceivePush(_ f: Fixture, _ h: Harness) {
        guard let payloadJSON = f.action.raw["payload"]?.objectValue else {
            return XCTFail("[\(f.id)] receive_push needs action.payload")
        }
        let userInfo = payloadJSON.mapValues { $0.foundation }
        let payload = PushPayloadParser.parse(
            userInfo: userInfo,
            title: payloadJSON["title"]?.stringValue ?? "",
            body: payloadJSON["body"]?.stringValue ?? ""
        )

        let spy = PushDelegateSpy(harness: h)
        AppDNA.pushDelegate = spy
        defer { AppDNA.pushDelegate = nil }

        pushTokenManager(h).trackDelivered(pushId: payload.pushId)          // REAL push_delivered
        AppDNA.pushDelegate?.onPushReceived(notification: payload, inForeground: true)

        h.state["registered_action_button_count"] = payload.actions.count
    }

    private func runTapPush(_ f: Fixture, _ h: Harness) {
        guard let payloadJSON = f.action.raw["payload"]?.objectValue else {
            return XCTFail("[\(f.id)] tap_push needs action.payload")
        }
        let userInfo = payloadJSON.mapValues { $0.foundation }
        let payload = PushPayloadParser.parse(
            userInfo: userInfo,
            title: payloadJSON["title"]?.stringValue ?? "",
            body: payloadJSON["body"]?.stringValue ?? ""
        )

        let pushSpy = PushDelegateSpy(harness: h)
        let linkSpy = DeepLinkDelegateSpy(harness: h)
        AppDNA.pushDelegate = pushSpy
        AppDNA.deepLinks.setDelegate(linkSpy)
        defer {
            AppDNA.pushDelegate = nil
            AppDNA.deepLinks.setDelegate(nil)
        }

        pushTokenManager(h).trackTapped(pushId: payload.pushId)             // REAL push_tapped
        AppDNA.pushDelegate?.onPushTapped(notification: payload, actionId: nil)

        // The body action routes. `DeepLinksModule.handleURL` is the REAL dispatch: it fires
        // `onDeepLinkReceived` on the host delegate AND emits `deep_link_handled` {url} — which iOS
        // never did before SPEC-070-B, so every deep-link-attributed session was invisible in iOS
        // analytics while Android counted it. `trackEvent` is the module's analytics seam (AppDNA.track
        // needs a fully configured SDK); the event name and props are the SDK's own, via
        // DeepLinkAnalytics.
        guard let action = payload.action, action.type == "deep_link", let url = URL(string: action.value) else {
            return
        }
        let previousSink = AppDNA.deepLinks.trackEvent
        AppDNA.deepLinks.trackEvent = { name, props in h.tracker.track(event: name, properties: props) }
        defer { AppDNA.deepLinks.trackEvent = previousSink }

        AppDNA.deepLinks.handleURL(url)                                      // REAL

        // The route the host navigates to — derived from the URL the SDK parsed out of the push.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        h.state["current_route"] = [components?.host, path.isEmpty ? nil : path]
            .compactMap { $0 }
            .joined(separator: "/")
    }

    private func pushTokenManager(_ h: Harness) -> PushTokenManager {
        PushTokenManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.fixture.\(UUID().uuidString)"),
            eventTracker: h.tracker,
            apiClient: nil
        )
    }

    // MARK: - Assertions

    private func assertExpectations(fixture f: Fixture, harness h: Harness) {
        let prefix = "[\(f.id)]"

        // Events — every one produced by the real EventTracker, captured through `eventSink`.
        let expectedEvents = f.expect.events ?? []
        XCTAssertEqual(
            h.events.count, expectedEvents.count,
            "\(prefix) event count — expected \(expectedEvents.map(\.name)), got \(h.events.map(\.event_name))"
        )
        for (i, expected) in expectedEvents.enumerated() {
            guard i < h.events.count else { break }
            let actual = h.events[i]
            XCTAssertEqual(actual.event_name, expected.name, "\(prefix) event[\(i)].name")
            guard let expectedProps = expected.properties?.objectValue else { continue }
            for (key, expectedValue) in expectedProps {
                // `context` is the envelope's context block, not a property.
                if key == "context" {
                    assertContext(expectedValue, of: actual, prefix: "\(prefix) event[\(i)]")
                    continue
                }
                let actualValue = actual.properties?[key]?.value
                assertEqualJSON(
                    expected: expectedValue,
                    actual: actualValue,
                    label: "\(prefix) event[\(i)].properties.\(key)"
                )
            }
        }

        // Delegate calls — every one invoked on a real SDK delegate protocol.
        let expectedCalls = f.expect.delegate_calls ?? []
        XCTAssertEqual(
            h.delegateCalls.count, expectedCalls.count,
            "\(prefix) delegate-call count — expected \(expectedCalls.map(\.name)), got \(h.delegateCalls.map(\.name))"
        )
        for (i, expected) in expectedCalls.enumerated() {
            guard i < h.delegateCalls.count else { break }
            let actual = h.delegateCalls[i]
            XCTAssertEqual(actual.name, expected.name, "\(prefix) delegate[\(i)].name")
            guard let expectedArgs = expected.args?.objectValue else { continue }
            for (key, expectedValue) in expectedArgs {
                assertEqualJSON(
                    expected: expectedValue,
                    actual: actual.args[key],
                    label: "\(prefix) delegate[\(i)].args.\(key)"
                )
            }
        }

        // State — a key no real SDK call produced is a FAILURE, not an omission.
        for (key, expectedValue) in (f.expect.state_after?.objectValue ?? [:]) {
            guard let actualValue = h.state[key] else {
                XCTFail("""
                \(prefix) state_after.\(key) — no value produced by any real SDK call.
                Either the driver never exercised the SDK path that owns this state, or this SDK has no
                such concept (in which case say so and drop the key / the platform claim). What this
                runner will NOT do is compute the value itself.
                """)
                continue
            }
            assertEqualJSON(expected: expectedValue, actual: actualValue, label: "\(prefix) state_after.\(key)")
        }

        // Errors
        let expectedErrors = f.expect.errors ?? []
        XCTAssertEqual(h.errors.count, expectedErrors.count, "\(prefix) error count")
        for (i, expected) in expectedErrors.enumerated() where i < h.errors.count {
            XCTAssertEqual(h.errors[i].type, expected.type, "\(prefix) error[\(i)].type")
        }
    }

    private func assertContext(_ expected: AnyJSON, of event: SDKEvent, prefix: String) {
        guard let expectedContext = expected.objectValue else { return }
        let actual: [String: Any] = [
            "screen": SharedFixtureTests.orNull(event.context.screen),
            "session_id": event.context.session_id,
        ]
        for (key, value) in expectedContext {
            assertEqualJSON(expected: value, actual: actual[key], label: "\(prefix).context.\(key)")
        }
    }

    private func assertEqualJSON(expected: AnyJSON, actual: Any?, label: String) {
        let e = Self.canonicalJSON(expected)
        let a = Self.canonical(actual)
        if e != a {
            XCTFail("\(label): expected \(e), got \(a)")
        }
    }

    // MARK: - Canonicalization (shape-insensitive comparison)

    static func canonicalJSON(_ value: AnyJSON) -> String {
        switch value {
        case .null:            return "null"
        case .bool(let b):     return b ? "true" : "false"
        case .int(let i):      return String(i)
        case .double(let d):   return canonicalNumber(d)
        case .string(let s):   return s
        case .array(let a):    return "[" + a.map { canonicalJSON($0) }.joined(separator: ",") + "]"
        case .object(let o):
            let inner = o.keys.sorted().map { "\($0)=\(canonicalJSON(o[$0] ?? .null))" }.joined(separator: ",")
            return "{" + inner + "}"
        }
    }

    static func canonical(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let codable = value as? AnyCodable { return canonical(codable.value) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return canonicalNumber(number.doubleValue)
        }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return s }
        if let array = value as? [Any] { return "[" + array.map { canonical($0) }.joined(separator: ",") + "]" }
        if let dict = value as? [String: Any] {
            let inner = dict.keys.sorted().map { "\($0)=\(canonical(dict[$0]))" }.joined(separator: ",")
            return "{" + inner + "}"
        }
        return String(describing: value)
    }

    private static func canonicalNumber(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// `Optional<T>` → `Any`, using `NSNull` for nil. A recorded null is a value the SDK produced; a
    /// state key the driver never set at all is a hard failure in the assertion phase.
    static func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    /// `SectionAction` → the (type, value) pair the fixtures speak.
    static func describe(_ action: SectionAction) -> (String, String?) {
        switch action {
        case .deepLink(let url):    return ("deep_link", url)
        case .openURL(let url):     return ("open_url", url)
        case .openWebview(let url): return ("open_webview", url)
        case .navigate(let id):     return ("navigate", id)
        case .showScreen(let id):   return ("show_screen", id)
        case .showPaywall(let id):  return ("show_paywall", id)
        case .showSurvey(let id):   return ("show_survey", id)
        case .share(let text):      return ("share", text)
        case .haptic(let type):     return ("haptic", type)
        case .custom(let type, let value): return (type, value)
        case .next:                 return ("next", nil)
        case .back:                 return ("back", nil)
        case .dismiss:              return ("dismiss", nil)
        case .openAppSettings:      return ("open_app_settings", nil)
        case .submitForm:           return ("submit_form", nil)
        case .track(let event, _):  return ("track", event)
        // Flow-level verbs (SectionAction parity with Android's sealed class). No fixture dispatches
        // one today; these arms exist because the switch must stay exhaustive. Spellings are the
        // snake_case the fixtures speak, matching the action strings Android's FlowManager routes.
        case .restart:              return ("restart", nil)
        case .complete:             return ("complete", nil)
        case .setResponse(let key, _): return ("set_response", key)
        case .presentPaywall(let id):  return ("present_paywall", id)
        case .dismissPaywall:       return ("dismiss_paywall", nil)
        case .showMessage(let id):  return ("show_message", id)
        case .setUserProperty(let key, _): return ("set_user_property", key)
        case .purchase(let productId):     return ("purchase", productId)
        case .restore:              return ("restore", nil)
        }
    }

    /// `[PushAction]` → the wire shape the fixtures pin. An empty `value` is the parser's placeholder
    /// for a button that carries no target (e.g. `dismiss`), so it is omitted rather than serialized
    /// as an empty string.
    static func marshal(_ actions: [PushAction]) -> [[String: Any]] {
        actions.map { action in
            var out: [String: Any] = ["action_type": action.type]
            if !action.value.isEmpty { out["action_value"] = action.value }
            if let id = action.id { out["id"] = id }
            if let label = action.label { out["label"] = label }
            return out
        }
    }
}
