import Foundation
import UIKit

/// Event envelope matching the server event schema.
struct SDKEvent: Codable {
    let schema_version: Int
    let event_id: String
    let event_name: String
    let ts_ms: Int64
    let user: EventUser
    let device: EventDevice
    let context: EventContext
    let properties: [String: AnyCodable]?
    let privacy: EventPrivacy
}

struct EventUser: Codable {
    let anon_id: String
    let user_id: String?
}

struct EventDevice: Codable {
    let platform: String
    let os: String
    let app_version: String
    let sdk_version: String
    let bundle_version: Int?
    let locale: String
    let country: String
    /// SDK-wrapper attribution (native|flutter|react_native).
    let framework: String
    /// The WRAPPER's own version (the RN npm package / the Flutter pub
    /// package), which `sdk_version` cannot express because that one is always the native core.
    /// Optional, and Codable omits it when nil — so a native host's envelope is byte-identical to
    /// what it was, and no existing consumer sees a new key.
    let framework_version: String?
    /// The device's IANA time-zone id (`TimeZone.current.identifier`, e.g. "Europe/Berlin"), so the
    /// server can send time-zone-aware pushes, quiet hours and journey waits in the user's own zone
    /// without the host passing a `timezone` trait. Optional: an event persisted by an older SDK decodes
    /// without it, and nil is omitted from the JSON.
    let timezone: String?
}

struct EventContext: Codable {
    let session_id: String
    let screen: String?
    // The push_id of the most recent push received within the last 30 min, so conversions can be
    // attributed to the push that drove them. Mirrors Android's `context.push_id`; iOS shipped no such
    // field, so push→conversion attribution was Android-only.
    let push_id: String?
    let experiment_exposures: [ExperimentExposure]?
    // Per-device monotonic sequence, assigned at buildEnvelope.
    let client_seq: Int64?
}

/// Device-wide MONOTONIC sequence counter. Persisted in UserDefaults (a
/// FACADE-available store, not the EventStore/EventQueue which are built inside configure()), so it
/// survives restart and is readable before configure(). The single increment site is buildEnvelope.
enum ClientSeqCounter {
    // `key` persists the RESERVED CEILING (>= every seq handed out). We hand out from
    // an in-memory block and WRITE only when the block is exhausted — persisting the ceiling ABOVE the
    // values we hand out — so a hard kill between the async UserDefaults write and its disk flush yields a
    // GAP (the unused reserved tail), NEVER a REUSE of an already-emitted seq (fixture #3 forbids reuse).
    // Also O(1) amortized: one store write every `blockSize`, not per event (hot-path budget).
    private static let key = "ai.appdna.sdk.client_seq"
    private static let lock = NSLock()
    private static let blockSize: Int64 = 100
    private static var current: Int64 = 0
    private static var ceiling: Int64 = 0
    private static var loaded = false

    static func next() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            // Restart: resume from the persisted ceiling (>= every seq handed out before a crash).
            let persisted = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value ?? 0
            current = persisted
            ceiling = persisted
            loaded = true
        }
        current += 1
        if current > ceiling {
            ceiling = current + blockSize
            UserDefaults.standard.set(NSNumber(value: ceiling), forKey: key)
            // Force the ceiling to disk at the (rare) block boundary so it is DURABLE before we hand out a
            // seq from the new block — a hard kill then yields a gap, NEVER a reuse. synchronize() is
            // deprecated but remains the way to force a UserDefaults flush; only ~1 in blockSize pays it.
            UserDefaults.standard.synchronize()
        }
        return current
    }

    /// Test hook: reset the in-memory block + persisted ceiling so a fresh test starts clean.
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        current = 0; ceiling = 0; loaded = false
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Test hook: simulate a COLD restart — drop the in-memory block WITHOUT clearing the persisted
    /// ceiling, so the next next() re-reads it (exercises the restore branch; a crash yields a gap).
    static func simulateRestartForTesting() {
        lock.lock()
        defer { lock.unlock() }
        loaded = false
    }
}

struct ExperimentExposure: Codable {
    let exp: String
    let variant: String
}

