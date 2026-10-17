// ContentView.swift — #908
//
// The same four demo buttons the Android sample carries, so a walk on one platform has a
// counterpart on the other. Each button has an `accessibilityIdentifier`, because that is what a
// UI test taps by — a label would tie the test to the copy.
import SwiftUI
import AppDNASDK

struct ContentView: View {
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
            Spacer()
        }
        .padding(20)
        .onAppear { Launch.autoPresentIfAsked() }
    }
}
