import Foundation

/// SDK environment targeting.
public enum Environment: String, Sendable {
    case production
    case sandbox
}

/// Log verbosity levels.
public enum LogLevel: Int, Comparable, Sendable {
    case none = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Billing provider for paywall purchase flows.
///
/// Wire format (SPEC-070-B / fixture `dto_parsing/billing_provider_adapty_tagged_map`): the value-less
/// cases cross a wrapper channel as BARE STRINGS (`"storeKit2"`, `"revenueCat"`, `"none"`), while
/// `adapty` — the only case with an associated value — crosses as the TAGGED MAP
/// `{"type": "adapty", "apiKey": "..."}`. Read from Android `Configuration.kt:71/:95`
/// (`fromWire` / `toWire`); the tags, the key spelling (`apiKey`, not `api_key`), and the
/// bare-vs-tagged split are matched EXACTLY. iOS had none of this — the enum wasn't even `Codable`,
/// so an Adapty key handed to a wrapper had nowhere to go.
public enum BillingProvider: Sendable, Codable, Equatable {
    case revenueCat
    case storeKit2
    case adapty(apiKey: String)
    case none

    /// The wire tag. Identical strings on both platforms — these ARE the contract.
    public var type: String {
        switch self {
        case .storeKit2: return "storeKit2"
        case .revenueCat: return "revenueCat"
        case .adapty: return "adapty"
        case .none: return "none"
        }
    }

    /// The Adapty publishable key, when this is `.adapty`. Nil otherwise.
    public var apiKey: String? {
        if case .adapty(let key) = self { return key }
        return nil
    }

    /// Decode the wrapper wire form: a bare string for the value-less cases, or a tagged map for
    /// `adapty`. Returns nil on anything else — including a BARE `"adapty"`, which carries no apiKey
    /// and therefore cannot be honored — so the caller decides between a default and an error rather
    /// than having one silently chosen for it. Mirrors Android `BillingProvider.fromWire`.
    public static func fromWire(_ value: Any?) -> BillingProvider? {
        if let provider = value as? BillingProvider { return provider }
        // `BillingProvider.none`, spelled out. A bare `.none` in a `BillingProvider?` return position
        // resolves to `Optional.none` — i.e. NIL — so `fromWire("none")` reported "unparseable" for the
        // one provider value that explicitly says "this app does no billing". The compiler warned
        // ("assuming you mean 'Optional<BillingProvider>.none'"); `BillingProviderWireTests` did not
        // catch it because `XCTAssertEqual(fromWire("none"), .none)` collapses to `nil == nil` and
        // passes vacuously. The shared fixture, which asserts the STRING "none", is what caught it.
        if let string = value as? String {
            switch string {
            case "storeKit2": return .storeKit2
            case "revenueCat": return .revenueCat
            case "none": return BillingProvider.none
            default: return nil
            }
        }
        if let map = value as? [String: Any] {
            guard let type = map["type"] as? String else { return nil }
            switch type {
            case "adapty":
                guard let apiKey = map["apiKey"] as? String, !apiKey.isEmpty else { return nil }
                return .adapty(apiKey: apiKey)
            case "storeKit2": return .storeKit2
            case "revenueCat": return .revenueCat
            case "none": return BillingProvider.none
            default: return nil
            }
        }
        return nil
    }

    /// Re-encode to the wire form. Lossless round-trip with `fromWire`. Mirrors Android `toWire()`.
    public func toWire() -> Any {
        switch self {
        case .adapty(let apiKey):
            return ["type": "adapty", "apiKey": apiKey] as [String: Any]
        default:
            return type
        }
    }

    // MARK: Codable — same shape as fromWire/toWire, so JSON and channel maps agree.

    private enum CodingKeys: String, CodingKey {
        case type
        case apiKey
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            guard let provider = BillingProvider.fromWire(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown BillingProvider tag '\(raw)' (a bare \"adapty\" carries no apiKey)"
                )
            }
            self = provider
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "adapty":
            let apiKey = try container.decode(String.self, forKey: .apiKey)
            guard !apiKey.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .apiKey,
                    in: container,
                    debugDescription: "BillingProvider.adapty requires a non-empty apiKey"
                )
            }
            self = .adapty(apiKey: apiKey)
        case "storeKit2": self = .storeKit2
        case "revenueCat": self = .revenueCat
        case "none": self = .none
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown BillingProvider type '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .adapty(let apiKey):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("adapty", forKey: .type)
            try container.encode(apiKey, forKey: .apiKey)
        default:
            var container = encoder.singleValueContainer()
            try container.encode(type)
        }
    }
}

