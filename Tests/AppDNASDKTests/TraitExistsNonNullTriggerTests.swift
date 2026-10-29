import XCTest
@testable import AppDNASDK

/// A screen's user-trait trigger reads "exists" as a non-null value, as the audience rules do (the shared
/// fixture `exists_requires_non_null_value`). A trait identify stored as null (`NSNull`) does not exist;
/// the same trait with a value does.
final class TraitExistsNonNullTriggerTests: XCTestCase {

    private func entry() throws -> ScreenIndexEntry {
        let json = #"{"id":"s1","name":"Welcome back","trigger_rules":{"user_traits":[{"trait":"name","operator":"exists"}]}}"#
        return try JSONDecoder().decode(ScreenIndexEntry.self, from: Data(json.utf8))
    }

    private func shown(_ traits: [String: Any]) throws -> String? {
        AutoTriggerEngine().evaluate(
            entries: [try entry()], event: "app_open", properties: nil, userTraits: traits,
            sessionCount: 1, daysSinceInstall: 0, currentScreenName: nil
        )
    }

    func testANullTraitDoesNotExist() throws {
        XCTAssertNil(try shown(["name": NSNull(), "plan": "pro"]))
    }

    func testATraitWithAValueExists() throws {
        XCTAssertEqual(try shown(["name": "Ana"]), "s1")
    }
}
