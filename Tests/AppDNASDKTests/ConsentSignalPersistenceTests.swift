import XCTest
@testable import AppDNASDK

/// The consent sender's persisted state round-trips through the real stores, including a pending slot whose triple
/// carries no user. `user_id` is then `NSNull`, which is not a property-list value: written into UserDefaults as a
/// dictionary it raised `NSInvalidArgumentException` and terminated the app — any anonymous user who declined
/// analytics. Without the fix this test fails on that exception (in an app nothing catches it).
final class ConsentSignalPersistenceTests: XCTestCase {

    private let suite = "ai.appdna.sdk.tests.consent_persistence"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAPendingSlotWithNoUserIsPersistedAndReadBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let persistence = ConsentSignalPersistence(keychain: ConsentFixtureKeychain(), defaults: defaults)

        let anonymous = ConsentSyncTable.Triple(anonId: "anon-device-a", userId: nil, analytics: false)
        var state = ConsentSyncTable.State()
        state.ack = .unknown
        state.dropped = anonymous
        state.slot = ConsentSyncTable.Slot(generation: 3, triple: anonymous, attempts: 1, tsMs: 946_684_800_123)
        state.lastBodyTs = 946_684_800_123
        state.lastGeneration = 3

        persistence.save(state)
        let back = persistence.load()

        XCTAssertEqual(back.slot, state.slot)
        XCTAssertNil(back.slot?.triple.userId)
        XCTAssertEqual(back.ack, .unknown)
        XCTAssertEqual(back.dropped, anonymous)
        XCTAssertEqual(back.lastBodyTs, 946_684_800_123)
        XCTAssertEqual(back.lastGeneration, 3)

        // The wire body still sends the absent user as an explicit null.
        let body = ConsentSignalPersistence.body(try XCTUnwrap(back.slot))
        XCTAssertTrue(body["user_id"] is NSNull)

        // Clearing the slot removes it.
        state.slot = nil
        persistence.save(state)
        XCTAssertNil(persistence.load().slot)
        XCTAssertNil(defaults.object(forKey: ConsentSignalPersistence.slotKey))
    }
}
