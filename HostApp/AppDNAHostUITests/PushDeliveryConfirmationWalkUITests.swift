// PushDeliveryConfirmationWalkUITests.swift
//
// The device half of the delivery-confirmation walk. Delivered counts only what the device confirms, and on iOS a push
// that arrives while the app is closed is confirmed by the Notification Service Extension alone.
//
// What this test drives:
//   1. the walk menu's "Allow notifications" item, and the system alert, so the host registers a REAL APNs token
//      (sandbox) with the walk server;
//   2. the Home button, so the host is in the BACKGROUND;
//   3. a wait (`PUSH_WAIT_SECONDS`, default 120) while the walk operator sends a plain push to this device through
//      the server's real routes (a walk script under `scripts/walks/`). APNs delivers it, iOS runs the
//      extension, and the extension posts the receipt (the operator reads `delivered_at` off the row);
//   4. the app again, so the SDK drains the App Group hand-off and tracks `push_delivered` — asserted here, on the
//      host's event log.
//
// A `simctl push` does NOT run a Notification Service Extension on the simulator (measured: the notification is
// added straight to Notification Center, no extension process starts), which is why the push must come from APNs.
//
// Skipped unless `TestCredentials` has been filled in — `packages/appdna-sdk-ios/**` is a public mirror.
import XCTest

final class PushDeliveryConfirmationWalkUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func logContains(_ app: XCUIApplication, _ needle: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", needle)
        return app.staticTexts.containing(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    func testABackgroundPushIsConfirmedByTheExtensionAndTrackedWhenTheAppReturns() throws {
        guard !TestCredentials.apiKey.isEmpty else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        let app = XCUIApplication()
        // A walk user of its own, so earlier walks' frequency-cap counters never filter the push.
        app.launchArguments += ["-appdnaApiKey", TestCredentials.apiKey, "-appdnaLogLevel", "debug",
                                "-appdnaIdentify", "probe-delivery-walk-ios"]
        app.launch()

        // 1 — permission and a real APNs token.
        let allow = app.buttons["walk.push."]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "the walk menu's push item must be drawn (APPDNA_WALK_MENU)")
        allow.tap()
        let alertAllow = springboard.alerts.buttons["Allow"]
        if alertAllow.waitForExistence(timeout: 10) { alertAllow.tap() }
        XCTAssertTrue(logContains(app, "permission → granted", timeout: 20), "notification permission must be granted")
        XCTAssertTrue(logContains(app, "APNs token registered", timeout: 60), "the simulator must receive an APNs token")
        // The control for the final assertion: nothing has been delivered yet.
        XCTAssertFalse(logContains(app, "push_delivered", timeout: 1))

        // 2 — the app goes to the background.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        print("PUSH-WALK: backgrounded at \(Date()) — send the push now")

        // 3 — the operator sends the push meanwhile; its banner shows over the Home Screen.
        let wait = Double(ProcessInfo.processInfo.environment["PUSH_WAIT_SECONDS"] ?? "") ?? 120
        let banner = springboard.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", "Delivery walk")).firstMatch
        let shown = banner.waitForExistence(timeout: wait)
        print("PUSH-WALK: banner seen = \(shown)")
        // Stay in the background a while, so the row's delivered_at can only have come from the extension: the app
        // cannot report anything until it is activated below.
        Thread.sleep(forTimeInterval: 40)
        print("PUSH-WALK: activating the app at \(Date())")

        // 4 — the app returns: the hand-off is drained and push_delivered is tracked.
        app.activate()
        XCTAssertTrue(logContains(app, "push_delivered", timeout: 30),
                      "the SDK must track push_delivered for the delivery the extension handed over")
    }
}
