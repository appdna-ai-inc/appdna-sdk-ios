import XCTest
@testable import AppDNASDK

/// Two package test processes on one simulator share `UserDefaults.standard` (both are the
/// same `xctest` tool), so a drop counted by one used to surface as a leading `_sdk_events_dropped`
/// in the other's next tracked event. Under XCTest the counter lives in a domain private to the
/// process; these pin that, by writing the counter's key into the SHARED domain exactly the way a
/// concurrent suite would.
final class DroppedEventsCounterIsolationTests: XCTestCase {
    private let key = "ai.appdna.sdk.dropped_events"

    override func setUp() {
        super.setUp()
        _ = DroppedEventsCounter.getAndReset()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        _ = DroppedEventsCounter.getAndReset()
        super.tearDown()
    }

    func testUnderXCTestTheCounterIsNotTheSharedStandardDomain() {
        XCTAssertFalse(DroppedEventsCounter.defaults === UserDefaults.standard,
                       "under XCTest the counter must not live in the domain every test process shares")
    }

    func testAnotherProcessesCountInTheSharedDomainDoesNotReachThisProcess() {
        UserDefaults.standard.set(7, forKey: key) // what a concurrent suite's eviction writes
        XCTAssertEqual(DroppedEventsCounter.peek(), 0, "a count written to the shared domain leaked into this process")
    }

    func testAnotherProcessesCountDoesNotPrefixTheNextTrackedEvent() {
        UserDefaults.standard.set(7, forKey: key)
        let tracker = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.fixture.\(UUID().uuidString)")))
        var names: [String] = []
        tracker.eventSink = { names.append($0.event_name) }
        tracker.track(event: "isolation_probe", properties: nil)
        XCTAssertEqual(names, ["isolation_probe"], "a foreign dropped count was emitted as _sdk_events_dropped first")
    }

    func testTheCounterStillCountsInItsOwnDomain() {
        DroppedEventsCounter.increment(3)
        XCTAssertEqual(DroppedEventsCounter.peek(), 3)
        DroppedEventsCounter.subtract(2)
        XCTAssertEqual(DroppedEventsCounter.getAndReset(), 1)
        XCTAssertEqual(DroppedEventsCounter.peek(), 0)
    }
}
