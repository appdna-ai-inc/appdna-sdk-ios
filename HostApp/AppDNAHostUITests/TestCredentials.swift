// TestCredentials.swift
//
// 🔴 PLACEHOLDERS, AND THEY STAY PLACEHOLDERS. `packages/appdna-sdk-ios/**` is force-pushed to the
// PUBLIC SDK mirror. `scripts/sdk-host-ios.ts` overwrites this file ON THE MAC, after the sync and
// before the build, exactly as `patch-sample.py` patches the Android sample — so the real values
// exist only inside a build on the bridge and never in a commit.
//
// A generated constant rather than an environment variable because `TEST_RUNNER_<VAR>=…` on the
// `xcodebuild test` command line does NOT reach the UI-test runner's `ProcessInfo` here: the
// setting is accepted, the run goes green, and the test that needed it is quietly SKIPPED. That
// looks exactly like a harness that works, which is the failure this file exists to avoid.
enum TestCredentials {
    static let apiKey = ""
    static let surveyId = ""
    static let paywallId = ""
    static let flowId = ""
    /// The location walk's own flow. Empty = that test skips, rather than presenting
    /// whatever `flowId` happens to name and failing on a screen it was never looking at.
    static let locationFlowId = ""
    /// The Rive walk's own flow, for the same reason.
    static let riveFlowId = ""
    /// The category-bubbles walk's own flow: a scrolling row of eight bubbles filtering
    /// three selects, plus a Segmented element authored `bubble` next to a plain one. Empty = skip.
    static let categoryFlowId = ""
    /// The feedback-form walk's own survey. It waits for `survey.rating.1`, so it needs a
    /// survey whose FIRST question is a numeric rating; the survey walk's is an emoji scale, and
    /// pointing both at one survey made this test report a network problem it did not have.
    static let feedbackSurveyId = ""
    /// A location flow whose SECOND step's heading interpolates the first step's answer
    /// (`{{responses.<step>.<field>.city}} · …timezone}}`). Empty = that test skips.
    static let templateFlowId = ""
}
