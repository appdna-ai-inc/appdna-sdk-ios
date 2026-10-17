// AppDNAHostApp.swift — #908
//
// The iOS counterpart of `packages/appdna-sdk-android/sample`. Android has had one all along,
// which is why every device walk this month has an Android column and an "iOS unproven" note.
//
// 🔴 NOTHING REAL IS COMMITTED HERE. This directory is force-pushed to the PUBLIC SDK mirror, so
// the api key, the base URL and the surface ids are all read at RUN time — from launch arguments
// or the environment — and the defaults below are placeholders. `scripts/sdk-host-ios.ts` supplies
// the real ones, exactly as `patch-sample.py` does for the Android sample.
//
// Driving it:
//
//     -appdnaApiKey <key>            the SDK key to configure with
//     -appdnaPaywall <id>            ids for the four buttons
//     -appdnaFlow <id>
//     -appdnaSurvey <id>
//     -appdnaScreen <id>
//     -appdnaAutoPresent paywall     present one straight away, without a tap
//     -appdnaAutoPresentDelay 8      seconds to wait for config before presenting
//
// Auto-present exists because the simulator exposes no tap verb to this environment — no `simctl`
// verb, no `idb`, and `osascript` is blocked. A UI TEST can tap (it runs inside the simulator), and
// `AppDNAHostUITests` does exactly that; auto-present is for the screenshot walks that do not want
// a test runner in the way.
import SwiftUI
import UIKit
import AppDNASDK

@main
struct AppDNAHostApp: App {
    init() { Launch.configureSDK() }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Launch-time configuration, read from arguments so nothing has to be baked into the bundle.
enum Launch {
    static func arg(_ name: String) -> String? {
        let v = UserDefaults.standard.string(forKey: name)
        return (v?.isEmpty == false) ? v : nil
    }

    static var paywallId: String { arg("appdnaPaywall") ?? "demo_paywall" }
    static var flowId: String { arg("appdnaFlow") ?? "demo_onboarding" }
    static var surveyId: String { arg("appdnaSurvey") ?? "demo_survey" }
    static var screenId: String { arg("appdnaScreen") ?? "demo_screen" }

    static func configureSDK() {
        // An absent key still configures: the SDK then fails its bootstrap loudly, which is a
        // better state to debug than an app that quietly did nothing at launch.
        let key = arg("appdnaApiKey") ?? "appdna_sandbox_demo_key"
        AppDNA.configure(apiKey: key, environment: .sandbox)
        NSLog("AppDNA-E2E host configured env=sandbox key=\(key.prefix(8))…")
    }

    /// Present a surface without a tap, after giving the SDK time to fetch its config.
    static func autoPresentIfAsked() {
        guard let what = arg("appdnaAutoPresent") else { return }
        let delay = Double(arg("appdnaAutoPresentDelay") ?? "") ?? 8
        NSLog("AppDNA-E2E auto-presenting \(what) in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { present(what) }
    }

    static func present(_ what: String) {
        switch what {
        case "paywall": AppDNA.showPaywall(paywallId)
        case "onboarding": AppDNA.presentOnboarding(flowId: flowId)
        case "survey": AppDNA.showSurvey(surveyId)
        case "screen": AppDNA.showScreen(screenId)
        default: NSLog("AppDNA-E2E unknown surface \(what)")
        }
    }
}
