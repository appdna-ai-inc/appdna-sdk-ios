// DeferredDeepLinkRetryTests.swift
//
// A TRANSPORT FAILURE MUST NOT SPEND THE ONE CHANCE.
//
// A deferred deep link is resolvable exactly once, on the first launch ever. `markLaunched()` used
// to run on every path out of the fetch — the error case and the missing-Firestore branch included
// — so a user who installed from a link and opened the app with no network lost the destination and
// the referrer permanently, and silently: the host got `nil`, which is indistinguishable from "this
// install did not come from a link".
//
// 🔴 `AppDNA.firestoreDB` is nil in a unit test, which is exactly the "nothing was asked" branch.
// So this drives the real manager through the real `UserDefaults`.
//
// 🔴 It does NOT read the simulator's pasteboard. `UIPasteboard.general.string` blocks while iOS asks the user to
// allow a paste whenever the pasteboard holds another process's text, and in a test no one answers: on a shared
// simulator where a walk had copied text, this test hung the whole suite (sampled: the main thread parked in
// `-[_UIConcretePasteboard string]` under `checkPasteboard()`). Each check gets an empty pasteboard of its own.
import XCTest
@testable import AppDNASDK

final class DeferredDeepLinkRetryTests: XCTestCase {

    private let firstLaunchKey = "ai.appdna.sdk.first_launch_completed"
    private let attemptsKey = "ai.appdna.sdk.ddl_failed_attempts"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: firstLaunchKey)
        UserDefaults.standard.removeObject(forKey: attemptsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: firstLaunchKey)
        UserDefaults.standard.removeObject(forKey: attemptsKey)
        super.tearDown()
    }

    /// One check, driven to its completion handler.
    private func check() -> Bool {
        let done = expectation(description: "checkDeferredDeepLink called back")
        DeferredDeepLinkManager(orgId: "org", appId: "app", eventTracker: nil, pasteboard: EmptyPasteboard())
            .checkDeferredDeepLink { _ in done.fulfill() }
        return XCTWaiter.wait(for: [done], timeout: 5) == .completed
    }

    func testAFailedCheckKeepsTheChanceAndGivesUpAfterFour() throws {
        let max = DeferredDeepLinkManager.maxFailedAttempts

        // Attempts 1..max-1: the chance survives, and the count is what survives it.
        for n in 1..<max {
            XCTAssertTrue(check(), "the host must always get its callback")
            XCTAssertFalse(
                UserDefaults.standard.bool(forKey: firstLaunchKey),
                "attempt \(n) failed without reaching the server — the chance must survive it",
            )
            XCTAssertEqual(
                UserDefaults.standard.integer(forKey: attemptsKey), n,
                "attempt \(n) must be counted",
            )
        }

        // The last one gives up, so a permanently offline device stops asking.
        XCTAssertTrue(check())
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: firstLaunchKey),
            "after \(max) failures the chance IS spent",
        )

        /*
         🔴 NEGATIVE CONTROL. Everything above is also true of a manager that never marks launched
         at all — including the "gives up" assertion, if something else were setting the key. Once
         the flag is set, a further check must return WITHOUT counting another attempt: that is the
         early return at the top of `checkDeferredDeepLink`, and it is what distinguishes "the
         chance is spent" from "the chance was never tracked".
         */
        let countedWhenSpent = UserDefaults.standard.integer(forKey: attemptsKey)
        XCTAssertTrue(check())
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: attemptsKey), countedWhenSpent,
            "a check after the flag is set must not reach the fetch at all",
        )
    }
}

/// A pasteboard with nothing on it, which never asks the user.
private struct EmptyPasteboard: PasteboardReading {
    var string: String? { nil }
    func clear() {}
}
