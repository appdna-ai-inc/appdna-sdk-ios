import XCTest
@testable import AppDNASDK

/// A screen's user-trait trigger reads "exists" as a non-null value, as the audience rules do (the shared
/// fixture `exists_requires_non_null_value`). A trait identify stored as null (`NSNull`) does not exist;
/// the same trait with a value does.
final class TraitExistsNonNullTriggerTests: XCTestCase {

    /// Through the live decision every tracked event runs (`ScreenManager.triggeredScreen`), on a fresh manager.
    private func shown(_ traits: [String: Any]) throws -> String? {
        let manager = ScreenManager()
        manager.updateIndex(try JSONDecoder().decode(ScreenIndex.self, from: JSONSerialization.data(withJSONObject: [
            "screens": [["id": "s1", "name": "Welcome back", "trigger_rules": ["user_traits": [["trait": "name", "operator": "exists"]]]]],
        ])))
        return manager.triggeredScreen(event: "app_open", properties: nil, currentScreenName: nil,
                                       inputs: ScreenTriggerInputs(sessionCount: 1, daysSinceInstall: 0), traits: traits)
    }

    func testANullTraitDoesNotExist() throws {
        XCTAssertNil(try shown(["name": NSNull(), "plan": "pro"]))
    }

    func testATraitWithAValueExists() throws {
        XCTAssertEqual(try shown(["name": "Ana"]), "s1")
    }
}
