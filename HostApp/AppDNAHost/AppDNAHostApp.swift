// AppDNAHostApp.swift
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
        WindowGroup {
            ContentView()
                // `appdnasample://…` (declared in Info.plist) — a custom-scheme CTA or push deep link
                // opened by the OS comes back here, and the SDK hands it to the deep-link delegate.
                .onOpenURL { url in AppDNA.deepLinks.handleURL(url) }
        }
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

    /*
     The field id whose STORED location answer the host reads back.
     `getLocationData(fieldId:)` scans every onboarding response for that key, so the walk can
     assert what was persisted rather than what the dropdown drew. Without it the only evidence a
     suggestion was really selected is a screenshot of the suggestion, which says nothing about
     whether the city, country, coordinates and zone reached the store.
     */
    static var locationFieldId: String? { arg("appdnaLocationField") }

    static func configureSDK() {
        // An absent key still configures: the SDK then fails its bootstrap loudly, which is a
        // better state to debug than an app that quietly did nothing at launch.
        let key = arg("appdnaApiKey") ?? "appdna_sandbox_demo_key"
        AppDNA.configure(apiKey: key, environment: .sandbox)
        /*
         `-appdnaLogLevel info` (or debug). The SDK defaults to `.warning`, so every `Log.info` is
         SUPPRESSED — including the lines that say which branch a decision took. That cost a cycle
         on the store-price substitution: the store-price lookup logs its three failure modes at info, the paywall rendered
         the authored price, and the log had nothing in it either way, which is indistinguishable
         from the code never running.
        */
        #if DEBUG
        armRootSwapIfAsked()
        #endif

        if let lvl = arg("appdnaLogLevel") {
            switch lvl.lowercased() {
            case "debug": AppDNA.setLogLevel(.debug)
            case "info": AppDNA.setLogLevel(.info)
            case "error": AppDNA.setLogLevel(.error)
            case "none": AppDNA.setLogLevel(.none)
            default: AppDNA.setLogLevel(.warning)
            }
            NSLog("AppDNA-E2E log level \(lvl)")
        }
        NSLog("AppDNA-E2E host configured env=sandbox key=\(key.prefix(8))…")
    }

    /*
     TEAR THE PRESENTATION STACK DOWN WHILE A FORM IS UP.

     The defect is a feedback form orphaned when its presenter goes away for a reason of the host's
     own. Reproducing it needs a host that does exactly that, deterministically, at a moment a test
     controls — so the swap is triggered by the app being BACKGROUNDED and brought back, which a UI
     test can drive precisely (`XCUIDevice.press(.home)` then `activate()`), rather than by a timer
     a test has to race.

     Debug-only and opt-in: `-appdnaSwapRootOnForeground`.
    */
    #if DEBUG
    private static var swapObserver: NSObjectProtocol?
    private static var backgroundObserver: NSObjectProtocol?

    static func armRootSwapIfAsked() {
        guard arg("appdnaSwapRootOnForeground") != nil, swapObserver == nil else { return }
        /*
         🔴 THE SIGNAL IS A BACKGROUNDING, not an activation count.

         Counting activations was wrong twice over: from zero it missed the first one (so a genuine
         return looked like launch), and seeded from the current state it fired on the SECOND
         activation SwiftUI raises during its own launch sequence — the host swapped its root half
         a second after starting, `host.title` never appeared, and the test failed before it
         reached anything about the SDK.

         `didEnterBackground` happens exactly once per trip to the home screen and never during
         launch, so it is the unambiguous edge.
        */
        NSLog("AppDNA-E2E root swap armed")
        var wasBackgrounded = false
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in wasBackgrounded = true }
        swapObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            guard wasBackgrounded else { return }
            wasBackgrounded = false
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?
                .windows.first(where: { $0.isKeyWindow }) else { return }
            NSLog("AppDNA-E2E swapping the root view controller")
            // A LABEL, not a bare controller: an empty `UIViewController`'s view does not surface
            // as a queryable element, so a test could not tell "the swap did not run" from "the
            // swap ran and the alert survived" — which is the whole question.
            let replacement = UIHostingController(
                rootView: Text("swapped").accessibilityIdentifier("host.swappedRoot")
            )
            window.rootViewController = replacement
        }
    }

    #endif

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
