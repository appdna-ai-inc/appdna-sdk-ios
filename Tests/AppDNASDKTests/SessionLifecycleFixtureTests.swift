import XCTest
@testable import AppDNASDK

/// Session-lifecycle behavioral fixtures: `packages/sdk-shared-fixtures/events/` files that carry a
/// `lifecycle` block. Mirrors the Android `SessionLifecycleFixtureTest`.
///
/// Each case is a fresh process: the process-wide foreground state is reset, the persisted last-active
/// time is seeded, and the REAL `SessionManager` is driven the way iOS drives it. The events it tracks
/// are read off the real `EventTracker` through its `eventSink` and counted.
///
/// Step mapping (iOS):
///  - launch_foreground   init with a non-background application state, then the main queue drains
///                        (the launch decision runs there)
///  - launch_background   init with a background application state, then the main queue drains
///  - foreground_callback willEnterForeground (the scene lifecycle also posts it for a launch)
///  - background          didEnterBackground
///  - reconfigure         the current manager is released and a new one launches in the foreground
///
/// The callbacks are invoked on the manager directly rather than posted through NotificationCenter:
/// any other SessionManager alive in this test process would answer a posted notification too.
final class SessionLifecycleFixtureTests: XCTestCase {

    private static let lastActiveKey = "ai.appdna.sdk.lastActiveAt"

    func testSessionLifecycleFixtures() throws {
        let fixtures = try loadLifecycleFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No iOS session-lifecycle fixtures found (packages/sdk-shared-fixtures/events)")
        var cases = 0
        for (id, lifecycle) in fixtures {
            let appOpenProps = lifecycle["app_open_properties"] as? [String: Any] ?? [:]
            for c in lifecycle["cases"] as? [[String: Any]] ?? [] {
                try runCase(id, c, appOpenProps)
                cases += 1
            }
        }
        print("[SessionLifecycle] asserted \(cases) cases in \(fixtures.count) fixtures")
    }

    private func drainMain() {
        let e = expectation(description: "main queue drained")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 5)
    }

    private func runCase(_ fixtureId: String, _ c: [String: Any], _ appOpenProps: [String: Any]) throws {
        let label = "[\(fixtureId) / \(c["name"] as? String ?? "?")]"
        SessionManager.resetProcessStateForTest()
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.lastActiveKey)
        d.removeObject(forKey: SessionManager.sessionCountKey)
        switch c["last_active"] as? String {
        case "none": break
        case "recent": d.set(Date().addingTimeInterval(-5 * 60), forKey: Self.lastActiveKey)
        case "stale": d.set(Date().addingTimeInterval(-31 * 60), forKey: Self.lastActiveKey)
        default: XCTFail("\(label) unknown last_active: \(String(describing: c["last_active"]))")
        }

        let keychain = KeychainStore(service: "ai.appdna.sdk.lifecycle.\(UUID().uuidString)")
        let tracker = EventTracker(identityManager: IdentityManager(keychainStore: keychain))
        var tracked: [SDKEvent] = []
        tracker.eventSink = { tracked.append($0) }

        var sm: SessionManager?
        func launch(background: Bool) {
            sm = SessionManager(eventTracker: tracker, isApplicationInBackground: { background })
            drainMain()
        }
        for step in c["steps"] as? [String] ?? [] {
            switch step {
            case "launch_foreground": launch(background: false)
            case "launch_background": launch(background: true)
            case "foreground_callback": sm?.appDidEnterForeground()
            case "background": sm?.appDidEnterBackground()
            case "reconfigure": sm = nil; launch(background: false)
            default: XCTFail("\(label) unknown lifecycle step: \(step)")
            }
        }
        sm = nil

        let names = tracked.map(\.event_name)
        for (name, count) in c["expect"] as? [String: Int] ?? [:] {
            XCTAssertEqual(names.filter { $0 == name }.count, count, "\(label) count of \(name) (tracked: \(names))")
        }
        let expectedProps = try JSONSerialization.data(withJSONObject: appOpenProps, options: [.sortedKeys])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        for ev in tracked where ev.event_name == "app_open" {
            let actual = try enc.encode(ev.properties ?? [:])
            XCTAssertEqual(String(decoding: actual, as: UTF8.self), String(decoding: expectedProps, as: UTF8.self),
                           "\(label) app_open properties")
        }
        d.removeObject(forKey: Self.lastActiveKey)
        d.removeObject(forKey: SessionManager.sessionCountKey)
        SessionManager.resetProcessStateForTest()
    }

    private func loadLifecycleFixtures() throws -> [(String, [String: Any])] {
        guard let root = SharedFixtureTests.fixturesRootURL()?.appendingPathComponent("events") else {
            XCTFail("Could not locate packages/sdk-shared-fixtures/events")
            return []
        }
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var out: [(String, [String: Any])] = []
        for url in items where url.lastPathComponent.hasSuffix(".fixture.json") {
            guard let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  j["category"] as? String == "events",
                  let lifecycle = j["lifecycle"] as? [String: Any],
                  (j["platforms"] as? [String] ?? []).contains("ios"),
                  let id = j["id"] as? String else { continue }
            out.append((id, lifecycle))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
