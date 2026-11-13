// SharedFixtureDrivers+HoldConfigMessages.swift
//
// iOS driver for `hold_config_messages`: a config-driven in-app message triggered while the app has no foreground
// scene is held, and drawn when the app next becomes active in the same process. Driven through the REAL
// `MessageManager` — its trigger evaluation, frequency tracker, presentation gate, hold and release — over a REAL
// `RemoteConfigManager` fed through its real per-item message parser. Only the screen (`MessageSurface`) and the
// activation signal are replaced: the screen has a foreground scene or it does not, and records what is drawn.
//
// `backgroundSceneDrawable` replays the previous scene choice (`connectedScenes.first`: any connected scene, the one a
// background launch connects included) through the same manager, for the red control in
// `ConfigMessageBackgroundLaunchTests`.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import UIKit
import XCTest
@testable import AppDNASDK

/// The fake edges of a `hold_config_messages` run, and what they observed.
final class ConfigMessageHoldRig {
    /// The screen the manager draws on: a foreground scene exists or it does not.
    final class Screen {
        /// Whether a foreground scene with a key window exists.
        var foreground = true
        /// The red control: the scene a background launch connects counts as somewhere to draw, as the
        /// `connectedScenes.first` lookup treated it.
        var backgroundSceneDrawable = false
        var presented: [String] = []
        var onActive: (() -> Void)?
        let host = UIViewController()
    }

    let screen = Screen()
    let remoteConfig: RemoteConfigManager
    let manager: MessageManager

    init(tracker: EventTracker, messages: [String: [String: Any]]) {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.fixture.hold.\(UUID().uuidString)")
        remoteConfig = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        for (id, data) in messages {
            // A previous run's `once` record would hide the message: the frequency store is process-wide.
            UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).shown")
            UserDefaults.standard.removeObject(forKey: "ai.appdna.sdk.msg_freq.\(id).count")
            remoteConfig._parseMessageDocForTesting(id: id, data: data)
        }
        let s = screen
        manager = MessageManager(
            remoteConfigManager: remoteConfig,
            eventTracker: tracker,
            surface: MessageSurface(
                host: { (s.foreground || s.backgroundSceneDrawable) ? s.host : nil },
                show: { id, _, _ in s.presented.append(id) },
                close: { _, done in done() },
                observeActivation: { block in
                    s.onActive = block
                    return { s.onActive = nil }
                }
            )
        )
    }

    func appActive() { screen.onActive?() }
    func close() { manager.dismissOnScreenForTesting() }
    func unpublish(_ id: String) {
        remoteConfig._pruneMessagesForTesting(Set(remoteConfig._getMessagesForTesting().keys).subtracting([id]))
    }
}

extension SharedFixtureTests {

    /// Lets the main queue run what `MessageManager.onEvent` dispatched to it (the present hop).
    @MainActor
    static func drainMainQueue() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    /// Runs a `hold_config_messages` script; returns the state it produced (`presented`, `held`).
    @MainActor
    static func runHoldConfigMessagesScript(
        _ action: [String: AnyJSON], tracker: EventTracker, backgroundSceneDrawable: Bool = false
    ) async -> [String: Any]? {
        guard let script = action["script"]?.arrayValue,
              let raw = action["messages"]?.foundation as? [String: Any] else { return nil }
        let messages = raw.compactMapValues { $0 as? [String: Any] }
        let rig = ConfigMessageHoldRig(tracker: tracker, messages: messages)
        rig.screen.backgroundSceneDrawable = backgroundSceneDrawable
        for step in script {
            let o = step.objectValue ?? [:]
            switch o["op"]?.stringValue {
            case "window": rig.screen.foreground = o["available"]?.boolValue ?? true
            case "track":
                rig.manager.onEvent(eventName: o["event"]?.stringValue ?? "", properties: nil)
                await drainMainQueue()
            case "app_active": rig.appActive()
            case "close": rig.close()
            case "unpublish": rig.unpublish(o["id"]?.stringValue ?? "")
            default: return nil
            }
        }
        return ["presented": rig.screen.presented, "held": rig.manager.heldMessageIds]
    }

    @MainActor
    func runHoldConfigMessages(_ f: Fixture, _ h: Harness) async {
        guard let state = await Self.runHoldConfigMessagesScript(f.action.raw, tracker: h.tracker) else {
            return XCTFail("[\(f.id)] hold_config_messages needs messages and a script of known ops")
        }
        for (k, v) in state { h.state[k] = v }
    }
}
