// ContentView.swift
//
// The same four demo buttons the Android sample carries, so a walk on one platform has a
// counterpart on the other. Each button has an `accessibilityIdentifier`, because that is what a
// UI test taps by — a label would tie the test to the copy.
import SwiftUI
import StoreKit
import AppDNASDK

struct ContentView: View {
    /*
     What the SIMULATOR'S STORE actually holds, rendered where a UI test can read it.

     🔴 Written because "the paywall shows the authored price" has two very different causes that
     look identical from outside: the SDK never asked, or the SDK asked and this simulator has no
     products. The second one is a HARNESS fault — `STOREKIT_CONFIGURATION` only copies the file
     into the bundle, and the scheme reference that switches the store over is emitted for the Run
     action and not the Test action — and three cycles went into the first explanation before the
     second turned out to be true. This label distinguishes them in one assertion.

     Empty until `-appdnaProbeStore <id>,<id>` is passed, so a normal run is unchanged.
    */
    @State private var storeProbe = "—"

    /*
     EVERY EVENT THE SDK TRACKS, RENDERED WHERE A UI TEST CAN READ IT.

     🔴 A UI test can only assert what is DRAWN. The SDK's stdout is invisible under
     `xcodebuild test` (which is why `simctl launch --console-pty` exists here),
     so an event that renders nothing — a survey follow-up branch, a dismissal, a permission
     outcome — could be read out of logcat on Android and only INFERRED on this platform.

     `AppDNA.lifecycleDelegate.onEventTracked` makes every one of them observable, and this label
     is the bridge from the delegate to `XCUIApplication`. It keeps the last eight names, newest
     first, so a test can assert an event fired several steps ago without racing the next one.

     Hidden: the label carries no visible UI. A UI test reads a zero-opacity element perfectly well,
     and the host must look the same on a screenshot as it did before.
     */
    @StateObject private var events = TrackedEventLog.shared

    private let surfaces: [(id: String, title: String)] = [
        ("onboarding", "Present Onboarding"),
        ("paywall", "Show Paywall"),
        ("survey", "Show Survey"),
        ("screen", "Show Screen"),
    ]

    /*
     The STORED location answer, recomputed on demand rather than as a plain computed
     property.

     🔴 A computed property here would be read during body evaluation and then never again, because
     nothing in it is observable. On a cold launch that races `SessionDataStore`'s first read of
     `UserDefaults`, so a walk could poll the label twenty times and see the same stale
     "UNANSWERED" — nothing would re-evaluate the view. Refreshing explicitly on appear, and again
     whenever the event mirror changes, removes the hidden dependency.
     */
    @State private var locationReadback = "not read yet"
    /// The RAW stored responses bucket, sorted-key JSON, so a walk reads every key the SDK
    /// persisted (`mapbox_id` included) whatever `LocationData` version the host is built against.
    @State private var responsesRaw = "not read yet"

    private func refreshLocationReadback() {
        responsesRaw = UserDefaults.standard.data(forKey: "appdna.session.onboarding_responses")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "(no bucket)"
        guard let fieldId = Launch.locationFieldId else { locationReadback = "no field asked for"; return }
        guard let d = AppDNA.getLocationData(fieldId: fieldId) else {
            /*
             🔴 SAY WHAT IS ACTUALLY STORED. "UNANSWERED" has three causes that need different
             fixes — the write never happened, it happened under a different key, or
             `LocationData.fromStoredAnswer` cannot parse the shape — and they are
             indistinguishable from the API's nil. The raw bucket is readable here because this is
             the app's own `UserDefaults` and this is a test host, so one failing run names the
             cause instead of costing another round trip.
             */
            /*
             🔴 `data(forKey:)`, NOT `dictionary(forKey:)`. `SessionDataStore.persistDict` stores
             JSON **Data**, so `dictionary(forKey:)` returns nil for a bucket that is present —
             which made this diagnostic report "(no bucket)" for three runs while the real question
             was whether the write had flushed. A diagnostic that can be wrong in the same
             direction as the defect is worse than none.
             */
            let raw = UserDefaults.standard.data(forKey: "appdna.session.onboarding_responses")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let shape = raw.map { dict in
                dict.map { step, value in
                    "\(step):[\((value as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "not-a-dict")]"
                }.sorted().joined(separator: " ")
            } ?? "(no bucket in UserDefaults)"
            locationReadback = "field=\(fieldId) UNANSWERED stored=\(shape)"
            return
        }
        var parts: [String] = ["field=\(fieldId)"]
        if !d.formatted_address.isEmpty { parts.append("addr=\(d.formatted_address)") }
        if let v = d.city, !v.isEmpty { parts.append("city=\(v)") }
        if let v = d.country, !v.isEmpty { parts.append("country=\(v)") }
        if let v = d.country_code, !v.isEmpty { parts.append("cc=\(v)") }
        if let v = d.latitude { parts.append("lat=\(v)") }
        if let v = d.longitude { parts.append("lng=\(v)") }
        if let v = d.timezone, !v.isEmpty { parts.append("tz=\(v)") }
        if let v = d.timezone_offset { parts.append("tzoff=\(v)") }
        if let v = d.raw_query, !v.isEmpty { parts.append("typed=\(v)") }
        locationReadback = parts.joined(separator: " | ")
    }

