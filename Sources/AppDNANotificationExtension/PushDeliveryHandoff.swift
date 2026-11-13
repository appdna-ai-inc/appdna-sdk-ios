import Foundation

/// the deliveries the Notification Service Extension confirmed, handed to the app through a shared App Group.
///
/// The extension confirms each delivery to the server itself (the push's signed receipt), which sets `delivered_at`.
/// The `push_delivered` ANALYTICS event, though, belongs to the app's event pipeline (its identity, session and consent),
/// which the extension does not have. So, when the host shares an App Group between the app and the extension and
/// names it under the `AppDNAAppGroup` Info.plist key in BOTH targets, the extension records each delivery here, and the
/// app's SDK tracks `push_delivered` for it the next time it is configured or becomes active — once: a delivery the app
/// already saw in the foreground is removed from the store when the app tracks it.
///
/// Without an App Group nothing is stored, and only the server-side delivery (from the receipt) is counted.
@_spi(AppDNAInternal)
public struct PushDeliveryHandoff {
    /// The Info.plist key (app and extension) naming the shared App Group.
    public static let appGroupInfoKey = "AppDNAAppGroup"
    static let storeKey = "ai.appdna.push.delivered_pending"
    /// The most deliveries kept: a device that never opens the app must not grow the store without bound.
    public static let capacity = 100

    public struct Record: Equatable {
        public let pushId: String
        public let deliveryId: String
        public let confirmedAtMs: Int64
    }

    private let defaults: UserDefaults

    public init?(appGroup: String?) {
        guard let appGroup, !appGroup.isEmpty, let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        self.defaults = defaults
    }

    /// The store for the App Group named in `bundle`'s Info.plist, or nil when none is named.
    public init?(bundle: Bundle) {
        self.init(appGroup: bundle.object(forInfoDictionaryKey: Self.appGroupInfoKey) as? String)
    }

    /// Test seam.
    public init(defaults: UserDefaults) { self.defaults = defaults }

    private func load() -> [[String: Any]] { defaults.array(forKey: Self.storeKey) as? [[String: Any]] ?? [] }

    /// The extension records a delivery it confirmed (once per delivery id; the oldest beyond `capacity` are dropped).
    public func record(pushId: String, deliveryId: String, now: Date = Date()) {
        guard !deliveryId.isEmpty else { return }
        var all = load().filter { ($0["delivery_id"] as? String) != deliveryId }
        all.append(["push_id": pushId, "delivery_id": deliveryId, "at": Int64(now.timeIntervalSince1970 * 1000)])
        if all.count > Self.capacity { all.removeFirst(all.count - Self.capacity) }
        defaults.set(all, forKey: Self.storeKey)
    }

    /// The app takes every recorded delivery, oldest first, and clears the store.
    public func takeAll() -> [Record] {
        let all = load()
        defaults.removeObject(forKey: Self.storeKey)
        return all.compactMap { d in
            guard let deliveryId = d["delivery_id"] as? String, !deliveryId.isEmpty else { return nil }
            let at = (d["at"] as? NSNumber)?.int64Value ?? 0
            return Record(pushId: d["push_id"] as? String ?? "", deliveryId: deliveryId, confirmedAtMs: at)
        }
    }

    /// The app saw this delivery itself (foreground): it is not handed over again.
    public func discard(deliveryId: String) {
        let all = load()
        let kept = all.filter { ($0["delivery_id"] as? String) != deliveryId }
        if kept.count != all.count { defaults.set(kept, forKey: Self.storeKey) }
    }

    public var count: Int { load().count }
}
