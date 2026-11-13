// ConfigMessageBackgroundLaunchTests.swift
//
// A config-driven in-app message triggered during a BACKGROUND launch (a content-available push, a background fetch)
// was drawn into the scene that launch connects in the background — `connectedScenes.first`, whatever its state — so
// it was counted shown, and a `once` message used up, while nobody could see it. It is now held and drawn when the app
// next becomes active in the same process.
//
// These tests run the shared fixture's script through the REAL `MessageManager` twice: as the SDK now chooses where to
// draw, and with the scene a background launch connects counted as drawable — what `connectedScenes.first` did — as
// the RED CONTROL: the same harness must see that rule draw in the background and lose the held messages, or a green
// run of the fixture proves nothing. A third test keeps the PRODUCTION scene lookup (`MessageSurface.live.host`) in a
// host with no foreground scene, the package test host's real state.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import UIKit
import XCTest
@testable import AppDNASDK

@MainActor
final class ConfigMessageBackgroundLaunchTests: XCTestCase {

    private static let fixturePath = "action_dispatch/config_messages_background_launch.fixture.json"

    private func fixtureAction() throws -> [String: SharedFixtureTests.AnyJSON] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var file: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("sdk-shared-fixtures/" + Self.fixturePath)
            let sibling = dir.appendingPathComponent("packages/sdk-shared-fixtures/" + Self.fixturePath)
            if FileManager.default.fileExists(atPath: candidate.path) { file = candidate; break }
            if FileManager.default.fileExists(atPath: sibling.path) { file = sibling; break }
            dir.deleteLastPathComponent()
        }
        if file == nil, let env = ProcessInfo.processInfo.environment["APPDNA_SDK_FIXTURES_DIR"] {
            file = URL(fileURLWithPath: env).appendingPathComponent(Self.fixturePath)
        }
        let url = try XCTUnwrap(file, "\(Self.fixturePath) not found")
        let root = try JSONDecoder().decode(SharedFixtureTests.AnyJSON.self, from: Data(contentsOf: url))
        return try XCTUnwrap(root.objectValue?["action"]?.objectValue)
    }

    private func tracker() -> (EventTracker, () -> [String]) {
        let identity = IdentityManager(keychainStore: KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)"))
        let t = EventTracker(identityManager: identity)
        var names: [String] = []
        t.eventSink = { e in
            let id = (e.properties?["message_id"]?.value as? String).map { ":" + $0 } ?? ""
            names.append(e.event_name + id)
        }
        return (t, { names })
    }

    func testFixtureScriptHoldsAndDrawsEachMessageOnceWhenActive() async throws {
        let (t, events) = tracker()
        let action = try fixtureAction()
        let result = await SharedFixtureTests.runHoldConfigMessagesScript(action, tracker: t)
        let state = try XCTUnwrap(result)
        XCTAssertEqual(state["presented"] as? [String], ["fx_hold_a", "fx_hold_b", "fx_hold_b"])
        XCTAssertEqual(state["held"] as? [String], [])
        XCTAssertEqual(events(), [
            "in_app_message_shown:fx_hold_a", "in_app_message_dismissed:fx_hold_a",
            "in_app_message_shown:fx_hold_b", "in_app_message_dismissed:fx_hold_b",
            "in_app_message_shown:fx_hold_b", "in_app_message_dismissed:fx_hold_b",
        ])
    }

    /// RED CONTROL — the background scene counted as somewhere to draw, as `connectedScenes.first` counted it: the
    /// `once` message is drawn (and used up) at the background launch, before the app is opened; the message triggered
    /// meanwhile is never drawn, and the one triggered at a later background launch is drawn in the background too.
    func testRedControlBackgroundSceneDrawsWhileNobodyLooks() async throws {
        let (t, events) = tracker()
        let action = try fixtureAction()
        let result = await SharedFixtureTests.runHoldConfigMessagesScript(action, tracker: t, backgroundSceneDrawable: true)
        let state = try XCTUnwrap(result)
        XCTAssertEqual(state["presented"] as? [String], ["fx_hold_a", "fx_hold_c"])
        XCTAssertEqual(events().first, "in_app_message_shown:fx_hold_a")
    }

    /// The REAL present and dismiss: the live `show` / `close` (UIKit `present` / `dismiss`) over a real key window.
    /// Two messages are held with no foreground; once there is one, activation draws the first, and closing it through
    /// its own dismiss path (the closure the message's ✕ and "Got it" run) draws the second — once each.
    func testRealPresentAndDismissDrawEachHeldMessageOnce() async throws {
        let ids = ["fx_hold_real_a_\(UUID().uuidString.prefix(6))", "fx_hold_real_b_\(UUID().uuidString.prefix(6))"]
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        for (i, id) in ids.enumerated() {
            rcm._parseMessageDocForTesting(id: id, data: [
                "message_type": "modal",
                "content": ["title": "Synthetic \(i)", "body": "Synthetic body.", "cta_text": "OK"],
                "trigger_rules": ["event": "evt_\(i)", "frequency": "once"],
            ])
        }
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        // A window with no scene runs no transition animation, so an animated present / dismiss never completes here.
        // With animations off, the live `present(animated: true)` / `dismiss(animated: true)` complete at once.
        UIView.setAnimationsEnabled(false)
        defer { window.isHidden = true; UIView.setAnimationsEnabled(true) }

        // CONTROL: can this harness complete a UIKit present / dismiss at all? If a plain controller's dismiss never
        // calls back here, the manager's cannot either, and a failure below would say nothing about the SDK.
        var controlPresented = false, controlDismissed = false
        root.present(UIViewController(), animated: true) { controlPresented = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        root.dismiss(animated: true) { controlDismissed = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        try XCTSkipUnless(controlPresented && controlDismissed && root.presentedViewController == nil,
            "this host cannot complete a UIKit present/dismiss (presented=\(controlPresented) dismissed=\(controlDismissed)); "
            + "the device walk covers the real close")

        var foreground = false
        var onActive: (() -> Void)?
        var shown: [String] = []
        var surface = MessageSurface.live
        surface.host = {
            guard foreground else { return nil }
            var top: UIViewController = root
            while let p = top.presentedViewController { top = p }
            return top
        }
        let liveShow = surface.show
        surface.show = { id, host, content in shown.append(id); liveShow(id, host, content) }
        surface.observeActivation = { block in onActive = block; return { onActive = nil } }
        let (t, events) = tracker()
        let manager = MessageManager(remoteConfigManager: rcm, eventTracker: t, surface: surface)

        manager.onEvent(eventName: "evt_0", properties: nil)
        await SharedFixtureTests.drainMainQueue()
        manager.onEvent(eventName: "evt_1", properties: nil)
        await SharedFixtureTests.drainMainQueue()
        XCTAssertEqual(manager.heldMessageIds, ids)

        foreground = true
        onActive?()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(shown, [ids[0]])
        XCTAssertNotNil(root.presentedViewController, "the first held message is on screen (UIKit present)")

        manager.dismissOnScreenForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(shown, ids, "closing the first draws the second")
        XCTAssertNotNil(root.presentedViewController)

        manager.dismissOnScreenForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        onActive?()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(root.presentedViewController, "both closed through UIKit dismiss")
        XCTAssertEqual(shown, ids, "each drawn once")
        XCTAssertEqual(manager.heldMessageIds, [])
        XCTAssertEqual(events(), [
            "in_app_message_shown:\(ids[0])", "in_app_message_dismissed:\(ids[0])",
            "in_app_message_shown:\(ids[1])", "in_app_message_dismissed:\(ids[1])",
        ])
        for id in ids { UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).shown") }
    }

    /// The PRODUCTION scene lookup in a host with no foreground scene (the package test host has no connected scene,
    /// which is the state of a background launch): the message is held — not drawn, not counted shown, its `once`
    /// not used up — and becoming active with still no foreground scene draws nothing.
    func testLiveSceneLookupHoldsWithoutAForegroundScene() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        try XCTSkipIf(
            scenes.contains { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive },
            "this host has a foreground scene; the fixture covers the hold through the replaced screen"
        )
        let id = "fx_hold_live_\(UUID().uuidString.prefix(8))"
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        rcm._parseMessageDocForTesting(id: id, data: [
            "message_type": "modal",
            "content": ["title": "Synthetic", "body": "Synthetic body.", "cta_text": "OK"],
            "trigger_rules": ["event": "session_start", "frequency": "once"],
        ])
        var surface = MessageSurface.live
        var onActive: (() -> Void)?
        var shown: [String] = []
        surface.show = { messageId, _, _ in shown.append(messageId) }
        surface.observeActivation = { block in onActive = block; return { onActive = nil } }
        let (t, events) = tracker()
        let manager = MessageManager(remoteConfigManager: rcm, eventTracker: t, surface: surface)

        manager.onEvent(eventName: "session_start", properties: nil)
        await SharedFixtureTests.drainMainQueue()
        manager.onEvent(eventName: "session_start", properties: nil)
        await SharedFixtureTests.drainMainQueue()
        onActive?()

        XCTAssertEqual(manager.heldMessageIds, [id], "held once, however often it triggers")
        XCTAssertEqual(shown, [])
        XCTAssertEqual(events(), [], "nothing is counted shown while it is held")
        XCTAssertTrue(
            MessageFrequencyTracker().canShow(messageId: id, frequency: .once, maxDisplays: nil),
            "a held `once` message is not used up"
        )
        UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).shown")
    }
}
