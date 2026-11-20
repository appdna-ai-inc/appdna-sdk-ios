import XCTest
@testable import AppDNASDK

/// A screen trigger's `max_impressions` and `cooldown_hours` survive a cold launch (a new `AutoTriggerEngine`
/// over the same store). `once_per_session` deliberately does not. Mirrors Android `ScreenFrequencyPersistenceTest`.
/// Red control: an engine with no store shows the capped screen again after the "relaunch".
final class ScreenFrequencyPersistenceTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "screen-freq-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func entry(_ id: String, _ frequency: String) throws -> ScreenIndexEntry {
        let json = #"{"id":"\#(id)","name":"\#(id)","trigger_rules":{"events":[{"event_name":"go"}],"frequency":\#(frequency)}}"#
        return try JSONDecoder().decode(ScreenIndexEntry.self, from: Data(json.utf8))
    }

    private func go(_ engine: AutoTriggerEngine, _ e: ScreenIndexEntry) -> String? {
        engine.evaluate(entries: [e], event: "go", properties: nil, userTraits: [:], sessionCount: 1,
                        daysSinceInstall: 0, currentScreenName: nil)
    }

    func testCapsAndCooldownHoldAcrossARelaunch() throws {
        let capped = try entry("capped", #"{"max_impressions":1}"#)
        let cooled = try entry("cooled", #"{"cooldown_hours":24}"#)
        let perSession = try entry("per_session", #"{"once_per_session":true}"#)
        let store = DefaultsScreenFrequencyStore(defaults: defaults)

        let first = AutoTriggerEngine(store: store)
        XCTAssertEqual(go(first, capped), "capped")
        XCTAssertEqual(go(first, cooled), "cooled")
        XCTAssertEqual(go(first, perSession), "per_session")
        XCTAssertNil(go(first, capped))

        let relaunched = AutoTriggerEngine(store: store)
        XCTAssertNil(go(relaunched, capped), "max_impressions started again on a relaunch")
        XCTAssertNil(go(relaunched, cooled), "cooldown_hours started again on a relaunch")
        XCTAssertEqual(go(relaunched, perSession), "per_session", "once_per_session must reset with the session")
    }

    func testWithoutAStoreTheCapResetsOnRelaunch() throws {
        let capped = try entry("capped_mem", #"{"max_impressions":1}"#)
        XCTAssertEqual(go(AutoTriggerEngine(), capped), "capped_mem")
        XCTAssertEqual(go(AutoTriggerEngine(), capped), "capped_mem")
    }
}
