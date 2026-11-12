// TrackedEventLog.swift
//
// The host's `AppDNALifecycleDelegate`, kept for ONE reason: a UI test can only assert what is
// drawn, and the SDK's stdout is invisible under `xcodebuild test`. So every event the SDK tracks
// is rendered into a zero-opacity label (`host.lastEvents`) that `XCUIApplication` reads like any
// other element.
//
// 🔴 This is HOST code, not SDK code. An integrator does not need it — they implement
// `onEventTracked` for their own pipeline. It lives here because the gap it closes is ours: before
// it, an event that renders nothing could be proven on Android (logcat) and only inferred here.
import Foundation
import AppDNASDK

final class TrackedEventLog: ObservableObject, AppDNALifecycleDelegate, AppDNAPaywallDelegate, AppDNADeepLinkDelegate, AppDNAOnboardingDelegate {
    static let shared = TrackedEventLog()

    /// Newest first, capped — a test asserts on an event from several steps ago without racing
    /// the next one, and an app that runs for a while does not grow this without bound.
    private static let capacity = 8

    @Published private(set) var names: [String] = []

    /// The walk menu's visible log (`WalkMenuView`): newest first, with the detail a person needs to
    /// judge a row — the presentation result, the deep link, a completed flow's responses.
    @Published private(set) var detail: [String] = []

    /// The last deep link the SDK handed the host; the walk menu shows it on its own screen.
    @Published var deepLink: WalkDeepLink?

    func note(_ line: String) {
        let stamp = Self.clock.string(from: Date())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.detail = Array(([stamp + " " + line] + self.detail).prefix(40))
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// One string, because an accessibility value is one string. The separator is a space so a
    /// test can use `contains("survey_followup_winback")` without worrying about neighbours.
    var joined: String { names.joined(separator: " ") }

    private init() {}

    /*
     🔴 A PAYWALL ACTION IS NOT A TRACKED EVENT, so it needs its own door into the same
     mirror. `onPaywallAction` reports what the user DID — the CTA was tapped — separately from
     what it achieved, and a tap that cannot become a purchase emits no event at all. Folding it in
     here under its raw value means one label carries both, and a walk reading `host.lastEvents`
     can tell "the SDK never heard the tap" from "the store did not answer".
     */
    func onPaywallAction(paywallId: String, action: PaywallAction) {
        record("action:" + action.rawValue)
        note("paywall action: " + action.rawValue)
    }

    /// A deep link the SDK delivered (`AppDNA.deepLinks.handleURL`), mirrored so a walk can read it.
    func onDeepLinkReceived(url: URL, params: [String: String]) {
        record("deeplink:" + url.absoluteString)
        note("deep link received: \(url.absoluteString)")
        DispatchQueue.main.async { [weak self] in self?.deepLink = WalkDeepLink(url: url) }
    }

    /*
     The onboarding callbacks a walk has to READ, not infer: which step is on screen (so a timed
     advance can be clocked from the log), what a toggle or other element handed the host
     (`onElementInteraction`, e.g. `toggle_dark_mode` with "true"/"false"), and the responses a
     completed flow delivered. Observe-only: every hook returns the SDK's default.
     */
    func onOnboardingStepChanged(flowId: String, stepId: String, stepIndex: Int, totalSteps: Int) {
        note("step \(stepIndex + 1)/\(totalSteps) \(stepId)")
    }

    func onOnboardingCompleted(flowId: String, responses: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: responses, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(responses)"
        note("onboarding completed responses=" + json)
    }

    func onElementInteraction(flowId: String, stepId: String, blockId: String, action: String,
                              value: String?, inputValues: [String: Any]) async -> ElementInteractionResult? {
        note("element blockId=\(blockId) action=\(action) value=\(value ?? "nil")")
        return nil
    }

    func onEventTracked(name: String, properties: [String: Any]) {
        record(name)
        note(name + Self.summary(properties))
    }

    private func record(_ name: String) {
        /*
         🔴 Hop to the main thread HERE, in the host, rather than asking the SDK to.
         `onEventTracked` fires on whatever thread tracked the event — deliberately, because
         hopping inside the SDK would reorder events against the queue they were just written to —
         and `@Published` must be mutated on the main thread.
         */
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = [name] + self.names
            if next.count > Self.capacity { next = Array(next.prefix(Self.capacity)) }
            self.names = next
        }
    }
}

extension TrackedEventLog {
    /// The properties a walk reads, compactly: ids, products, errors and a completed flow's responses.
    static func summary(_ properties: [String: Any]) -> String {
        let keys = ["flow_id", "paywall_id", "survey_id", "product_id", "placement", "step_id", "error", "reason", "url", "responses"]
        let parts = keys.compactMap { k -> String? in
            guard let v = properties[k] else { return nil }
            if JSONSerialization.isValidJSONObject(v),
               let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
               let s = String(data: d, encoding: .utf8) { return "\(k)=\(s)" }
            return "\(k)=\(v)"
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}

/// A received deep link, identifiable so a sheet can present it.
struct WalkDeepLink: Identifiable {
    let id = UUID()
    let url: URL
}

