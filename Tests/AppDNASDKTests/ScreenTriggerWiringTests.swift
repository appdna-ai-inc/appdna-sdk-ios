import XCTest
@testable import AppDNASDK

/// The public `AppDNA.track` runs the screen triggers, as it runs the message and survey triggers. Nothing called
/// `ScreenManager.evaluateTriggers` before, so no screen ever auto-presented from an event.
///
/// What is observed: a trigger capped at ONE impression. When `track` runs the live decision, the engine records the
/// impression, and the same decision asked again afterwards picks nothing. A tracked event the screens module emits
/// itself (`screen_dismissed`) runs no trigger, so the cap is still unspent after it.
final class ScreenTriggerWiringTests: XCTestCase {

    private var tracker: EventTracker!
    private var previous: EventTracker?

    override func setUp() {
        super.setUp()
        tracker = EventTracker(identityManager: IdentityManager(keychainStore: KeychainStore(service: "t.\(UUID())")))
        tracker.eventSink = { _ in }
        previous = AppDNA.eventTrackerForTesting
        AppDNA.installEventTrackerForTest(tracker)
    }

    override func tearDown() {
        ScreenManager.shared.updateIndex(try! JSONDecoder().decode(ScreenIndex.self, from: Data(#"{"screens":[]}"#.utf8)))
        AppDNA.installEventTrackerForTest(previous)
        super.tearDown()
    }

    private func index(_ screenId: String, event: String) throws -> ScreenIndex {
        let json = #"{"screens":[{"id":"\#(screenId)","name":"Wired","trigger_rules":{"events":[{"event_name":"\#(event)"}],"frequency":{"max_impressions":1}}}]}"#
        return try JSONDecoder().decode(ScreenIndex.self, from: Data(json.utf8))
    }

    private func pickedAgain(_ event: String) -> String? {
        ScreenManager.shared.triggeredScreen(event: event, properties: nil, currentScreenName: nil,
                                             inputs: ScreenTriggerInputs(sessionCount: 1, daysSinceInstall: 0), traits: [:])
    }

    /// The dispatcher wired the way `AppDNA.configure` wires it (its `.screen` branch is
    /// `ScreenManager.shared.evaluateTriggers`), fed by the real tracker.
    private func wire() -> TriggerDispatcher {
        let d = TriggerDispatcher(executor: { $0() })
        tracker.triggerSink = { e, p in d.record(event: e, properties: p) }
        d.attach { surface, e, p in
            if surface == .screen { ScreenManager.shared.evaluateTriggers(event: e, properties: p) }
        }
        d.markConfigReady()
        return d
    }

    func testTrackRunsTheScreenTriggers() throws {
        XCTAssertTrue(TriggerDispatcher.surfaces(for: "walk_event").contains(.screen))
        let id = "wired_\(UUID().uuidString.prefix(8))"
        ScreenManager.shared.updateIndex(try index(id, event: "walk_event"))
        XCTAssertEqual(pickedAgain("walk_event"), id, "the harness cannot see an unspent trigger")
        ScreenManager.shared.reset()
        ScreenManager.shared.updateIndex(try index(id + "b", event: "walk_event"))
        let d = wire()
        tracker.track(event: "walk_event", properties: nil)
        _ = d
        XCTAssertNil(pickedAgain("walk_event"), "track did not run the trigger: its one impression is still unspent")
    }

    func testTheScreensModulesOwnEventsRunNoTrigger() throws {
        XCTAssertFalse(TriggerDispatcher.surfaces(for: "screen_dismissed").contains(.screen))
        let id = "own_\(UUID().uuidString.prefix(8))"
        ScreenManager.shared.updateIndex(try index(id, event: "screen_dismissed"))
        let d = wire()
        tracker.track(event: "screen_dismissed", properties: nil)
        _ = d
        XCTAssertEqual(pickedAgain("screen_dismissed"), id, "screen_dismissed ran the trigger and spent its impression")
    }
}