/// Configuration options for the AppDNA SDK.
public struct AppDNAOptions: Sendable {
    /// Automatic flush interval in seconds: the value passed to `init`, or 30 when none was. When the host
    /// does not set it, the bootstrap answer's `settings.flushInterval` (if positive) replaces the default
    /// once the bootstrap succeeds.
    public let flushInterval: TimeInterval
    /// The most events one upload sends, and the queue length that triggers a flush: a cap on the
    /// network-sized batch (100 on Wi-Fi or wired, 50 on cellular, 20 on an expensive connection). The value
    /// passed to `init`, or 100 (no cap) when none was; then the bootstrap answer's `settings.batchSize`
    /// (if positive) is the cap. A value below 1 is ignored (logged) as if none was passed.
    public let batchSize: Int
    /// Remote config cache TTL in seconds: the value passed to `init`, or 3600 (1 hour) when none was; then
    /// the bootstrap answer's `settings.configTTL` (if positive) replaces the default.
    public let configTTL: TimeInterval
    /// The `flushInterval` the host passed to `init`; nil when it passed none.
    public let requestedFlushInterval: TimeInterval?
    /// The `batchSize` the host passed to `init`; nil when it passed none (no cap of its own).
    public let requestedBatchSize: Int?
    /// The `configTTL` the host passed to `init`; nil when it passed none.
    public let requestedConfigTTL: TimeInterval?
    /// Log verbosity. Default: .warning.
    public let logLevel: LogLevel
    /// Billing provider for paywall purchases. Default: .storeKit2.
    public let billingProvider: BillingProvider
    /// SPEC-070-C D4 — SDK-wrapper attribution (`native` | `flutter` | `react_native`),
    /// tagged on every event's device context (→ BigQuery `framework` column). Defaults
    /// to `native`; the Flutter/RN wrappers pass their identity via configure().
    public let framework: String

    /// SPEC-070-C — the wrapper SDK's OWN published version (e.g. Flutter "1.0.5"),
    /// passed by the wrapper so diagnose() reports the wrapper version per platform
    /// instead of the native core version. nil for native hosts.
    public let frameworkVersion: String?

    /// SPEC-070-B PN row 14 (AC-36) — when true, analytics stay OFF until the host calls
    /// `setConsent(analytics:)`, and no event (including `sdk_initialized`) is emitted before that
    /// decision. When false — the default, preserving today's behavior — analytics are opt-out.
    ///
    /// Either way the decision is now **persisted**: `setConsent(false)` used to be silently undone
    /// by the next cold start.
    public let requireConsent: Bool

    /// SPEC-070-B PN row 16 (W12) — how long a wrapper waits for a host veto before applying the
    /// hook's default. A legitimate veto (a server-side entitlement, fraud, or promo check) can
    /// exceed 5 s on a bad network; past this timeout `onPromoCodeSubmit` silently rejects and the
    /// seven default-allow hooks are silently bypassed. Surfaced through `diagnose()`.
    public let vetoTimeout: TimeInterval

    public init(
        flushInterval: TimeInterval? = nil,
        batchSize: Int? = nil,
        configTTL: TimeInterval? = nil,
        logLevel: LogLevel = .warning,
        billingProvider: BillingProvider = .storeKit2,
        framework: String = "native",
        frameworkVersion: String? = nil,
        requireConsent: Bool = false,
        vetoTimeout: TimeInterval = 5
    ) {
        self.requestedFlushInterval = flushInterval
        self.requestedBatchSize = batchSize
        self.requestedConfigTTL = configTTL
        self.flushInterval = flushInterval.flatMap { $0 > 0 ? $0 : nil } ?? RuntimeSettings.defaultFlushInterval
        self.batchSize = batchSize.flatMap { $0 > 0 ? $0 : nil } ?? 100
        self.configTTL = configTTL.flatMap { $0 > 0 ? $0 : nil } ?? RuntimeSettings.defaultConfigTTL
        self.logLevel = logLevel
        self.billingProvider = billingProvider
        self.framework = framework
        self.frameworkVersion = frameworkVersion
        self.requireConsent = requireConsent
        self.vetoTimeout = vetoTimeout
    }
}

// MARK: - Internal Logger

enum Log {
    static var level: LogLevel = .warning

    /// Test seam: when set, every warning and error that passes the level check is also handed here.
    /// Nil in production.
    static var testSink: ((String) -> Void)?

    static func error(_ message: @autoclosure () -> String) {
        guard level >= .error else { return }
        let text = "[AppDNA][ERROR] \(message())"
        testSink?(text)
        print(text)
    }

    static func warning(_ message: @autoclosure () -> String) {
        guard level >= .warning else { return }
        let text = "[AppDNA][WARN] \(message())"
        testSink?(text)
        print(text)
    }

    static func info(_ message: @autoclosure () -> String) {
        guard level >= .info else { return }
        print("[AppDNA][INFO] \(message())")
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard level >= .debug else { return }
        print("[AppDNA][DEBUG] \(message())")
    }
}
