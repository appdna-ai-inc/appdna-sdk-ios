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
//     -appdnaAutoPresentDelay 8      seconds before presenting, so the fetched config has landed
//     -appdnaIdentify <user id>      identify after configure (a consent walk)
//     -appdnaConsent true|false      setConsent after configure (a consent walk)
//     -appdnaIdentifyAt tick|ready   when: right after configure, on the same tick, or in onReady (default)
//
// Auto-present exists because the simulator exposes no tap verb to this environment — no `simctl`
// verb, no `idb`, and `osascript` is blocked. A UI TEST can tap (it runs inside the simulator), and
// `AppDNAHostUITests` does exactly that; auto-present is for the screenshot walks that do not want
// a test runner in the way.
import SwiftUI
import UIKit
import WidgetKit
import AppDNASDK

@main
struct AppDNAHostApp: App {
    // Forwards the APNs token to the SDK (a walk build asks for notification permission from its menu).
    @UIApplicationDelegateAdaptor(WalkAppDelegate.self) private var appDelegate
    init() { Launch.configureSDK() }
    var body: some Scene {
        WindowGroup {
            // A walk build (`APPDNA_WALK_MENU` set) opens on its menu; every other build is unchanged.
            Group { if WalkMenu.isActive { WalkMenuView() } else { ContentView() } }
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

    /*
     `-appdnaStdoutFile <name>` (a launch argument, or the app's defaults domain): stdout goes to
     Documents/<name>, line-buffered. The SDK logs with `print`, and an app the OS launches in the BACKGROUND
     (a silent push, a fetch) has no console, so without this nothing it logged there can be read.
    */
    static func redirectStdoutIfAsked() {
        guard let name = arg("appdnaStdoutFile"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = docs.appendingPathComponent(name).path
        guard freopen(path, "a", stdout) != nil else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        print("AppDNA-E2E stdout → \(path) at \(Date())")
    }

    static func configureSDK() {
        redirectStdoutIfAsked()
        // An absent key still configures: the SDK then fails its bootstrap loudly, which is a
        // better state to debug than an app that quietly did nothing at launch.
        let key = arg("appdnaApiKey") ?? WalkMenu.bundledApiKey ?? "appdna_sandbox_demo_key"
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
        seedOnboardingCacheIfAsked()
        probeWidgetsIfAsked()
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
        consentWalkIfAsked()
    }

    /*
     A CONSENT WALK: identify and set the analytics decision the way a host app calls them, after
     `configure`, from launch arguments. The SDK sends its consent signal on its own; the walk reads
     the server's row. Nothing happens without the arguments.
    */
    static func consentWalkIfAsked() {
        let user = arg("appdnaIdentify")
        let consent = arg("appdnaConsent")
        guard user != nil || consent != nil else { return }
        let apply = {
            if let user { AppDNA.identify(userId: user) }
            if let consent { AppDNA.setConsent(analytics: consent == "true") }
        }
        if arg("appdnaIdentifyAt") == "tick" {
            // On the configure tick, as a host that restores its signed-in user at launch does: the SDK is still
            // configuring, so the calls are held and applied once it has.
            apply()
            NSLog("AppDNA-E2E consent-walk at=tick user_id=\(user ?? "(unchanged)") consent=\(consent ?? "(unchanged)")")
            return
        }
        // Once the SDK is ready, as a host that identifies after its own sign-in does.
        AppDNA.onReady {
            apply()
            NSLog("AppDNA-E2E consent-walk at=ready user_id=\(user ?? "(unchanged)") consent=\(consent ?? "(unchanged)")")
        }
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
    /*
     A SYNTHETIC FLOW WITHOUT A SERVER: `-appdnaSeedOnboarding <name>` writes the bundled
     `WalkFlows/<name>.json` (the published shape: `{"flows": {<id>: <flow>}}`) into the SDK's config
     cache before `configure`. With no reachable bootstrap the SDK runs on its cached config, so the
     flow is decoded, rendered and operated by production code; only the delivery from the console is
     skipped. Debug-only and opt-in.
    */
    static func seedOnboardingCacheIfAsked() {
        guard let name = arg("appdnaSeedOnboarding"),
              let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        UserDefaults(suiteName: "ai.appdna.sdk.config")?.set(data, forKey: "onboarding")
        NSLog("AppDNA-E2E seeded the onboarding cache from \(name).json")
    }

    /*
     WHAT WIDGETKIT REPORTS, IN THE SYSTEM LOG: `-appdnaProbeWidgets` logs the host's placed widgets
     (`WidgetCenter.getCurrentConfigurations`) at launch and on every return to the foreground, as
     `AppDNA-E2E widgets n=<count> [...]`, so a walk can read what the SDK's detection read — a UI test
     cannot see the SDK's stdout. Debug-only and opt-in.
    */
    private static var widgetProbeObserver: NSObjectProtocol?
    static func probeWidgetsIfAsked() {
        guard arg("appdnaProbeWidgets") != nil, widgetProbeObserver == nil else { return }
        func probe(_ when: String) {
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .success(let infos):
                    NSLog("AppDNA-E2E widgets \(when) n=\(infos.count) \(infos.map { "\($0.kind)/\($0.family)/h\($0.hashValue)" })")
                case .failure(let error):
                    NSLog("AppDNA-E2E widgets \(when) failed \(error)")
                }
            }
        }
        probe("launch")
        widgetProbeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            probe("active")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { probe("active+2s") }
        }
    }

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
