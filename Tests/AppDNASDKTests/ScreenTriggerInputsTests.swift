import XCTest
@testable import AppDNASDK

/// Days since install, as a screen's `days_since_install` trigger reads it: whole days, never negative, nil when unknown.
final class ScreenTriggerInputsTests: XCTestCase {
    private let day: Int64 = 86_400_000
    private let install: Int64 = 1_700_000_000_000

    func testWholeDaysRoundDown() {
        XCTAssertEqual(ScreenTriggerInputs.daysSinceInstall(installEpochMs: install, nowMs: install + day - 1), 0)
        XCTAssertEqual(ScreenTriggerInputs.daysSinceInstall(installEpochMs: install, nowMs: install + day), 1)
        XCTAssertEqual(ScreenTriggerInputs.daysSinceInstall(installEpochMs: install, nowMs: install + 7 * day + 5), 7)
    }

    func testAClockBeforeTheInstallIsDayZero() {
        XCTAssertEqual(ScreenTriggerInputs.daysSinceInstall(installEpochMs: install, nowMs: install - day), 0)
    }

    func testAnUnknownInstallIsUnknown() {
        XCTAssertNil(ScreenTriggerInputs.daysSinceInstall(installEpochMs: nil, nowMs: install))
    }

    /// The live inputs read the real sources: the session counter SessionManager writes, and the install marker.
    func testCurrentReadsTheSessionCounterAndTheInstallMarker() {
        let key = SessionManager.sessionCountKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(4, forKey: key)
        let inputs = ScreenTriggerInputs.current()
        XCTAssertEqual(inputs.sessionCount, 4)
        if let installMs = AppInstallDate.epochMs() {
            XCTAssertEqual(inputs.daysSinceInstall, ScreenTriggerInputs.daysSinceInstall(
                installEpochMs: installMs, nowMs: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))))
        } else {
            XCTAssertNil(inputs.daysSinceInstall)
        }
    }
}
