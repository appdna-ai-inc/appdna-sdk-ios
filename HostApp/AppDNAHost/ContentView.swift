// ContentView.swift — #908
//
// The same four demo buttons the Android sample carries, so a walk on one platform has a
// counterpart on the other. Each button has an `accessibilityIdentifier`, because that is what a
// UI test taps by — a label would tie the test to the copy.
import SwiftUI
import StoreKit
import AppDNASDK

struct ContentView: View {
    /*
     #923 — what the SIMULATOR'S STORE actually holds, rendered where a UI test can read it.

     🔴 Written because "the paywall shows the authored price" has two very different causes that
     look identical from outside: the SDK never asked, or the SDK asked and this simulator has no
     products. The second one is a HARNESS fault — `STOREKIT_CONFIGURATION` only copies the file
     into the bundle, and the scheme reference that switches the store over is emitted for the Run
     action and not the Test action — and three cycles went into the first explanation before the
     second turned out to be true. This label distinguishes them in one assertion.

     Empty until `-appdnaProbeStore <id>,<id>` is passed, so a normal run is unchanged.
    */
    @State private var storeProbe = "—"

    private let surfaces: [(id: String, title: String)] = [
        ("onboarding", "Present Onboarding"),
        ("paywall", "Show Paywall"),
        ("survey", "Show Survey"),
        ("screen", "Show Screen"),
    ]

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
            Spacer()
        }
        .padding(20)
        .onAppear {
            Launch.autoPresentIfAsked()
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
