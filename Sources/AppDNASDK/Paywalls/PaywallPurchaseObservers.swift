import Foundation
import Combine

/// Owns `PaywallRenderer`'s three post-purchase observer tokens for exactly the life
/// of the view (a `@StateObject`), and removes them in `deinit`.
///
/// They used to be removed in `.onDisappear` (to stop a leak). But `.onDisappear` also fires when the
/// host covers the paywall with a full-screen cover while a purchase is in flight, so a
/// `.paywallPurchaseEnded` / `.paywallPurchaseFailure` posted in that window reached no one and the CTA
/// stayed spinning when the paywall came back. The paywall is still alive then, so its observers must be too.
///
/// ⚠️ The blocks passed to `register` must NOT capture the view (`self`): the view holds this object, so
/// a block capturing it would make a cycle (holder → token → block → view → holder) and `deinit` would
/// never run. The renderer passes `Binding`s to its `@State` instead.
final class PaywallPurchaseObservers: ObservableObject {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// Registers the three observers, replacing any this holder already has (a repeated `onAppear`).
    func register(
        onSuccess: @escaping (Notification) -> Void,
        onEnded: @escaping (Notification) -> Void,
        onFailure: @escaping (Notification) -> Void
    ) {
        removeAll()
        tokens = [
            center.addObserver(forName: .paywallPurchaseSuccess, object: nil, queue: .main, using: onSuccess),
            center.addObserver(forName: .paywallPurchaseEnded, object: nil, queue: .main, using: onEnded),
            center.addObserver(forName: .paywallPurchaseFailure, object: nil, queue: .main, using: onFailure),
        ]
    }

    /// How many observers are registered (0 or 3). For tests.
    var registeredCount: Int { tokens.count }

    private func removeAll() {
        tokens.forEach { center.removeObserver($0) }
        tokens = []
    }

    deinit {
        removeAll()
    }
}
