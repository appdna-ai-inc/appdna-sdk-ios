// StepAdvanceResultFloorTests.swift
//
// The sign-in bridge floor: every member of `AuthActionPolicy.bridgeFloorActions`
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
        // The SDK's INTERNAL `max(configured, floor)` (reached through `@testable import`; not public API,
        // ) — the one line every wrapper bridge applies with the public
        // `minimumBridgeTimeout(stepData:)`.
        XCTAssertEqual(StepAdvanceResult.bridgeTimeout(configured: 5, stepData: ["action": "social_login"]), 120)
        XCTAssertEqual(StepAdvanceResult.bridgeTimeout(configured: 150, stepData: ["action": "social_login"]), 150)
        XCTAssertEqual(StepAdvanceResult.bridgeTimeout(configured: 5, stepData: ["action": "next"]), 5)
        XCTAssertEqual(StepAdvanceResult.bridgeTimeout(configured: 5, stepData: nil), 5)
        for action in AuthActionPolicy.bridgeFloorActions {
            XCTAssertEqual(StepAdvanceResult.bridgeTimeout(configured: 5, stepData: ["action": action]),
                           StepAdvanceResult.authBridgeTimeout, action)
        }
    }
}
