import Foundation

// MARK: - Served targeting

/// The `targeting` object of a served experiment doc — the rules the Console lets an author set, as the server
/// normalises them: `countries` (upper-case ISO-3166 alpha-2), `min_app_version`, `new_users_only`, and
/// `user_traits` (`[{trait, operator, value}]`, every condition must match). `platforms` is informational; the
/// top-level `platforms` field of the doc stays authoritative.
///
/// Decoding is per field so one odd value cannot drop the whole experiment; a key that is present but cannot be
/// decoded marks the targeting `malformed`, and a malformed targeting is never eligible (fail closed — a rule the
/// author set is never silently skipped).
struct ExperimentTargeting: Codable {
    var countries: [String]? = nil
    var min_app_version: String? = nil
    var new_users_only: Bool? = nil
    var user_traits: [AudienceRule]? = nil
    var platforms: [String]? = nil
    var malformed: Bool = false

    enum CodingKeys: String, CodingKey {
        case countries, min_app_version, new_users_only, user_traits, platforms
    }

    init(
        countries: [String]? = nil,
        min_app_version: String? = nil,
        new_users_only: Bool? = nil,
        user_traits: [AudienceRule]? = nil,
        platforms: [String]? = nil
    ) {
        self.countries = countries
        self.min_app_version = min_app_version
        self.new_users_only = new_users_only
        self.user_traits = user_traits
        self.platforms = platforms
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            malformed = true
            return
        }
        var bad = false
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard c.contains(key), (try? c.decodeNil(forKey: key)) != true else { return nil }
            if let v = try? c.decode(type, forKey: key) { return v }
            bad = true
            return nil
        }
        countries = field([String].self, .countries)
        min_app_version = field(String.self, .min_app_version)
        new_users_only = field(Bool.self, .new_users_only)
        user_traits = field([AudienceRule].self, .user_traits)
        platforms = field([String].self, .platforms)
        // A trait condition the device cannot evaluate — no trait name (`trait` / `field`), or a `trait` /
        // `operator` that is not a string (that one already fails the decode above) — fails closed too. Android
        // `ExperimentTargeting.fromAny`, same rule.
        if let rules = user_traits, rules.contains(where: { ($0.trait ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            bad = true
        }
        malformed = bad
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(countries, forKey: .countries)
        try c.encodeIfPresent(min_app_version, forKey: .min_app_version)
        try c.encodeIfPresent(new_users_only, forKey: .new_users_only)
        try c.encodeIfPresent(user_traits, forKey: .user_traits)
        try c.encodeIfPresent(platforms, forKey: .platforms)
    }
}

// MARK: - Device context

/// What the device knows about itself when an experiment is evaluated. Production values come from
/// `ExperimentEligibilityContext.current(traits:)`; tests pass their own.
struct ExperimentEligibilityContext {
    /// "ios"
    let platform: String
    /// The host app's version (`CFBundleShortVersionString`).
    let appVersion: String?
    /// The device region (ISO-3166 alpha-2, upper case) — `DeviceRegion.current()`, not an IP lookup.
    let deviceRegion: String?
    /// When the app was first installed on this device (epoch ms) — `AppInstallDate`.
    let installEpochMs: Int64?
    /// The identity's traits: the ones the host passed to `AppDNA.identify(userId:traits:)`, plus the `country`,
    /// `region`, `city` and `timezone` the bootstrap answer carries (merged without overwriting the host's). There is
    /// no API that sets traits for an anonymous user, so until `identify` only the bootstrap traits are present.
    let traits: [String: Any]

    static func current(traits: [String: Any]) -> ExperimentEligibilityContext {
        ExperimentEligibilityContext(
            platform: "ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            deviceRegion: DeviceRegion.current(),
            installEpochMs: AppInstallDate.epochMs(),
            traits: traits
        )
    }
}

/// The device's country for the targeting "Countries" rule — one definition on both platforms (Android
/// `DeviceRegion`): the device's REGION SETTING, read from its locales. The first candidate that is an ISO-3166
/// alpha-2 code (exactly two ASCII letters, upper-cased; a UN M.49 area such as `419` is not a country), from the
/// current locale's region, then the region of each preferred language in order. None → nil (a country rule then
/// fails closed). No carrier / SIM country on either platform: `CTCarrier.isoCountryCode` is deprecated and answers a
/// placeholder since iOS 16, and Android no longer reads the SIM's or the network's country, so the same device
/// settings target the same way on both.
enum DeviceRegion {
    static func current() -> String? {
        current(locale: Locale.current, preferredLanguages: Locale.preferredLanguages)
    }

