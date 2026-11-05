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

final class TrackedEventLog: ObservableObject, AppDNALifecycleDelegate, AppDNAPaywallDelegate, AppDNADeepLinkDelegate {
    static let shared = TrackedEventLog()

    /// Newest first, capped — a test asserts on an event from several steps ago without racing
    /// the next one, and an app that runs for a while does not grow this without bound.
    private static let capacity = 8

    @Published private(set) var names: [String] = []

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
    }

    /// A deep link the SDK delivered (`AppDNA.deepLinks.handleURL`), mirrored so a walk can read it.
    func onDeepLinkReceived(url: URL, params: [String: String]) {
        record("deeplink:" + url.absoluteString)
    }

    func onEventTracked(name: String, properties: [String: Any]) {
        record(name)
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
