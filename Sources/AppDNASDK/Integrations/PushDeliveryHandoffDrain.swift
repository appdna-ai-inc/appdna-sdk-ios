import Foundation
import UIKit
@_spi(AppDNAInternal) import AppDNANotificationExtension

/// tracks `push_delivered` for the deliveries the host's Notification Service Extension confirmed while the app
/// was not running (see `PushDeliveryHandoff`). Runs at the push configured point and each time the app becomes active.
///
/// Each delivery is tracked once: it claims the same `PushIdempotency` key the foreground path claims, and the
/// foreground path removes a delivery it tracked from the store (`discard`), so a later launch does not re-track it.
/// Tracking goes through `PushTokenManager.trackDelivered`, so the event takes the app's identity, session and consent
/// like any other, and `/push/delivered` is called too (the server counts it once with the extension's receipt).
enum PushDeliveryHandoffDrain {
    /// Test seam: the store (production: the App Group named under `AppDNAAppGroup` in the app's Info.plist).
    static var storeProvider: () -> PushDeliveryHandoff? = { PushDeliveryHandoff(bundle: .main) }
    private static let lock = NSLock()
    private static var observers: [NSObjectProtocol] = []

    /// Installs the become-active trigger once per process.
    static func installOnce() {
        lock.lock(); defer { lock.unlock() }
        guard observers.isEmpty else { return }
        observers = [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in drain() }
        }
    }

    /// Tracks every delivery the extension handed over, then clears the store. Does nothing before the push configured
    /// point (no manager to track with); the store is kept for the next drain.
    @discardableResult
    static func drain() -> Int {
        guard PushGate.shared.isConfigured, let manager = AppDNA.pushModule.manager, let store = storeProvider() else { return 0 }
        var tracked = 0
        for record in store.takeAll() where PushIdempotency.claim(.delivered, key: record.deliveryId) {
            manager.trackDelivered(pushId: record.pushId, deliveryId: record.deliveryId)
            tracked += 1
        }
        return tracked
    }

    /// The app tracked this delivery itself (it arrived in the foreground): not handed over again.
    static func discard(deliveryId: String?) {
        guard let deliveryId, !deliveryId.isEmpty else { return }
        storeProvider()?.discard(deliveryId: deliveryId)
    }
}
