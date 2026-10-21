// TrackedEventVisibilityUITests.swift — #1047
//
// THE GENERAL GAP, not one event. A UI test can only assert what is DRAWN, and the SDK's stdout is
// invisible under `xcodebuild test` — so on this platform every claim about an event that renders
// nothing was an inference from the code, while Android could read the same claim out of logcat.
//
// `AppDNALifecycleDelegate.onEventTracked` closes it: the host feeds a zero-opacity label from it,
// and `XCUIApplication` reads that label like any other element. This test proves the pipe works,
// which is what makes EVERY future event-only assertion possible — `trigger_winback` was simply
// the first one to need it.
//
// Skipped unless `TestCredentials` has been filled in — `packages/appdna-sdk-ios/**` is a public
// mirror and must carry no credentials.
import XCTest

final class TrackedEventVisibilityUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }

    func testEveryTrackedEventIsReadableFromAUITest() throws {
        guard let apiKey else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }

        let app = XCUIApplication()
        app.launchArguments += ["-appdnaApiKey", apiKey]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        let log = app.staticTexts["host.lastEvents"]
        XCTAssertTrue(log.waitForExistence(timeout: 20),
                      "the host must render the tracked-event log, even at zero opacity")

        /*
         🔴 THE NEGATIVE CONTROL FIRST. An empty label would make every `contains` below pass for
         the worst possible reason — the harness seeing nothing — which is the shape #923's first
         render test shipped. So the test asserts the log has CONTENT before asserting what is in
         it. The SDK tracks `session_started` and `app_opened` at configure, so by the time the
         host screen is up there is something.
         */
        let deadline = Date().addingTimeInterval(25)
        while (log.label.isEmpty || log.label == "—"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertFalse(log.label.isEmpty,
                       "the log is EMPTY — the delegate is not wired, and every assertion that "
                         + "reads it would pass for the wrong reason")

        /*
         The SDK's own launch events are the ones guaranteed to exist without driving a surface, so
         they are what this asserts. The claim is the PIPE, not any particular event: once this
         label carries names, a walk can assert `survey_followup_winback` or `push_dismissed` or
         anything else that renders nothing.

         🔴 The names are `sdk_initialized` and `session_start`, READ OFF A REAL RUN rather than
         guessed. The first version of this test guessed `session_started` / `app_opened` and
         failed against a log that already read "sdk_initialized session_start" — the negative
         control above is what made that a wrong expectation rather than a broken pipe.
         */
        let observed = log.label
        print("[#1047] host.lastEvents = \(observed)")
        XCTAssertTrue(
            observed.contains("sdk_initialized") || observed.contains("session_start"),
            "expected one of the SDK's launch events in the log; got \"\(observed)\"",
        )
    }
}
