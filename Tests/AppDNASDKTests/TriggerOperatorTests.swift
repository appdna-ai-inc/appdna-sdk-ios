// TriggerOperatorTests.swift
//
// THE OPERATOR VOCABULARY, AND WHAT AN UNKNOWN ONE MUST DO.
//
// The console's survey schema allowed `neq`, `in` and `not_in`, which no SDK implemented. This
// platform decoded an unrecognised operator to `.eq` — so a condition authored `neq` selected
// precisely the audience the author had EXCLUDED — while Android answered false. Both now evaluate
// the full set, and both answer false for anything outside it.
//
// Mirrors `TriggerOperatorTest.kt`.
import XCTest
@testable import AppDNASDK

final class TriggerOperatorTests: XCTestCase {

    private typealias Op = TriggerCondition.ConditionOperator

    /// Decode an operator the way a published document delivers it — a bare JSON string.
    private func decode(_ raw: String) throws -> Op {
        let json = Data("\"\(raw)\"".utf8)
        return try JSONDecoder().decode(Op.self, from: json)
    }

    func testEqAndNeqAreTextComparisonsAndExactOpposites() {
        XCTAssertTrue(Op.eq.matches("pro", "pro"))
        XCTAssertFalse(Op.eq.matches("pro", "free"))
        // 🔴 The pair that was inverted here: neq must be the complement of eq, never its twin.
        XCTAssertFalse(Op.neq.matches("pro", "pro"))
        XCTAssertTrue(Op.neq.matches("pro", "free"))
        // Numbers compare as text, so 30 and "30" are equal.
        XCTAssertTrue(Op.eq.matches(30, "30"))
    }

    func testTheNumericOperatorsNeedBothSidesNumeric() {
        XCTAssertTrue(Op.gte.matches(30, 30))
        XCTAssertTrue(Op.gt.matches(31, 30))
        XCTAssertFalse(Op.gt.matches(30, 30))
        XCTAssertTrue(Op.lte.matches("29", 30))
        XCTAssertTrue(Op.lt.matches(29.5, 30))
        // A non-numeric side never matches rather than comparing as text.
        XCTAssertFalse(Op.gte.matches("pro", 30))
        XCTAssertFalse(Op.gte.matches(30, "pro"))
    }

    func testContainsIsASubstringOfTheText() {
        XCTAssertTrue(Op.contains.matches("pro_annual", "annual"))
        XCTAssertFalse(Op.contains.matches("pro_annual", "monthly"))
    }

    func testInAndNotInReadAListAndASingleValueAsAOneElementList() {
        XCTAssertTrue(Op.in.matches("pro", ["free", "pro"]))
        XCTAssertFalse(Op.in.matches("team", ["free", "pro"]))
        XCTAssertFalse(Op.not_in.matches("pro", ["free", "pro"]))
        XCTAssertTrue(Op.not_in.matches("team", ["free", "pro"]))
        // A non-list value is the author's one-element list, not a condition that never matches.
        XCTAssertTrue(Op.in.matches("pro", "pro"))
        XCTAssertFalse(Op.not_in.matches("pro", "pro"))
        // Members compare as text, so a numeric list works.
        XCTAssertTrue(Op.in.matches(3, [1, 2, 3]))
    }

    func testAnUnknownOperatorDecodesToUnknownAndNeverMatches() throws {
        /*
         🔴 THE DEFECT ITSELF. `?? .eq` did not merely lose the operator, it substituted a different
         one — and `neq` is the case where that inverts the author's intent. Decoding to `.unknown`
         and answering false is the safe reading: a survey that never appears is noticed, one shown
         to the wrong audience is not.
         */
        for raw in ["equals", ">=", "eq ", "EQ", "regex", "neq_"] {
            let op = try decode(raw)
            XCTAssertEqual(op, .unknown, "`\(raw)` must not decode to a real operator")
            XCTAssertFalse(op.matches("pro", "pro"), "`\(raw)` must not match")
        }
        // control: a SUPPORTED spelling of the same comparison decodes and matches, so the loop
        // above is measuring the operator and not the operands.
        XCTAssertEqual(try decode("eq"), .eq)
        XCTAssertTrue(try decode("eq").matches("pro", "pro"))
        // And the one that used to invert: it decodes as itself now.
        XCTAssertEqual(try decode("neq"), .neq)
        XCTAssertFalse(try decode("neq").matches("pro", "pro"))
    }

    func testEveryOperatorTheConsoleCanAuthorIsEvaluated() throws {
        /*
         The parity contract the console schema and the docs are written against. A value in
         `survey.schema.ts` / `message.schema.ts` that decodes to `.unknown` here is a condition an
         author can publish and no device will ever satisfy (Rule 8).
         */
        for raw in ["eq", "neq", "gt", "gte", "lt", "lte", "contains", "in", "not_in"] {
            XCTAssertNotEqual(try decode(raw), .unknown, "the console can author `\(raw)`")
        }
    }

    func testAnUnknownFrequencyDecodesToOnce() throws {
        /*
         The other half of the trigger-frequency fix: the console's `recurring` was in neither SDK. Here it fell to
         `.once`; on Android it took the most permissive branch, so the same published survey was a
         one-off on this platform and unlimited on the other. Android answers `once` now too, and
         this pins the behaviour THIS side is already correct about so it cannot drift back.
         */
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(MessageFrequency.self, from: Data("\"recurring\"".utf8)), .once)
        XCTAssertEqual(try decoder.decode(MessageFrequency.self, from: Data("\"whatever\"".utf8)), .once)
        // control: the four real ones decode as themselves.
        XCTAssertEqual(try decoder.decode(MessageFrequency.self, from: Data("\"once_per_session\"".utf8)), .once_per_session)
        XCTAssertEqual(try decoder.decode(MessageFrequency.self, from: Data("\"every_time\"".utf8)), .every_time)
        XCTAssertEqual(try decoder.decode(MessageFrequency.self, from: Data("\"max_times\"".utf8)), .max_times)
    }
}
