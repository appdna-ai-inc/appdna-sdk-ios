// SessionDataStorePersistFailureTests.swift
//
// A value that cannot be written as JSON (NaN, infinity, a non-JSON type) is not persisted — and that
// is no longer silent: the store logs a warning naming the key (never the values) and clears the
// previously saved copy, so the next launch does not reload data the app has since replaced.
//
// NEGATIVE CONTROL: with the old `guard … else { return }` both tests fail — no warning is logged and
// the earlier, valid copy is still in UserDefaults.
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

    func testANaNSessionValueIsLoggedAndTheStaleCopyIsCleared() {
        SessionDataStore.shared.setSessionData(key: "plan", value: "pro")
        XCTAssertNotNil(UserDefaults.standard.data(forKey: sessionKey), "a valid value is persisted")

        SessionDataStore.shared.setSessionData(key: "score", value: Double.nan)

        XCTAssertNil(UserDefaults.standard.data(forKey: sessionKey),
                     "the earlier copy must not survive: it no longer matches the session")
        XCTAssertEqual(logged.filter { $0.contains("SessionDataStore") && $0.contains(sessionKey) }.count, 1,
                       "the failure must be logged once, naming the key: \(logged)")
        XCTAssertFalse(logged.joined().contains("pro"), "values are never logged")
        // The in-memory value still reads for the rest of this session.
        XCTAssertEqual(SessionDataStore.shared.getSessionData(key: "plan") as? String, "pro")
    }

    func testAnInfiniteOnboardingAnswerIsLoggedAndTheStaleCopyIsCleared() {
        SessionDataStore.shared.setOnboardingResponses(["s": ["name": "Ada"]])
        XCTAssertNotNil(UserDefaults.standard.data(forKey: responsesKey))

        SessionDataStore.shared.setOnboardingResponses(["s": ["lat": Double.infinity] as [String: Any]])

        XCTAssertNil(UserDefaults.standard.data(forKey: responsesKey))
        XCTAssertTrue(logged.contains { $0.contains(responsesKey) }, "\(logged)")
    }

    func testAValidValueLogsNothing() {
        SessionDataStore.shared.setSessionData(key: "plan", value: "pro")
        XCTAssertTrue(logged.isEmpty, "\(logged)")
    }
}
