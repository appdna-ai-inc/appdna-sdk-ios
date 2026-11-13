// PendingMessageNoWindowTests.swift
//
// A journey in-app message that arrives while the app has no window to draw in: a background launch (a
// content-available push, a background task) configures the SDK with no foreground scene. These tests drive the REAL
// `PendingMessageListener` with its REAL presenter — `presentOnTopViewController`, which looks for a key window in the
// connected scenes — so the no-window branch that `PendingMessageFollowTests` only reaches through a fake presenter
// runs here against UIKit. Only the Firestore subscription is replaced (one waiting delivery), and the retry delay
// is shortened.
//
// The package test host has NO connected scene (measured 2026-11-13: `applicationState=0 scenes=` — empty), which is
// the state of a background launch: the presenter's `connectedScenes … isKeyWindow` guard fails for real. A host
// that does have a key window gets "no window" manufactured instead (each key window's root view controller is taken
// away, and given back to stand for the scene coming to the foreground), and there the message is drawn too.
//
// © 2026 AppDNA AI, Inc.

import XCTest
import UIKit
@testable import AppDNASDK

@MainActor
final class PendingMessageNoWindowTests: XCTestCase {

    /// Takes the root view controller off every key window of every connected scene, so the presenter finds nothing
    /// to draw in; `restore()` gives them back.
    private final class NoPresentableWindow {
        private var stashed: [(UIWindow, UIViewController)] = []
        let scenes: Int
        init() {
            let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            scenes = windowScenes.count
            for scene in windowScenes {
                for w in scene.windows where w.isKeyWindow {
                    if let root = w.rootViewController { stashed.append((w, root)); w.rootViewController = nil }
                }
            }
        }
        var tookAWindow: Bool { !stashed.isEmpty }
        func restore() {
            for (w, root) in stashed { w.rootViewController = root }
            stashed = []
        }
    }

    private final class Delivered {
        var consumed = 0
        var scheduled: [Double] = []
    }

    /// The real listener and presenter; a subscription that answers with one waiting delivery; retries after
    /// `seconds × scale` instead of `seconds`.
    private func listener(_ d: Delivered, scale: Double) -> PendingMessageListener {
        PendingMessageListener(
            eventTracker: nil,
            subscribe: { _, _, _, onAdded in
                onAdded(.init(id: "d-bg", data: [
                    "content": ["title": "Synthetic title", "body": "Synthetic body.", "cta_text": "OK"],
                    "message_type": "modal", "trigger": "journey", "consumed": false,
                ], markConsumed: { d.consumed += 1 }))
                return {}
            },
            schedule: { seconds, block in
                d.scheduled.append(seconds)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds * scale, execute: block)
            }
        )
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func wait(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; spin(0.05) }
        return cond()
    }

    private func hostState() -> String {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return "applicationState=\(UIApplication.shared.applicationState.rawValue) scenes=" + scenes.map { s in
            "[\(s.activationState.rawValue) windows=\(s.windows.count) key=\(s.windows.filter(\.isKeyWindow).count)]"
        }.joined()
    }

    /// Dismisses what the presenter drew, so the next test starts from the host's own screen.
    private func dismissDrawn() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for w in scenes.flatMap(\.windows) {
            if let p = w.rootViewController?.presentedViewController {
                p.dismiss(animated: false)
            }
        }
        spin(0.3)
    }

    private func presented() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).compactMap { $0.rootViewController?.presentedViewController }.first
    }

    /// The window arrives only after every retry has run — a background launch the user opens minutes later, in the
    /// SAME process. The delivery must be drawn when the app next becomes active, not left until a cold launch.
    func testADeliveryWhoseRetriesRanOutIsDrawnWhenTheAppNextBecomesActive() throws {
        let gone = NoPresentableWindow()
        defer { gone.restore(); dismissDrawn() }
        XCTAssertTrue(gone.scenes == 0 || gone.tookAWindow, "a host with a scene has a key window to take away; \(hostState())")

        let d = Delivered()
        let l = listener(d, scale: 0.05)
        defer { withExtendedLifetime(l) {} }
        l.follow(orgId: "o", appId: "a", anonId: "anon-bg", userId: nil)

        // Every attempt fails: 1 present + (maxPresentAttempts − 1) retries.
        let retries = PendingMessageListener.maxPresentAttempts - 1
        XCTAssertTrue(wait(5) { d.scheduled.count >= retries }, "the retries are scheduled; \(d.scheduled)")
        spin(Double(retries) * 0.05 + 0.6)
        XCTAssertEqual(d.scheduled.count, retries, "no retry after the last one; \(d.scheduled)")
        XCTAssertEqual(d.consumed, 0, "never drawn while there was no window")
        XCTAssertNil(presented(), "nothing on screen")

        // The user opens the app: the scene (if the host has one) gets its window back and becomes active.
        gone.restore()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        if let scene = UIApplication.shared.connectedScenes.first {
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        }
        if gone.scenes == 0 {
            // No scene can exist in this host, so the activation cannot draw it — but it must TRY: a fresh round of
            // attempts through the real presenter starts (its first retry is scheduled at 1 s), and the delivery
            // stays unconsumed for the next activation or the next cold launch.
            XCTAssertTrue(wait(2) { d.scheduled.count > retries },
                          "becoming active re-presents a delivery whose retries ran out; scheduled \(d.scheduled)")
            XCTAssertEqual(d.scheduled.last, 1, "a fresh round: attempt 1 again, not attempt \(retries + 1); \(d.scheduled)")
            XCTAssertEqual(d.consumed, 0, "still no window, so still not drawn or consumed")
            print("[1782] scene-less host: scheduled \(d.scheduled) consumed \(d.consumed) — \(hostState())")
        } else {
            XCTAssertTrue(wait(3) { d.consumed == 1 },
                          "drawn when the app becomes active, in the same process; consumed \(d.consumed), scheduled \(d.scheduled)")
            spin(0.5)
            XCTAssertEqual(d.consumed, 1, "drawn and consumed once, though two activation notifications were posted")
            print("[1782] host with a scene: drawn on activation, scheduled \(d.scheduled) — \(hostState())")
        }
    }

    /// A background launch connects a scene in the BACKGROUND, with a key window nobody can see. Drawing there marked
    /// the delivery consumed and counted it shown before the user opened the app, so it is not somewhere to draw:
    /// only a foreground scene is, an active one first.
    func testOnlyAForegroundSceneIsSomewhereToDraw() {
        XCTAssertNil(PendingMessageListener.drawableSceneIndex([]), "no scene: nowhere to draw")
        XCTAssertNil(PendingMessageListener.drawableSceneIndex([.background]),
                     "a background launch's scene is not somewhere to draw")
        XCTAssertNil(PendingMessageListener.drawableSceneIndex([.unattached, .background]))
        XCTAssertEqual(PendingMessageListener.drawableSceneIndex([.foregroundInactive]), 0,
                       "a scene coming to the foreground counts")
        XCTAssertEqual(PendingMessageListener.drawableSceneIndex([.background, .foregroundActive]), 1,
                       "the foreground scene, not the first one")
        XCTAssertEqual(PendingMessageListener.drawableSceneIndex([.foregroundInactive, .foregroundActive]), 1,
                       "an active scene before an inactive one")
    }
}
