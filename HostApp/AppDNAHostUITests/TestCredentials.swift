// TestCredentials.swift — #901
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
}
