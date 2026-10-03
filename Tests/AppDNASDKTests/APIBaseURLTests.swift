// APIBaseURLTests.swift
//
// The test-only base-URL override (Info.plist `AppDNABaseURLOverride`).
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class APIBaseURLTests: XCTestCase {

    override func tearDown() {
        APIBaseURL.infoPlistReaderForTesting = nil
        APIBaseURL.gateForTesting = nil
        AppDNA.diagnoseEnvironmentForTesting = nil
        super.tearDown()
    }

    private func install(_ value: Any?, gate: Bool) {
        APIBaseURL.infoPlistReaderForTesting = { $0 == APIBaseURL.infoPlistKey ? value : nil }
        APIBaseURL.gateForTesting = { gate }
    }

    func testSandboxKeyAndGateUseTheOverride() {
        install("https://x.example", gate: true)
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox), "https://x.example")
        XCTAssertEqual(Endpoint.bootstrap.url(environment: .sandbox)?.host, "x.example")
    }

    func testProductionIgnoresTheOverride() {
        install("https://x.example", gate: true)
        XCTAssertEqual(APIBaseURL.resolve(environment: .production), "https://api.appdna.ai")
        XCTAssertEqual(Endpoint.bootstrap.url(environment: .production)?.host, "api.appdna.ai")
    }

    func testClosedGateIgnoresTheOverride() {
        install("https://x.example", gate: false)
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox), "https://api.appdna.ai")
    }

    func testNoKeyUsesProduction() {
        install(nil, gate: true)
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox), "https://api.appdna.ai")
    }

    func testValueValidation() {
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox, overrideValue: "", gateOpen: true), "https://api.appdna.ai")
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox, overrideValue: "   ", gateOpen: true), "https://api.appdna.ai")
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox, overrideValue: "https://x.example/", gateOpen: true), "https://x.example")
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox, overrideValue: "x.example", gateOpen: true), "https://api.appdna.ai")
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox, overrideValue: "ftp://x.example", gateOpen: true), "https://api.appdna.ai")
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox, overrideValue: 42, gateOpen: true), "https://api.appdna.ai")
        XCTAssertEqual(APIBaseURL.resolve(environment: .sandbox, overrideValue: "http://10.0.0.2:3000", gateOpen: true), "http://10.0.0.2:3000")
    }

    func testSimulatorPassesTheGate() {
        #if targetEnvironment(simulator)
        XCTAssertTrue(APIBaseURL.isNonAppStoreBuild())
        #endif
    }

    func testDiagnoseReportsTheResolvedBase() {
        install("https://x.example/", gate: true)
        AppDNA.diagnoseEnvironmentForTesting = .sandbox
        XCTAssertTrue(AppDNA.diagnose().contains("base_url: https://x.example"))
        XCTAssertFalse(AppDNA.diagnose().contains("base_url: https://x.example/"))
        AppDNA.diagnoseEnvironmentForTesting = .production
        XCTAssertTrue(AppDNA.diagnose().contains("base_url: https://api.appdna.ai"))
    }
}