    static var declaredURLSchemes: String {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        return "schemes:" + schemes.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AppDNA SDK Host")
                .font(.title2.bold())
                .padding(.bottom, 8)
                .accessibilityIdentifier("host.title")

            ForEach(surfaces, id: \.id) { surface in
                Button(surface.title) { Launch.present(surface.id) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(red: 0.42, green: 0.36, blue: 0.70))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .accessibilityIdentifier("host.\(surface.id)")
            }
            Text(storeProbe)
                .font(.caption2.monospaced())
                .accessibilityIdentifier("host.storeProducts")
            Text(events.joined)
                .accessibilityIdentifier("host.lastEvents")
                .opacity(0)
                .frame(height: 0)
            // The URL schemes this build DECLARES (`CFBundleURLTypes`), the same input
            // `URLSafety.hostSchemes` reads. `XCUIApplication.open` delivers a URL without
            // consulting them, so the deep-link UI test asserts on this instead.
            Text(Self.declaredURLSchemes)
                .accessibilityIdentifier("host.urlSchemes")
                .opacity(0)
                .frame(height: 0)

            /*
             The STORED location answer, read back from the SDK rather than from the screen.
             A dropdown that drew "Lisbon, Portugal" proves the provider answered; it says nothing
             about whether the city, country, coordinates and zone were persisted in the shape both
             SDKs decode. This reads `getLocationData(fieldId:)`, which is the host-facing API an
             integrator would use, so the walk asserts the same thing a real app would see.

             Zero-height and transparent, like the event mirror above: it must not change the
             layout the other walks assert against.
             */
            Text(locationReadback)
                .accessibilityIdentifier("host.locationData")
                .opacity(0)
                .frame(height: 0)
            Text(responsesRaw)
                .accessibilityIdentifier("host.responsesRaw")
                .opacity(0)
                .frame(height: 0)
            Spacer()
        }
        .padding(20)
        // The single-parameter form on purpose: `onChange(of:initial:_:)` is iOS 17+, and this host
        // targets lower — the two-parameter version fails the build with
        // "'onChange(of:initial:_:)' is only available in iOS 17.0 or newer".
        .onChange(of: events.joined) { _ in refreshLocationReadback() }
        .onAppear {
            AppDNA.lifecycleDelegate = TrackedEventLog.shared
            // The paywall delegate is a SEPARATE registration, and the action it carries
            // is the only report of a CTA tap that could not become a purchase.
            AppDNA.paywall.setDelegate(TrackedEventLog.shared)
            AppDNA.deepLinks.setDelegate(TrackedEventLog.shared)
            Launch.autoPresentIfAsked()
            refreshLocationReadback()
            probeStoreIfAsked()
        }
    }

    /// Ask StoreKit directly for the ids given in `-appdnaProbeStore`, comma separated, and render
    /// the answer. `0` means this simulator serves no catalogue — a harness fault, not an SDK one.
    private func probeStoreIfAsked() {
        guard let raw = UserDefaults.standard.string(forKey: "appdnaProbeStore"), !raw.isEmpty else { return }
        let ids = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        storeProbe = "store: …"
        Task {
            do {
                let products = try await Product.products(for: Set(ids))
                let shown = products.map { "\($0.id)=\($0.displayPrice)" }.sorted().joined(separator: ",")
                await MainActor.run { storeProbe = "store:\(products.count) \(shown)" }
            } catch {
                await MainActor.run { storeProbe = "store:ERR \(error.localizedDescription)" }
            }
        }
    }
}