    /// The region from `locale`, then from each of `preferredLanguages` (BCP 47 identifiers) in order — the seam the
    /// shared fixtures drive.
    static func current(locale: Locale, preferredLanguages: [String]) -> String? {
        resolve([locale.region?.identifier] + preferredLanguages.map { Locale(identifier: $0).region?.identifier })
    }

    /// The first ISO-3166 alpha-2 code among `candidates`, upper-cased; nil when there is none.
    static func resolve(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespaces), raw.count == 2,
                  raw.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) else { continue }
            return raw.uppercased()
        }
        return nil
    }
}

/// When the app was first installed ON THIS DEVICE — the "new users only" date. The SDK's own install marker: a file
/// in the SDK's backup-excluded directory (`Application Support/ai.appdna.sdk/install_marker`), written by the first
/// `configure()` of an install. Nothing a backup restores is read, so what happens is:
///  - **app update** — the marker is kept: same date;
///  - **delete and reinstall** — the container (and the marker) is gone: a new date, the first launch after the install;
///  - **restore from a backup / device transfer** — the marker is excluded from backups, so it is not restored: a new
///    date, the first launch after the restore. (The app's restored files and preferences — the Documents directory's
///    creation date, the old `ai.appdna.sdk.install_date` preference — are not read: a restore may carry the original
///    device's dates.)
///  - **first launch of this SDK version on an install an older AppDNA SDK already ran on** (its backup-excluded SDK
///    directory exists before `configure()` touches it): a one-time migration takes the earlier of the Documents
///    directory's creation date and now, and writes it as the marker — that directory was made with the app container
///    at install, and the SDK directory proves the container is the one the app was installed into, not a restore.
///  - **an app that adds the AppDNA SDK in an update** (no SDK directory yet): the first launch with the SDK. This one
///    case differs from Android, whose `PackageInfo.firstInstallTime` predates the SDK; on iOS it cannot be told apart
///    from a restore without reading restorable data.
/// nil only when the marker can neither be read nor written ("new users only" then fails closed).
enum AppInstallDate {
    /// The old UserDefaults marker (backed up with the app's preferences). Not read here.
    static let legacyStoredKey = "ai.appdna.sdk.install_date"
    static let markerFileName = "install_marker"

    /// The install date (epoch ms), read once per process — `recordAtLaunch()` (called first in `configure()`) or the
    /// first evaluation, whichever comes first.
    static func epochMs() -> Int64? { cached.value }

    /// Writes the marker on the first launch of an install, before `configure()` creates the SDK directory (which is
    /// how the one-time migration tells an existing install from a fresh one).
    static func recordAtLaunch() { _ = cached.value }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var stored: Int64?
        var value: Int64? {
            lock.lock(); defer { lock.unlock() }
            if !done {
                let fm = FileManager.default
                let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
                stored = AppInstallDate.read(
                    documentsDirectory: fm.urls(for: .documentDirectory, in: .userDomainMask).first,
                    sdkDirectory: base.appendingPathComponent("ai.appdna.sdk", isDirectory: true),
                    now: Date())
                done = true
            }
            return stored
        }
    }
    private static let cached = Once()

    /// The install date from the marker in `sdkDirectory`; when there is none yet, the date this launch decides (see
    /// the type's comment), written there and excluded from backup.
    static func read(documentsDirectory: URL?, sdkDirectory: URL, now: Date) -> Int64? {
        let url = sdkDirectory.appendingPathComponent(markerFileName)
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite {
            return Int64((seconds * 1000).rounded())
        }
        // No marker. An older SDK ran on this install when its backup-excluded directory is already there (a restore
        // does not bring it back): take the container's date once. Otherwise this is the install's first launch.
        var date = now
        if FileManager.default.fileExists(atPath: sdkDirectory.path),
           let documents = documentsDirectory,
           let created = (try? FileManager.default.attributesOfItem(atPath: documents.path))?[.creationDate] as? Date {
            date = min(created, now)
        }
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        try? FileManager.default.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)
        guard (try? String(format: "%.3f", Double(ms) / 1000).write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        var dir = sdkDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        var target = url
        try? target.setResourceValues(values)
        return ms
    }
}

