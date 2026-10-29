import XCTest
@testable import AppDNASDK

/// A screen's user-trait trigger evaluates its operator the way an audience rule does: an operator the SDK
/// does not implement does NOT fire (it used to fire for every user), `not_exists` is the negation of
/// `exists`, and the comparison operators the console offers are evaluated rather than passed.
final class TraitTriggerOperatorsTests: XCTestCase {

    private func shown(_ op: String, _ value: String, _ traits: [String: Any]) throws -> String? {
        let json = #"{"id":"s1","name":"Offer","trigger_rules":{"user_traits":[{"trait":"plan","operator":"\#(op)","value":\#(value)}]}}"#
        let entry = try JSONDecoder().decode(ScreenIndexEntry.self, from: Data(json.utf8))
        return AutoTriggerEngine().evaluate(
            entries: [entry], event: "app_open", properties: nil, userTraits: traits,
            sessionCount: 1, daysSinceInstall: 0, currentScreenName: nil
        )
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