struct EventPrivacy: Codable {
    let consent: Consent
}

struct Consent: Codable {
    let analytics: Bool
}

// MARK: - AnyCodable wrapper for properties dict

public struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        // An `Int64` (epoch milliseconds: `purchase_time`, `purchased_at_ms`) used to fall
        // through to `String(describing:)` and reach the server as a STRING.
        case let int64 as Int64:
            try container.encode(int64)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}

// MARK: - Event builder

enum EventEnvelopeBuilder {
    private static let osVersionString: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Where the device's zone is read from: `TimeZone.current` in production, called on EVERY event.
    /// Test seam — tests set it and restore it: `NSTimeZone.default` does not reach `TimeZone.current` on
    /// every simulator (iOS 26.2 reports the host Mac's zone), so tests cannot steer the zone through it.
    static var timeZoneProvider: () -> TimeZone = { TimeZone.current }

    /// The device's IANA zone id, or nil when the platform reports none. Read per event (not cached) so a
    /// user who travels is scheduled in the zone they are in now.
    static func deviceTimeZoneId() -> String? {
        let id = timeZoneProvider().identifier
        return id.isEmpty ? nil : id
    }

    static func build(
        event: String,
        properties: [String: Any]?,
        identity: DeviceIdentity,
        sessionId: String,
        analyticsConsent: Bool,
        experimentExposures: [ExperimentExposure]? = nil,
        // The currently-visible screen, supplied by EventTracker's screenProvider.
        // Mirrors Android's `screen = screenProvider?.invoke()` (EventTracker.kt:116).
        screen: String? = nil,
        // The current push_id (within the 30-min window), supplied by EventTracker's pushIdProvider.
        // Mirrors Android's `pushId = pushIdProvider?.invoke()`.
        pushId: String? = nil,
        // A PRE-STAMPED client_seq (a pre-init event stamped its seq at facade
        // track() time). When present, buildEnvelope MUST use it verbatim and NOT re-mint at drain — else
        // a post-configure event minting during the drain window gets a LOWER seq than an earlier pre-init
        // event drained afterward = ordering inversion.
        clientSeq: Int64? = nil
    ) -> SDKEvent {
        let bundleVer = AppDNA.currentBundleVersion > 0 ? AppDNA.currentBundleVersion : nil
        let device = EventDevice(
            platform: "ios",
            os: Self.osVersionString,
            app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            sdk_version: AppDNA.sdkVersion,
            bundle_version: bundleVer,
            // Emit a BCP-47 hyphenated tag (e.g. "en-US"), matching Android's
            // `Locale.getDefault().toLanguageTag()`. `Locale.current.identifier` returns the ICU form with
            // an UNDERSCORE region separator ("en_US"), so the same device split into two `device.locale`
            // rows by platform in BigQuery. `.bcp47` canonicalizes to hyphens (iOS 16+, our min target).
            locale: Locale.current.identifier(.bcp47),
            country: (Locale.current as NSLocale).countryCode ?? "",
            framework: AppDNA.framework,
            framework_version: AppDNA.frameworkVersion,
            timezone: Self.deviceTimeZoneId()
        )

        let props: [String: AnyCodable]? = properties?.mapValues { AnyCodable($0) }

        return SDKEvent(
            schema_version: 1,
            event_id: UUID().uuidString.lowercased(),
            event_name: event,
            ts_ms: Int64(Date().timeIntervalSince1970 * 1000),
            user: EventUser(anon_id: identity.anonId, user_id: identity.userId),
            device: device,
            context: EventContext(
                session_id: sessionId,
                screen: screen,
                push_id: pushId,
                experiment_exposures: experimentExposures,
                // Stamp the monotonic sequence at the single choke point every
                // event's envelope is built. ts_ms stays but is no longer the ordering key. A pre-init
                // event carries the seq it stamped at facade track() time (used verbatim, never re-minted).
                client_seq: clientSeq ?? ClientSeqCounter.next()
            ),
            properties: props,
            privacy: EventPrivacy(consent: Consent(analytics: analyticsConsent))
        )
    }
}
