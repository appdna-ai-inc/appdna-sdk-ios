import XCTest
@testable import AppDNASDK

/// A screen's user-trait trigger evaluates its operator the way an audience rule does: an operator the SDK
/// does not implement does NOT fire (it used to fire for every user), `not_exists` is the negation of
/// `exists`, and the comparison operators the console offers are evaluated rather than passed.
final class TraitTriggerOperatorsTests: XCTestCase {

    private func shown(_ op: String, _ value: String, _ traits: [String: Any]) throws -> String? {
        let json = #"{"id":"s1","name":"Offer","trigger_rules":{"user_traits":[{"trait":"plan","operator":"\#(op)","value":\#(value)}]}}"#
        // Through the live decision every tracked event runs (`ScreenManager.triggeredScreen`), on a fresh manager.
        let manager = ScreenManager()
        manager.updateIndex(try JSONDecoder().decode(ScreenIndex.self, from: Data(#"{"screens":[\#(json)]}"#.utf8)))
        return manager.triggeredScreen(event: "app_open", properties: nil, currentScreenName: nil,
                                       inputs: ScreenTriggerInputs(sessionCount: 1, daysSinceInstall: 0), traits: traits)
    }

    func testAnUnknownOperatorDoesNotFire() throws {
        XCTAssertNil(try shown("is_one_of", #""pro""#, ["plan": "pro"]))
    }

    func testNotExistsDoesNotFireForAValue() throws {
        XCTAssertNil(try shown("not_exists", "null", ["plan": "pro"]))
    }

    func testNotExistsFiresForAnAbsentTrait() throws {
        XCTAssertEqual(try shown("not_exists", "null", ["other": 1]), "s1")
    }

    func testAComparisonIsEvaluated() throws {
        XCTAssertEqual(try shown("gt", "2", ["plan": 3]), "s1")
        XCTAssertNil(try shown("gt", "5", ["plan": 3]))
    }
}
