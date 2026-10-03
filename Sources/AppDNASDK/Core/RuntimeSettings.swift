import Foundation

/// The SDK's three runtime settings — `flushInterval`, `batchSize` and `configTTL` — and where each value
/// comes from.
///
/// Precedence, per setting: a value the host passed to `configure` (`AppDNAOptions`) > the value the
/// bootstrap answer carries in `settings` > the built-in default. The built-in default applies until a
/// bootstrap answer arrives, and stays when none does or when it does not carry the field. A bootstrap value
/// of 0 or less is ignored, so a server answer can never stop uploads; so is a host value of 0 or less (logged as a
/// warning): the setting then resolves as if the host had not set it. So is a host value EQUAL to the option's
/// default (flushInterval 30, batchSize 100, configTTL 3600): Android's options keep non-null public values, so
/// there a value at its default is the only "not set" there is; both platforms read it the same way.
///
/// `batchSize` is a cap on the adaptive, network-sized batch (100 on Wi-Fi or wired, 50 on cellular, 20 on an
/// expensive connection, 0 offline): the effective size is the adaptive one when no cap is set, otherwise the
/// smaller of the two. It is both the queue length that triggers a flush and the most one upload sends. Only an
/// internal test seam can install a cap of 0 (which holds every event on the device); no option or answer can. Android `RuntimeSettings`, same rules; both are pinned by the
/// shared fixture `resilience/runtime_settings_precedence`.
enum RuntimeSettings {
    static let defaultFlushInterval: TimeInterval = 30
    static let defaultConfigTTL: TimeInterval = 3600
    /// `AppDNAOptions.batchSize`'s default (the largest network-sized batch: no cap of the host's own).
    static let defaultBatchSizeOption = 100

    /// The host's value, or nil when it passed none or passed the option's default (Android: the same rule).
    static func hostValue<T: Equatable>(_ requested: T?, default value: T) -> T? {
        guard let requested, requested != value else { return nil }
        return requested
    }

    /// The values in force after resolving host options against a bootstrap answer.
    struct Resolved: Equatable {
        let flushInterval: TimeInterval
        /// nil: no cap (the adaptive size).
        let batchSizeCap: Int?
        let configTTL: TimeInterval
    }

    /// explicit (positive only) > bootstrap (positive only) > fallback.
    static func resolve<T: Comparable & Numeric>(explicit: T?, bootstrap: T?, fallback: T?) -> T? {
        if let explicit, explicit > 0 { return explicit }
        if let bootstrap, bootstrap > 0 { return bootstrap }
        return fallback
    }

    /// Resolve all three settings. `bootstrap` is nil before (or without) a successful bootstrap.
    static func resolveAll(options: AppDNAOptions, bootstrap: BootstrapSettings?) -> Resolved {
        warnIgnored("flushInterval", options.requestedFlushInterval)
        warnIgnored("batchSize", options.requestedBatchSize)
        warnIgnored("configTTL", options.requestedConfigTTL)
        return Resolved(
            flushInterval: resolve(
                explicit: hostValue(options.requestedFlushInterval, default: defaultFlushInterval),
                bootstrap: bootstrap?.flushInterval.map(TimeInterval.init),
                fallback: defaultFlushInterval
            ) ?? defaultFlushInterval,
            batchSizeCap: resolve(explicit: hostValue(options.requestedBatchSize, default: defaultBatchSizeOption),
                                  bootstrap: bootstrap?.batchSize, fallback: nil),
            configTTL: resolve(
                explicit: hostValue(options.requestedConfigTTL, default: defaultConfigTTL),
                bootstrap: bootstrap?.configTTL.map(TimeInterval.init),
                fallback: defaultConfigTTL
            ) ?? defaultConfigTTL
        )
    }

    /// A host value below 1 is not used; say so once per resolve.
    private static func warnIgnored<T: Comparable & Numeric>(_ name: String, _ value: T?) {
        if let value, value <= 0 {
            Log.warning("AppDNAOptions.\(name) must be 1 or more; \(value) is ignored and the default applies.")
        }
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
