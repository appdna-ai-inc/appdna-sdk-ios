// SessionDataStorePersistFailureTests.swift
//
// A value that cannot be written as JSON (NaN, infinity, a non-JSON type) is not persisted — and that
// is not silent: the store logs a warning naming the entry (never the values). Only THAT entry is left
// out of the saved copy; every other value is still saved.
//
// NEGATIVE CONTROL: the store dropped the WHOLE saved copy for one bad value (the earlier, valid "plan"
// was gone from disk after a NaN "score"), so these tests fail on it.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class SessionDataStorePersistFailureTests: XCTestCase {

    private let sessionKey = "appdna.session.session_data"
    private let responsesKey = "appdna.session.onboarding_responses"
    private var logged: [String] = []
    private var savedLevel: LogLevel = .warning

    override func setUp() {
        super.setUp()
        SessionDataStore.shared.clearAll()
        logged = []
        savedLevel = Log.level
        Log.level = .warning
        Log.testSink = { [weak self] in self?.logged.append($0) }
    }

    override func tearDown() {
        Log.testSink = nil
        Log.level = savedLevel
        SessionDataStore.shared.clearAll()
        super.tearDown()
    }

    private func saved(_ key: String) -> [String: Any]? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func testANaNSessionValueIsLoggedAndOnlyThatKeyIsLeftOut() {
        SessionDataStore.shared.setSessionData(key: "plan", value: "pro")
        XCTAssertNotNil(UserDefaults.standard.data(forKey: sessionKey), "a valid value is persisted")

        SessionDataStore.shared.setSessionData(key: "score", value: Double.nan)

        XCTAssertEqual(saved(sessionKey)?["plan"] as? String, "pro", "the other values are still saved")
        XCTAssertNil(saved(sessionKey)?["score"], "the NaN entry is left out")
        XCTAssertEqual(logged.filter { $0.contains("SessionDataStore") && $0.contains(sessionKey) && $0.contains("score") }.count, 1,
                       "the failure must be logged once, naming the entry: \(logged)")
        XCTAssertFalse(logged.joined().contains("pro"), "values are never logged")
        // The in-memory value still reads for the rest of this session.
        XCTAssertEqual(SessionDataStore.shared.getSessionData(key: "plan") as? String, "pro")
    }

    func testAnInfiniteOnboardingAnswerIsLoggedAndOnlyThatAnswerIsLeftOut() {
        SessionDataStore.shared.setOnboardingResponses(["s": ["name": "Ada"]])
        XCTAssertNotNil(UserDefaults.standard.data(forKey: responsesKey))

        SessionDataStore.shared.setOnboardingResponses([
            "s": ["lat": Double.infinity, "name": "Ada"] as [String: Any],
            "t": ["plan": "pro"],
        ])

        XCTAssertEqual((saved(responsesKey)?["s"] as? [String: Any])?["name"] as? String, "Ada")
        XCTAssertNil((saved(responsesKey)?["s"] as? [String: Any])?["lat"])
        XCTAssertEqual((saved(responsesKey)?["t"] as? [String: Any])?["plan"] as? String, "pro")
        XCTAssertTrue(logged.contains { $0.contains(responsesKey) && $0.contains("s.lat") }, "\(logged)")
    }

    func testAValidValueLogsNothing() {
        SessionDataStore.shared.setSessionData(key: "plan", value: "pro")
        XCTAssertTrue(logged.isEmpty, "\(logged)")
    }
}
