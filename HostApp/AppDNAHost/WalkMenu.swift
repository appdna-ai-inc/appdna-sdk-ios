// A DEVICE-WALK MENU, for a person holding the phone.
//
// The launch arguments `Launch` reads (`-appdnaApiKey`, `-appdnaFlow`, …) exist only when something
// launches the app FOR you: Xcode, `devicectl`, `simctl`. A tester who taps the icon on the home
// screen, or a push that cold-launches the app, passes none — so the host configured itself with the
// placeholder key and every surface answered "not found". A walk of a dozen surfaces also needs a
// dozen ids, where the host has one button per surface type.
//
// So a walk build carries its menu IN THE BUNDLE, as two build settings written into Info.plist:
//
//     APPDNA_HOST_API_KEY   the SDK key (used when no `-appdnaApiKey` is passed)
//     APPDNA_WALK_MENU      base64 of {"title": "...", "items": [{"title", "kind", "value"}, ...]}
//
// `kind` is one of: flow (an onboarding flow id), placement (a paywall placement), paywall (a paywall
// id), survey (a survey id), screen (a screen id), track (an event name), push (ask for notification
// permission). Both are EMPTY in the committed project, so a stock build and every UI test behave
// exactly as before. 🔴 This directory is mirrored to the PUBLIC SDK repo: no key, id or URL is ever
// committed here — the values are supplied by whoever builds the walk.
import SwiftUI
import UIKit
import AppDNASDK

struct WalkMenuItem: Decodable, Identifiable {
    let title: String
    let kind: String
    let value: String
    var id: String { "\(kind):\(value):\(title)" }
}

struct WalkMenuConfig: Decodable {
    let title: String?
    let items: [WalkMenuItem]
}

enum WalkMenu {
    static func infoString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An undefined build setting can survive as its literal reference.
        return (v.isEmpty || v.hasPrefix("$(")) ? nil : v
    }

    /// The key baked into a walk build, used only when no launch argument supplies one.
    static var bundledApiKey: String? { infoString("AppDNAHostApiKey") }

    static let config: WalkMenuConfig? = {
        guard let b64 = infoString("AppDNAWalkMenu"), let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(WalkMenuConfig.self, from: data)
    }()

    static var isActive: Bool { !(config?.items.isEmpty ?? true) }

    /// The controller currently on top, which a placement paywall is presented from.
    static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        return top
    }

    static func run(_ item: WalkMenuItem) {
        let log = TrackedEventLog.shared
        switch item.kind {
        case "flow":
            let shown = AppDNA.presentOnboarding(flowId: item.value)
            log.note("presentOnboarding(\(item.title)) → \(shown ? "presented" : "NOT presented (flow not found)")")
        case "placement":
            guard let vc = topViewController() else { log.note("no view controller to present from"); return }
            let shown = AppDNA.presentPaywall(placement: item.value, from: vc)
            log.note("presentPaywall(placement: \(item.value)) → \(shown ? "presented" : "NOT presented (no paywall)")")
        case "paywall":
            AppDNA.showPaywall(item.value)
            log.note("showPaywall(\(item.title))")
        case "survey":
            AppDNA.showSurvey(item.value)
            log.note("showSurvey(\(item.title))")
        case "screen":
            AppDNA.showScreen(item.value) { result in log.note("screen \(item.title) → \(result)") }
            log.note("showScreen(\(item.title))")
        case "track":
            AppDNA.track(event: item.value)
            log.note("track(\(item.value))")
        case "identify":
            AppDNA.identify(userId: item.value)
            log.note("identify(\(item.value))")
        case "consent":
            let on = item.value == "true"
            AppDNA.setConsent(analytics: on)
            log.note("setConsent(analytics: \(on))")
        case "push":
            Task {
                let granted = await AppDNA.registerForPush()
                log.note("notification permission → \(granted ? "granted" : "denied")")
            }
        default:
            log.note("unknown walk item kind \(item.kind)")
        }
    }
}

/// Forwards the APNs token to the SDK. The SDK installs its own notification-centre proxy for taps.
final class WalkAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppDNA.setPushToken(deviceToken)
        TrackedEventLog.shared.note("APNs token registered (\(deviceToken.count) bytes)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        TrackedEventLog.shared.note("APNs registration failed: \(error.localizedDescription)")
    }
}

struct WalkMenuView: View {
    @StateObject private var log = TrackedEventLog.shared
    @State private var responses = "—"

    private func refreshResponses() {
        responses = UserDefaults.standard.data(forKey: "appdna.session.onboarding_responses")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .prettyPrinted]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "(none stored)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Surfaces") {
                    ForEach(WalkMenu.config?.items ?? []) { item in
                        Button(item.title) { WalkMenu.run(item) }
                            .accessibilityIdentifier("walk.\(item.kind).\(item.value)")
                    }
                }
                Section("Log (newest first)") {
                    ForEach(Array(log.detail.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                Section("Stored onboarding responses") {
                    Text(responses).font(.caption2.monospaced())
                    Button("Refresh responses") { refreshResponses() }
                }
            }
            .navigationTitle(WalkMenu.config?.title ?? "Walk")
        }
        .onAppear {
            AppDNA.lifecycleDelegate = TrackedEventLog.shared
            AppDNA.paywall.setDelegate(TrackedEventLog.shared)
            AppDNA.deepLinks.setDelegate(TrackedEventLog.shared)
            AppDNA.onboarding.setDelegate(TrackedEventLog.shared)
            refreshResponses()
        }
        .onChange(of: log.names) { _ in refreshResponses() }
        // A deep link — a push, an in-app CTA, a typed URL — lands on its OWN screen, so "the app opened
        // on the linked screen, not the root" is something a tester can see.
        .sheet(item: $log.deepLink) { link in
            VStack(spacing: 16) {
                Text("Deep link screen").font(.largeTitle.bold())
                Text("\(link.url.host ?? "")\(link.url.path)").font(.title2.monospaced())
                Text(link.url.absoluteString).font(.footnote.monospaced()).foregroundColor(.secondary)
                Button("Back to the menu") { log.deepLink = nil }.padding(.top, 24)
            }
            .padding()
            .accessibilityIdentifier("walk.deepLinkScreen")
        }
    }
}
