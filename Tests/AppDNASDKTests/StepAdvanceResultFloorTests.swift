// StepAdvanceResultFloorTests.swift
//
// SPEC-497 §4.9 — the sign-in bridge floor: every member of `AuthActionPolicy.bridgeFloorActions`
// gets 120 s; anything else gets no floor.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class StepAdvanceResultFloorTests: XCTestCase {

    func testEveryBridgeFloorActionGets120Seconds() {
        XCTAssertEqual(AuthActionPolicy.bridgeFloorActions.count, 16)
        for action in AuthActionPolicy.bridgeFloorActions {
            XCTAssertEqual(StepAdvanceResult.minimumBridgeTimeout(stepData: ["action": action]), 120, action)
        }
    }

    func testBridgeFloorIsTheDelegateRequiredSet() {
        XCTAssertEqual(AuthActionPolicy.bridgeFloorActions, AuthActionPolicy.delegateRequiredActions)
        XCTAssertTrue(AuthActionPolicy.bridgeFloorActions.contains("social_login"))
    }

    func testNonAuthActionHasNoFloor() {
        XCTAssertNil(StepAdvanceResult.minimumBridgeTimeout(stepData: ["action": "next"]))
        XCTAssertNil(StepAdvanceResult.minimumBridgeTimeout(stepData: ["action": 5]))
        XCTAssertNil(StepAdvanceResult.minimumBridgeTimeout(stepData: [:]))
        XCTAssertNil(StepAdvanceResult.minimumBridgeTimeout(stepData: nil))
    }

    func testBridgeWaitIsMaxOfConfiguredAndFloor() {
        func wait(_ configured: TimeInterval, _ data: [String: Any]?) -> TimeInterval {
            max(configured, StepAdvanceResult.minimumBridgeTimeout(stepData: data) ?? 0)
        }
        XCTAssertEqual(wait(5, ["action": "social_login"]), 120)
        XCTAssertEqual(wait(150, ["action": "social_login"]), 150)
        XCTAssertEqual(wait(5, ["action": "next"]), 5)
    }
}
