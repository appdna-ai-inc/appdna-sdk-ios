import Foundation

/// The SDK's three runtime settings — `flushInterval`, `batchSize` and `configTTL` — and where each value
/// comes from.
///
/// Precedence, per setting: a value the host passed to `configure` (`AppDNAOptions`) > the value the
/// bootstrap answer carries in `settings` > the built-in default. The built-in default applies until a
/// bootstrap answer arrives, and stays when none does or when it does not carry the field. A bootstrap value
/// of 0 or less is ignored, so a server answer can never stop uploads; a host value is used as given.
///
/// `batchSize` is a cap on the adaptive, network-sized batch (100 on Wi-Fi or wired, 50 on cellular, 20 on an
/// expensive connection, 0 offline): the effective size is the adaptive one when no cap is set, otherwise the
/// smaller of the two. It is both the queue length that triggers a flush and the most one upload sends. A
/// cap of 0 holds every event on the device. Android `RuntimeSettings`, same rules; both are pinned by the
/// shared fixture `resilience/runtime_settings_precedence`.
enum RuntimeSettings {
    static let defaultFlushInterval: TimeInterval = 30
    static let defaultConfigTTL: TimeInterval = 3600

    /// The values in force after resolving host options against a bootstrap answer.
    struct Resolved: Equatable {
        let flushInterval: TimeInterval
        /// nil: no cap (the adaptive size).
        let batchSizeCap: Int?
        let configTTL: TimeInterval
    }

    /// explicit > bootstrap (positive only) > fallback.
    static func resolve<T: Comparable & Numeric>(explicit: T?, bootstrap: T?, fallback: T?) -> T? {
        if let explicit { return explicit }
        if let bootstrap, bootstrap > 0 { return bootstrap }
        return fallback
    }

    /// Resolve all three settings. `bootstrap` is nil before (or without) a successful bootstrap.
    static func resolveAll(options: AppDNAOptions, bootstrap: BootstrapSettings?) -> Resolved {
        Resolved(
            flushInterval: resolve(
                explicit: options.requestedFlushInterval,
                bootstrap: bootstrap?.flushInterval.map(TimeInterval.init),
                fallback: defaultFlushInterval
            ) ?? defaultFlushInterval,
            batchSizeCap: resolve(explicit: options.requestedBatchSize, bootstrap: bootstrap?.batchSize, fallback: nil),
            configTTL: resolve(
                explicit: options.requestedConfigTTL,
                bootstrap: bootstrap?.configTTL.map(TimeInterval.init),
                fallback: defaultConfigTTL
            ) ?? defaultConfigTTL
        )
    }

    /// The batch size in effect: the adaptive size, capped by `cap` when one is set (never below 0).
    static func effectiveBatchSize(adaptive: Int, cap: Int?) -> Int {
        guard let cap else { return adaptive }
        return min(adaptive, max(cap, 0))
    }
}

/// The batch-size cap in force, persisted so the background uploader (a BGProcessingTask that can run in a
/// fresh process, outside the queue) sends batches no larger than the queue would. Written by the queue when
/// it starts and whenever a bootstrap changes the cap; nil (no key) means no cap. Android
/// `BatchSizeCapGate`, same rule.
enum BatchSizeCapGate {
    private static let key = "ai.appdna.sdk.batch_size_cap"
    static func set(_ cap: Int?) {
        if let cap { UserDefaults.standard.set(cap, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    static var cap: Int? { UserDefaults.standard.object(forKey: key) as? Int }
}