// MARK: - Evaluation

/// Decides whether this device / user is IN a running experiment, before any variant is assigned. Order on device:
/// status → platform → targeting → traffic allocation → variant bucket → exposure. Not in → no variant, no exposure.
/// Must produce the same answers as Android `ExperimentEligibility.kt` (shared fixtures: `experiment_serving/`).
enum ExperimentEligibility {

    enum Ineligible: String {
        case malformedTargeting = "malformed_targeting"
        case country
        case minAppVersion = "min_app_version"
        case newUsersOnly = "new_users_only"
        case userTraits = "user_traits"
    }

    /// The first targeting rule this context fails, or nil when every rule passes (or there is none).
    static func failedRule(
        targeting: ExperimentTargeting?,
        startedAtMs: Int64?,
        context: ExperimentEligibilityContext
    ) -> Ineligible? {
        guard let t = targeting else { return nil }
        if t.malformed { return .malformedTargeting }

        if let countries = t.countries?.map({ $0.trimmingCharacters(in: .whitespaces).uppercased() }).filter({ !$0.isEmpty }),
           !countries.isEmpty {
            guard let region = context.deviceRegion?.uppercased(), countries.contains(region) else { return .country }
        }

        if let minVersion = t.min_app_version?.trimmingCharacters(in: .whitespaces), !minVersion.isEmpty {
            guard let app = context.appVersion,
                  let cmp = compareVersions(app, minVersion),
                  cmp != .orderedAscending else { return .minAppVersion }
        }

        if t.new_users_only == true {
            guard let installed = context.installEpochMs, let started = startedAtMs, installed >= started else {
                return .newUsersOnly
            }
        }

        if let conditions = t.user_traits, !conditions.isEmpty {
            // The shared evaluator treats a numeric comparison with a missing / non-numeric side as "equal", so
            // `ltv >= 10` would pass for a user with no `ltv`. Here a comparison needs two numbers.
            for rule in conditions where numericOperators.contains(rule.operator ?? "") {
                guard let key = rule.trait,
                      ConditionEvaluator.toDouble(context.traits[key]) != nil,
                      ConditionEvaluator.toDouble(rule.value?.value) != nil else { return .userTraits }
            }
            guard AudienceRuleEvaluator.evaluate(ruleArray: conditions, userTraits: context.traits) else { return .userTraits }
        }
        return nil
    }

    private static let numericOperators: Set<String> = ["gt", "gte", "lt", "lte"]

    /// Dotted versions compared number by number (missing parts = 0; a part's non-numeric suffix is ignored, so
    /// "2.1.0-beta" = 2.1.0). nil when either side has no number at all.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult? {
        func parts(_ v: String) -> [Int]? {
            let comps = v.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
            var out: [Int] = []
            var sawDigit = false
            for comp in comps {
                let digits = comp.prefix { $0.isASCII && $0.isNumber }
                if !digits.isEmpty { sawDigit = true }
                out.append(Int(digits.prefix(9)) ?? 0)
            }
            return sawDigit ? out : nil
        }
        guard let pa = parts(a), let pb = parts(b) else { return nil }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    /// The allocation bucket: `murmur3_32("<experimentId>.<salt>.<userId>.allocation") % 10000`. A different input
    /// from the variant bucket (`"<experimentId>.<salt>.<userId>"`), so allocation and variant are independent.
    static func allocationBucket(experimentId: String, salt: String, userId: String) -> UInt32 {
        ExperimentBucketer.hash32("\(experimentId).\(salt).\(userId).allocation") % 10000
    }

    /// In the allocated share of traffic? `bucket < round(allocation × 10000)`, so a user in at 30 % is still in at
    /// 50 %. A doc without `traffic_allocation` (written before it was served) = everyone; a non-finite value = no one.
    static func isAllocated(experimentId: String, salt: String, userId: String, trafficAllocation: Double?) -> Bool {
        guard let allocation = trafficAllocation else { return true }
        guard allocation.isFinite else { return false }
        let threshold = UInt32(max(0, min(10000, (allocation * 10000).rounded())))
        if threshold >= 10000 { return true }
        return allocationBucket(experimentId: experimentId, salt: salt, userId: userId) < threshold
    }
}
