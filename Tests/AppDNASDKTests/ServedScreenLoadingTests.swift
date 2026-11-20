import XCTest
@testable import AppDNASDK

/// A published screen never reached a device. The console writes each screen to
/// `config/screen_index/screens/{id}`, and the reader for it (`RemoteConfigManager.fetchScreenConfig`) had no caller:
/// `showScreen` answered `screenNotFound` on every cache miss, and slots resolved only from a cache nothing filled.
///
/// The document reader `RemoteConfigManager` installs is replaced by one serving console-shaped documents.
/// Red control: with the cache-miss fetch removed from `showScreen`, `testShowScreenFetchesOnACacheMiss` fails;
/// with `prefetch` removed from `updateIndex`, `testIndexLoadPrefetchesSoASlotResolves` fails.
final class ServedScreenLoadingTests: XCTestCase {

    private var requests: [String] = []
    private var docs: [String: [String: Any]] = [:]

    private func section(_ id: String) -> [String: Any] { ["id": id, "type": "text", "data": ["text": "Hello"]] }

    /// The shape `ScreenConfigSyncService.buildScreenConfig` writes.
    private func screenDoc(_ id: String, _ name: String, sections: Int = 1) -> [String: Any] {
        ["id": id, "version": 2, "name": name, "default_locale": "en", "updated_at": "2026-11-20T10:00:00.000Z",
         "config": ["presentation": "modal", "layout": ["type": "scroll"], "sections": (1...sections).map { section("s\($0)") }]]
    }

    override func setUp() {
        super.setUp()
        ScreenManager.shared.reset()
        requests = []
        docs = [:]
        ScreenManager.shared.documentLoader = { [unowned self] kind, id, done in
            self.requests.append("\(kind)/\(id)")
            done(self.docs["\(kind)/\(id)"])
        }
    }

    override func tearDown() {
        ScreenManager.shared.documentLoader = nil
        ScreenManager.shared.reset()
        super.tearDown()
    }

    func testShowScreenFetchesOnACacheMiss() {
        docs["screens/scr_welcome"] = screenDoc("scr_welcome", "Welcome screen", sections: 2)
        var notFound = false
        ScreenManager.shared.showScreen("scr_welcome") { r in if r.error == .screenNotFound { notFound = true } }
        XCTAssertEqual(requests, ["screens/scr_welcome"])
        XCTAssertFalse(notFound, "the host was told a published screen was not found")
        let cached = ScreenManager.shared.getCachedScreen("scr_welcome")
        XCTAssertEqual(cached?.name, "Welcome screen")
        XCTAssertEqual(cached?.presentation, "modal")
        XCTAssertEqual(cached?.sections?.count, 2)
    }

    func testAScreenWithNoPublishedDocumentIsStillNotFound() {
        var result: ScreenResult?
        ScreenManager.shared.showScreen("scr_gone") { result = $0 }
        XCTAssertEqual(requests, ["screens/scr_gone"])
        XCTAssertEqual(result?.error, .screenNotFound)
    }

    func testIndexLoadPrefetchesSoASlotResolves() throws {
        docs["screens/scr_listed"] = screenDoc("scr_listed", "Listed")
        docs["screens/scr_slot"] = screenDoc("scr_slot", "Slot")
        docs["screens/scr_intercept"] = screenDoc("scr_intercept", "Intercept")
        docs["flows/flow_a"] = ["id": "flow_a", "name": "Flow", "version": 1,
                                "config": ["start_screen_id": "scr_listed", "settings": [String: Any](),
                                           "screens": [["screen_id": "scr_listed", "navigation_rules": [Any]()]]]]
        let indexJSON: [String: Any] = [
            "screens": [["id": "scr_listed", "name": "Listed"]],
            "flows": [["id": "flow_a", "name": "Flow"]],
            "slots": [["slot_name": "home_banner", "screen_id": "scr_slot"]],
            "interceptions": [["id": "i1", "trigger_screen": "Checkout", "timing": "before", "screen_id": "scr_intercept"]],
        ]
        let index = try JSONDecoder().decode(ScreenIndex.self, from: JSONSerialization.data(withJSONObject: indexJSON))
        XCTAssertNil(ScreenManager.shared.screenForSlot("home_banner"))

        ScreenManager.shared.updateIndex(index)

        for r in ["screens/scr_listed", "screens/scr_slot", "screens/scr_intercept", "flows/flow_a"] {
            XCTAssertTrue(requests.contains(r), "the index load did not fetch \(r)")
        }
        let slot = ScreenManager.shared.screenForSlot("home_banner")
        XCTAssertEqual(slot?.screenId, "scr_slot")
        XCTAssertEqual(slot?.config.name, "Slot")
        XCTAssertNotNil(ScreenManager.shared.getCachedScreen("scr_intercept"))
        XCTAssertNotNil(ScreenManager.shared.getCachedFlow("flow_a"))
    }

    func testShowFlowFetchesTheFlowAndItsScreens() {
        docs["flows/flow_a"] = ["id": "flow_a", "name": "Two-screen flow", "version": 1,
                                "config": ["start_screen_id": "scr_f1", "settings": [String: Any](),
                                           "screens": [["screen_id": "scr_f1", "navigation_rules": [Any]()],
                                                       ["screen_id": "scr_f2", "navigation_rules": [Any]()]]]]
        docs["screens/scr_f1"] = screenDoc("scr_f1", "First")
        docs["screens/scr_f2"] = screenDoc("scr_f2", "Second")
        var notFound = false
        ScreenManager.shared.showFlow("flow_a") { r in if r.error == .screenNotFound { notFound = true } }
        XCTAssertEqual(requests, ["flows/flow_a", "screens/scr_f1", "screens/scr_f2"])
        XCTAssertFalse(notFound)
        XCTAssertEqual(ScreenManager.shared.getCachedFlow("flow_a")?.name, "Two-screen flow")
    }
}
