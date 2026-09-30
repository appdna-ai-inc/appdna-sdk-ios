// SocialLoginStepDataTests.swift
//
// A `social_login` tap's step data: the step's inputs first, the SDK's `provider` / `action` last, so an
// input field with id `action` or `provider` cannot override them (Android builds it in the same order).
//
// NEGATIVE CONTROL: with the old order (SDK keys first, then every input copied over them) the first
// test fails — `action` becomes the input's value, which also takes the tap out of the sign-in gate.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class SocialLoginStepDataTests: XCTestCase {

    func testAnInputNamedActionOrProviderCannotOverrideTheSdkKeys() {
        let data = SocialLoginStepData.build(
            provider: "apple",
            inputValues: ["action": "next", "provider": "typed", "email": "a@example.com"]
        )
        XCTAssertEqual(data["action"] as? String, "social_login")
        XCTAssertEqual(data["provider"] as? String, "apple")
        XCTAssertEqual(data["email"] as? String, "a@example.com", "other inputs are kept")
        XCTAssertTrue(AuthActionPolicy.bridgeFloorActions.contains(data["action"] as? String ?? ""),
                      "the tap stays a sign-in action")
    }

    func testAMissingProviderIsUnknown() {
        let data = SocialLoginStepData.build(provider: nil, inputValues: [:])
        XCTAssertEqual(data["provider"] as? String, "unknown")
        XCTAssertEqual(data["action"] as? String, "social_login")
    }
}
