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
    /// The device region setting (ISO-3166 alpha-2), not an IP lookup.
    let deviceRegion: String?
    /// When the app was first installed on this device (epoch ms).
    let installEpochMs: Int64?
    /// The identity's traits (`setUserProperties` + bootstrap geo).
    let traits: [String: Any]

    static func current(traits: [String: Any]) -> ExperimentEligibilityContext {
        ExperimentEligibilityContext(
            platform: "ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            deviceRegion: Locale.current.region?.identifier,
            installEpochMs: AppInstallDate.epochMs(),
            traits: traits
        )
    }
}

/// The app's first install on this device: the earlier of the Documents directory's creation date (created with the
/// app container at install — so it predates this SDK version on upgraded installs) and the install date the SDK
/// stores on first use. A reinstall is a new install.
enum AppInstallDate {
    static let storedKey = "ai.appdna.sdk.install_date"

    /// Read once per process (a file-attribute read); the install date does not change while the app runs.
    static func epochMs() -> Int64? { cached }
    private static let cached: Int64? = read()

    private static func read() -> Int64? {
        var candidates: [Date] = []
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let created = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date {
            candidates.append(created)
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: storedKey) != nil {
            candidates.append(Date(timeIntervalSince1970: defaults.double(forKey: storedKey)))
        } else {
            defaults.set(Date().timeIntervalSince1970, forKey: storedKey)
        }
        guard let earliest = candidates.min() else { return nil }
        return Int64(earliest.timeIntervalSince1970 * 1000)
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
