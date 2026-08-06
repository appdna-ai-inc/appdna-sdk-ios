import Foundation
import FirebaseFirestore

/// Manages remote config, flags, experiments, paywalls, onboarding flows, and messages from Firestore.
/// Uses stale-while-revalidate: always returns cached value, refreshes in background.
final class RemoteConfigManager {
    private let queue = DispatchQueue(label: "ai.appdna.sdk.config")
    private let firestorePath: String?
    private let configCache: ConfigCache
    private let configTTL: TimeInterval
    private weak var eventTracker: EventTracker?

    /// Shared JSON decoder for all config parsing.
    private static let snakeCaseDecoder = JSONDecoder()

    /// Recursively sanitize Firestore dictionaries: coerce string "true"/"false"
    /// → Bool so JSONDecoder doesn't fail on type mismatches for Bool fields.
    ///
    /// Numeric-string coercion was REMOVED — the old implementation
    /// turned any numeric-looking String value into an Int/Double,
    /// which broke user-authored text fields that happened to be
    /// all-digit (e.g. a survey question text like "2222222" became
    /// Int 2222222 and then failed to decode as `String?`). Firestore
    /// already returns correctly-typed numbers for the fields that
    /// need them (delay_seconds, max_displays, scale, etc.), so we
    /// trust the source types and only fix the one known ambiguity
    /// (stringified booleans).
    private static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues { sanitize($0) }
        }
        if let arr = value as? [Any] {
            return arr.map { sanitize($0) }
        }
        if let str = value as? String {
            let lower = str.lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
        }
        return value
    }

    /// Encode a Firestore dictionary to JSON Data, sanitizing type mismatches first.
    private static func sanitizedJSONData(_ dict: [String: Any]) throws -> Data {
        let clean = sanitize(dict) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: clean)
    }

    // In-memory caches
    private var paywalls: [String: PaywallConfig] = [:]
    private var experiments: [String: ExperimentConfig] = [:]
    // SPEC-036-H — prefetched per-item experiment variant configs, keyed by the variant's `variant_doc`
    // path. Populated after the experiments doc parses so `resolveSurfacePresentation` (synchronous)
    // can read the treatment config without an async fetch at present-time.
    private var variantDocs: [String: [String: Any]] = [:]
    private var flags: [String: Any] = [:]
    private var flows: [String: Any] = [:]
    private var onboardingFlows: [String: OnboardingFlowConfig] = [:]
    private var activeOnboardingFlowId: String?
    private var messages: [String: MessageConfig] = [:]
    private var surveys: [String: SurveyConfig] = [:]

    /// Round-10 #13 — consecutive fully-failed (e.g. offline) config fetches, so the retry backs off and
    /// caps instead of recording a false success. Accessed on `queue`.
    private var configFetchFailures = 0
    private static let maxConfigFetchRetries = 5
    /// Round-11 regression fix — whether the current fetch REACHED the server (any config document
    /// returned with no error). A missing doc is a successful round-trip (error==nil), so this is true
    /// online regardless of WHAT is published — including screens-only / brand-only / empty projects
    /// (which the earlier content-based `gotAnything` heuristic wrongly treated as failures, since
    /// screens write to ScreenManager and brand writes async to AppDNA.brandAccentHex, neither in that
    /// check). Only a genuine network failure (offline, no cache) leaves it false. Accessed on `queue`.
    private var configFetchReachedServer = false

    /// Called by SurveyManager to get current survey configs.
    private var surveyUpdateHandler: (([String: SurveyConfig]) -> Void)?

    init(firestorePath: String?, configCache: ConfigCache, configTTL: TimeInterval) {
        self.firestorePath = firestorePath
        self.configCache = configCache
        self.configTTL = configTTL

        // Load from disk cache on init
        loadCachedConfigs()
    }

    /// Set the event tracker for auto-tracked config_fetched events.
    func setEventTracker(_ tracker: EventTracker) {
        self.eventTracker = tracker
    }

    // MARK: - Public read methods (synchronous, from in-memory cache)

    func getConfig(key: String) -> Any? {
        queue.sync { flags[key] }
    }

    func getPaywallConfig(id: String) -> PaywallConfig? {
        queue.sync { paywalls[id] }
    }

    func getExperimentConfig(id: String) -> ExperimentConfig? {
        queue.sync { experiments[id] }
    }

    #if DEBUG
    /// SPEC-419 D6 — the applied (fetched + parsed) onboarding flow version, for the
    /// structural parity harness's readiness poll ("poll until the device reports the
    /// just-published version, then screenshot"). Reached via the unguarded public
    /// `AppDNA.debugAppliedConfigVersion` (see its note) — present in ALL build configs
    /// because the Flutter plugin calls it unconditionally (issue #527). This method was
    /// never actually `#if DEBUG`-gated despite the earlier wording here.
    func debugAppliedOnboardingVersion(flowId: String?) -> Int? {
        queue.sync {
            let id = flowId ?? activeOnboardingFlowId
            guard let id else { return nil }
            return onboardingFlows[id]?.version
        }
    }
    #endif

    // MARK: - SPEC-036-F §1.2 — typed-config decode for experiment treatment payloads

    /// Decode an experiment treatment `payload` dict into a typed `PaywallConfig`
    /// using the SAME `sanitizedJSONData` + decoder pipeline `parsePaywalls`
    /// uses, so a treatment renders byte-for-byte like a normal active config.
    /// Returns nil on decode failure → caller falls back to the active entity.
    func decodePaywallPayload(_ payload: [String: Any]) -> PaywallConfig? {
        Self.decodeTypedConfig(payload)
    }

    func decodeOnboardingPayload(_ payload: [String: Any]) -> OnboardingFlowConfig? {
        Self.decodeTypedConfig(payload)
    }

    func decodeMessagePayload(_ payload: [String: Any]) -> MessageConfig? {
        Self.decodeTypedConfig(payload)
    }

    func decodeSurveyPayload(_ payload: [String: Any]) -> SurveyConfig? {
        Self.decodeTypedConfig(payload)
    }

    /// Shared typed-config decode helper — runs the Firestore dict through the
    /// same sanitize + JSONDecoder path the live-config parsers use.
    private static func decodeTypedConfig<T: Decodable>(_ payload: [String: Any]) -> T? {
        do {
            let jsonData = try sanitizedJSONData(payload)
            return try snakeCaseDecoder.decode(T.self, from: jsonData)
        } catch {
            Log.error("Failed to decode experiment treatment payload as \(T.self): \(error)")
            return nil
        }
    }

    func getAllExperiments() -> [String: ExperimentConfig] {
        queue.sync { experiments }
    }

    /// SPEC-036-H — the prefetched `config` of a per-item experiment variant doc, by its `variant_doc`
    /// pointer path. `nil` if not yet fetched / fetch failed → caller renders the active item (never
    /// cross-cohort, never broken).
    func getVariantDoc(path: String) -> [String: Any]? {
        queue.sync { variantDocs[path] }
    }

    // MARK: - Test seams (internal; reachable only via @testable import)

    /// Inject a parsed experiments map directly, bypassing the Firestore fetch. Test-only.
    func _injectExperimentsForTesting(_ map: [String: ExperimentConfig]) {
        queue.sync { self.experiments = map }
    }

    /// Inject a prefetched per-item variant doc `config` by its pointer path. Test-only.
    func _injectVariantDocForTesting(path: String, config: [String: Any]) {
        queue.sync { self.variantDocs[path] = config }
    }

    /// Test-only — run the real per-item flag parser then block until applied (SPEC-036-H).
    func _parseFlagDocForTesting(key: String, data: [String: Any]) {
        parseSingleFlag(key: key, data: data); queue.sync {}
    }

    /// Test-only — run the real per-item message parser then block until applied.
    func _parseMessageDocForTesting(id: String, data: [String: Any]) {
        parseSingleMessage(id: id, data: data); queue.sync {}
    }

    /// Test-only — prune flags/messages to the given index keyset (as fetchViaIndex does).
    func _pruneFlagsForTesting(_ keys: Set<String>) {
        queue.sync { self.flags = self.flags.filter { keys.contains($0.key) } }
    }
    func _pruneMessagesForTesting(_ keys: Set<String>) {
        queue.sync { self.messages = self.messages.filter { keys.contains($0.key) } }
    }
    func _getMessagesForTesting() -> [String: MessageConfig] { queue.sync { messages } }

    func getAllFlags() -> [String: Any] {
        queue.sync { flags }
    }

    func getAllConfig() -> [String: Any] {
        getAllFlags()
    }

    // MARK: - Bundled config (offline-first)

    /// Load config from the bundled appdna-config.json embedded in the app binary.
    /// Only populates empty caches — remote and cached data take priority.
    func loadBundledConfig(_ json: [String: Any]) {
        queue.sync {
            // Paywalls
            if self.paywalls.isEmpty, let data = json["paywalls"] as? [String: Any], !data.isEmpty {
                self.parsePaywalls(data)
                Log.debug("Loaded paywalls from bundled config")
            }
            // Onboarding
            if self.onboardingFlows.isEmpty, let data = json["onboarding"] as? [String: Any], !data.isEmpty {
                self.parseOnboarding(data)
                Log.debug("Loaded onboarding from bundled config")
            }
            // Experiments
            if self.experiments.isEmpty, let data = json["experiments"] as? [String: Any], !data.isEmpty {
                self.parseExperiments(data)
                Log.debug("Loaded experiments from bundled config")
            }
            // Messages
            if self.messages.isEmpty, let data = json["messages"] as? [String: Any], !data.isEmpty {
                self.parseMessages(data)
                Log.debug("Loaded messages from bundled config")
            }
            // Surveys
            if self.surveys.isEmpty, let data = json["surveys"] as? [String: Any], !data.isEmpty {
                self.parseSurveys(data)
                Log.debug("Loaded surveys from bundled config")
            }
            // Flags / remote config
            if self.flags.isEmpty {
                if let data = json["remote_config"] as? [String: Any], !data.isEmpty {
                    self.flags = data
                    Log.debug("Loaded remote_config from bundled config")
                } else if let data = json["feature_flags"] as? [String: Any], !data.isEmpty {
                    self.flags = data
                    Log.debug("Loaded feature_flags from bundled config")
                }
            }
            // Screen index
            if let data = json["screen_index"] as? [String: Any], !data.isEmpty {
                self.parseScreenIndex(data)
                Log.debug("Loaded screen_index from bundled config")
            }
            // SPEC-419 brand-threading
            if let data = json["brand"] as? [String: Any], !data.isEmpty {
                self.parseBrand(data)
            }
        }
    }

    /// SPEC-419 brand-threading — capture the app's brand accent so SDK render
    /// defaults can use it instead of the hardcoded #6366F1. Doc/bundle shape:
    /// `{ palette: { accent, primary, ... } }`.
    private func parseBrand(_ data: [String: Any]) {
        guard let palette = data["palette"] as? [String: Any] else { return }
        if let accent = palette["accent"] as? String, !accent.isEmpty {
            // Write on main — brandAccentHex is read on the main thread from every SwiftUI body; parseBrand
            // runs on a background Firestore/group.notify queue, so an unsynchronized write was a data race.
            DispatchQueue.main.async { AppDNA.brandAccentHex = accent }
            Log.debug("Loaded brand accent \(accent)")
        }
    }

    // MARK: - Onboarding (v0.2)

    /// Get all onboarding flows (for audience-based selection).
    func getAllOnboardingFlows() -> [String: OnboardingFlowConfig] {
        queue.sync { onboardingFlows }
    }

    /// Get all paywall configs (for audience-based selection).
    func getAllPaywalls() -> [String: PaywallConfig] {
        queue.sync { paywalls }
    }

    /// Get an onboarding flow by ID, or the active flow if id is nil.
    func getOnboardingFlow(id: String?) -> OnboardingFlowConfig? {
        queue.sync {
            if let id {
                return onboardingFlows[id]
            }
            guard let activeId = activeOnboardingFlowId else { return nil }
            return onboardingFlows[activeId]
        }
    }

    // MARK: - Messages (v0.2)

    /// Get all active message configs.
    func getActiveMessages() -> [String: MessageConfig] {
        queue.sync { messages }
    }

    // MARK: - Surveys (v0.3)

    /// Get all survey configs.
    func getSurveyConfigs() -> [String: SurveyConfig] {
        queue.sync { surveys }
    }

    /// Register a handler that fires when survey configs are updated.
    func onSurveyConfigsUpdated(_ handler: @escaping ([String: SurveyConfig]) -> Void) {
        self.surveyUpdateHandler = handler
    }

    // MARK: - SPEC-067: Force Refresh

    /// Force an immediate config refresh, bypassing the cache TTL.
    /// Use this when you need configs to update immediately (e.g., after a user action).
    func forceRefresh() {
        Log.info("Force refreshing remote config (bypassing TTL)")
        fetchConfigs()
    }

    // MARK: - Fetch from Firestore

    func fetchConfigs() {
        guard let firestorePath else {
            Log.warning("No Firestore path available — serving cached config only")
            return
        }

        guard let db = AppDNA.firestoreDB else {
            Log.warning("Firestore not initialized — serving cached config only")
            return
        }
        let basePath = "\(firestorePath)/config"

        // Fetch all config documents in parallel.
        // For paywalls, onboarding, and surveys: prefer per-item docs (via index)
        // to avoid the 1MB mega-doc limit. Fall back to legacy mega-doc if no index.
        let group = DispatchGroup()
        // Round-11 regression fix — reset the per-fetch server-reachability flag; the always-present
        // getDocument closures below set it true the moment any of them returns without a network error.
        self.queue.sync { self.configFetchReachedServer = false }

        // Paywalls: index → per-item docs (subcollection), fallback → mega-doc
        group.enter()
        self.fetchViaIndex(
            db: db, basePath: basePath,
            indexPath: "paywall_index", indexKey: "paywalls",
            itemCollection: "paywall_index/paywalls",
            megaDocPath: "paywalls",
            parseItem: { [weak self] id, data in self?.parseSinglePaywall(id: id, data: data) },
            parseMegaDoc: { [weak self] data in self?.parsePaywalls(data) },
            onComplete: { group.leave() }
        )

        // Onboarding: index → per-item docs (subcollection), fallback → mega-doc
        group.enter()
        self.fetchViaIndex(
            db: db, basePath: basePath,
            indexPath: "onboarding_index", indexKey: "flows",
            itemCollection: "onboarding_index/flows",
            megaDocPath: "onboarding",
            parseItem: { [weak self] id, data in self?.parseSingleOnboardingFlow(id: id, data: data) },
            parseMegaDoc: { [weak self] data in self?.parseOnboarding(data) },
            extraIndexParse: { [weak self] indexData in
                // Extract active_flow_id from the index
                if let activeId = indexData["active_flow_id"] as? String {
                    self?.queue.async { self?.activeOnboardingFlowId = activeId }
                }
            },
            onComplete: { group.leave() }
        )

        // Surveys: index → per-item docs (subcollection), fallback → mega-doc
        group.enter()
        self.fetchViaIndex(
            db: db, basePath: basePath,
            indexPath: "survey_index", indexKey: "surveys",
            itemCollection: "survey_index/surveys",
            megaDocPath: "surveys",
            parseItem: { [weak self] id, data in self?.parseSingleSurvey(id: id, data: data) },
            parseMegaDoc: { [weak self] data in self?.parseSurveys(data) },
            onComplete: { group.leave() }
        )

        // Experiments — lightweight, keep mega-doc pattern. SPEC-036-H: after parsing, prefetch any
        // per-item variant docs the experiments reference via `variant_doc` so synchronous
        // presentation resolution can read the treatment config without an async fetch at present-time.
        group.enter()
        db.document("\(basePath)/experiments").getDocument { [weak self] snapshot, error in
            defer { group.leave() }
            guard let self else { return }
            if error == nil { self.queue.sync { self.configFetchReachedServer = true } }
            if let data = snapshot?.data() {
                self.parseExperiments(data)
                self.prefetchVariantDocs(db: db, group: group)
            } else if let error {
                Log.error("Failed to fetch experiments config: \(error.localizedDescription)")
            }
        }

        // Flags — SPEC-036-H: index → per-item docs (config/flag_index/flags/{key}), fallback → mega-doc.
        group.enter()
        self.fetchViaIndex(
            db: db, basePath: basePath,
            indexPath: "flag_index", indexKey: "flags",
            itemCollection: "flag_index/flags",
            megaDocPath: "flags",
            parseItem: { [weak self] key, data in self?.parseSingleFlag(key: key, data: data) },
            parseMegaDoc: { [weak self] data in self?.parseFlags(data) },
            pruneToKeys: { [weak self] keys in self?.queue.async { self?.flags = self?.flags.filter { keys.contains($0.key) } ?? [:] } },
            onComplete: { group.leave() }
        )

        // Flows (legacy zero-code) — lightweight, keep mega-doc
        group.enter()
        db.document("\(basePath)/flows").getDocument { [weak self] snapshot, error in
            defer { group.leave() }
            if error == nil { self?.queue.sync { self?.configFetchReachedServer = true } }
            if let data = snapshot?.data() {
                self?.queue.async { self?.flows = data }
                if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
                    self?.configCache.storeFlows(jsonData)
                }
            } else if let error {
                Log.error("Failed to fetch flows config: \(error.localizedDescription)")
            }
        }

        // In-app messages — SPEC-036-H: index → per-item docs (config/message_index/messages/{id}),
        // fallback → mega-doc.
        group.enter()
        self.fetchViaIndex(
            db: db, basePath: basePath,
            indexPath: "message_index", indexKey: "messages",
            itemCollection: "message_index/messages",
            megaDocPath: "messages",
            parseItem: { [weak self] id, data in self?.parseSingleMessage(id: id, data: data) },
            parseMegaDoc: { [weak self] data in self?.parseMessages(data) },
            pruneToKeys: { [weak self] keys in self?.queue.async { self?.messages = self?.messages.filter { keys.contains($0.key) } ?? [:] } },
            onComplete: { group.leave() }
        )

        // SPEC-089c: Screen index for server-driven UI
        group.enter()
        db.document("\(basePath)/screen_index").getDocument { [weak self] snapshot, error in
            defer { group.leave() }
            if error == nil { self?.queue.sync { self?.configFetchReachedServer = true } }
            if let data = snapshot?.data() {
                self?.parseScreenIndex(data)
            } else if let error {
                Log.debug("No screen_index config: \(error.localizedDescription)")
            }
        }

        // SPEC-419 brand-threading: the app's brand palette. brand.palette.accent
        // becomes the SDK-wide default for accent/link/badge/selected-border colors
        // (replacing the hardcoded #6366F1) — per-element overrides still win.
        group.enter()
        db.document("\(basePath)/brand").getDocument { [weak self] snapshot, error in
            defer { group.leave() }
            if error == nil { self?.queue.sync { self?.configFetchReachedServer = true } }
            if let data = snapshot?.data() {
                self?.parseBrand(data)
            } else if let error {
                Log.debug("No brand config: \(error.localizedDescription)")
            }
        }

        group.notify(queue: .global()) {
            // Round-10 #13 — a fully-failed fetch (offline at launch: every getDocument errors, but each
            // `defer { group.leave() }` still fires) used to unconditionally markFetched + emit
            // config_fetched. That set `fetchedAt=now` so `isStale` was false, and the ONLY reschedule
            // below is gated on `isStale` — so the SDK was stranded on cache with no periodic refresh and
            // no connectivity hook (Android recovers via ConfigRefreshWorker). Detect a fetch that never
            // REACHED the server and retry with bounded backoff instead of recording a false success.
            // Round-11 regression fix — this uses server-reachability (any getDocument returned without a
            // network error), NOT "did we parse any config": a missing doc is a successful round-trip, so
            // screens-only / brand-only / empty projects (which parse into ScreenManager / async
            // brandAccentHex / nothing, none visible to a content check) are correctly treated as success.
            let reachedServer = self.queue.sync { self.configFetchReachedServer }
            if !reachedServer {
                let attempt = self.queue.sync { () -> Int in
                    self.configFetchFailures += 1
                    return self.configFetchFailures
                }
                if attempt <= Self.maxConfigFetchRetries {
                    let backoff = min(pow(2.0, Double(attempt)), 30.0) // 2,4,8,16,30s
                    Log.warning("Remote config fetch returned nothing (offline?) — retry \(attempt)/\(Self.maxConfigFetchRetries) in \(Int(backoff))s")
                    DispatchQueue.global().asyncAfter(deadline: .now() + backoff) { [weak self] in
                        self?.fetchConfigs()
                    }
                } else {
                    Log.warning("Remote config fetch still empty after \(Self.maxConfigFetchRetries) retries — serving cache")
                }
                return
            }

            // Success — reset the failure streak.
            self.queue.sync { self.configFetchFailures = 0 }

            // Re-cache all in-memory configs to disk. This ensures the disk
            // cache stays fresh whether configs came from per-item docs (index)
            // or from the legacy mega-doc. Without this, per-item fetches would
            // leave the disk cache stale and offline restarts would fail.
            self.cacheAllFetchedConfigs()

            self.configCache.markFetched()
            Log.info("Remote config fetched successfully")
            self.eventTracker?.track(event: "config_fetched", properties: nil)
            NotificationCenter.default.post(name: AppDNA.configUpdated, object: nil)

            // Schedule TTL refresh
            DispatchQueue.global().asyncAfter(deadline: .now() + self.configTTL) { [weak self] in
                if self?.configCache.isStale == true {
                    self?.fetchConfigs()
                }
            }
        }
    }

    // MARK: - Private

    private func loadCachedConfigs() {
        if let data = configCache.loadPaywalls() {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsePaywalls(dict)
            }
        }
        if let data = configCache.loadExperiments() {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parseExperiments(dict)
            }
        }
        if let data = configCache.loadFlags() {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                queue.async { self.flags = dict }
            }
        }
        if let data = configCache.loadFlows() {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                queue.async { self.flows = dict }
            }
        }
        if let data = configCache.loadOnboarding() {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parseOnboarding(dict)
            }
        }
        if let data = configCache.loadMessages() {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parseMessages(dict)
            }
        }
        if let data = configCache.loadSurveys() {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parseSurveys(dict)
            }
        }
        Log.debug("Loaded cached configs from disk")
    }

    private func parsePaywalls(_ data: [String: Any]) {
        // Firestore doc structure: { "paywalls": { "uuid1": {...}, "uuid2": {...} } }
        // Unwrap the "paywalls" wrapper if present, otherwise treat data as flat map
        let paywallMap = (data["paywalls"] as? [String: Any]) ?? data
        var parsed: [String: PaywallConfig] = [:]
        for (key, value) in paywallMap {
            guard let dict = value as? [String: Any] else { continue }
            do {
                let jsonData = try Self.sanitizedJSONData(dict)
                let config = try Self.snakeCaseDecoder.decode(PaywallConfig.self, from: jsonData)
                parsed[key] = config
            } catch let decodingError as DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let ctx):
                    Log.error("Paywall '\(key)' decode: missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                case .typeMismatch(let type, let ctx):
                    Log.error("Paywall '\(key)' decode: type mismatch for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
                case .valueNotFound(let type, let ctx):
                    Log.error("Paywall '\(key)' decode: null value for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                case .dataCorrupted(let ctx):
                    Log.error("Paywall '\(key)' decode: corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
                @unknown default:
                    Log.error("Paywall '\(key)' decode: \(decodingError)")
                }
            } catch {
                Log.error("Failed to decode paywall '\(key)': \(error)")
            }
        }
        queue.async { self.paywalls = parsed }

        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
            configCache.storePaywalls(jsonData)
        }
    }

    private func parseExperiments(_ data: [String: Any]) {
        // Firestore doc structure: { "experiments": { "uuid1": {...}, "uuid2": {...} } }
        let experimentsMap = (data["experiments"] as? [String: Any]) ?? data
        var parsed: [String: ExperimentConfig] = [:]
        for (key, value) in experimentsMap {
            guard let dict = value as? [String: Any] else { continue }
            do {
                let jsonData = try Self.sanitizedJSONData(dict)
                let config = try Self.snakeCaseDecoder.decode(ExperimentConfig.self, from: jsonData)
                parsed[key] = config
            } catch {
                Log.error("Failed to decode experiment '\(key)': \(error.localizedDescription)")
            }
        }
        queue.async { self.experiments = parsed }

        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
            configCache.storeExperiments(jsonData)
        }
    }

    /// SPEC-036-H — fetch each `variant_doc`-referenced per-item variant doc by its EXACT path (never
    /// via an index — that is the cohort-isolation guarantee) and cache its `config`. Enters `group`
    /// once per doc so `fetchConfigs` waits for them before notifying. Runs only for `per_item` mode
    /// docs; `inline`-mode experiments carry no `variant_doc` and skip this entirely.
    private func prefetchVariantDocs(db: Firestore, group: DispatchGroup) {
        let paths: [String] = queue.sync {
            experiments.values
                .flatMap { ($0.variants ?? []) }
                .compactMap { $0.variant_doc }
        }
        // Prune cached variant docs no longer referenced by any current experiment (a re-materialized
        // or ended experiment changes/drops its pointer), so the cache can't grow unbounded across TTL
        // refetches. Unchanged paths are retained (no serving gap); new/changed paths are fetched below.
        let pathSet = Set(paths)
        queue.async { self.variantDocs = self.variantDocs.filter { pathSet.contains($0.key) } }
        // De-dupe; a path appears once per treatment variant.
        for path in pathSet {
            group.enter()
            db.document(path).getDocument { [weak self] snapshot, error in
                defer { group.leave() }
                guard let self else { return }
                if let config = snapshot?.data()?["config"] as? [String: Any] {
                    self.queue.async { self.variantDocs[path] = config }
                } else if let error {
                    Log.error("Failed to fetch variant doc '\(path)': \(error.localizedDescription)")
                }
            }
        }
    }

    private func parseOnboarding(_ data: [String: Any]) {
        // Parse active_flow_id
        let activeId = data["active_flow_id"] as? String

        // Parse flows map
        var parsed: [String: OnboardingFlowConfig] = [:]
        if let flowsDict = data["flows"] as? [String: Any] {
            for (key, value) in flowsDict {
                guard let dict = value as? [String: Any] else { continue }
                do {
                    let jsonData = try Self.sanitizedJSONData(dict)
                    let config = try Self.snakeCaseDecoder.decode(OnboardingFlowConfig.self, from: jsonData)
                    parsed[key] = config
                } catch let decodingError as DecodingError {
                    switch decodingError {
                    case .keyNotFound(let codingKey, let ctx):
                        Log.error("Onboarding '\(key)' decode: missing key '\(codingKey.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                    case .typeMismatch(let type, let ctx):
                        Log.error("Onboarding '\(key)' decode: type mismatch for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
                    case .valueNotFound(let type, let ctx):
                        Log.error("Onboarding '\(key)' decode: null value for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                    case .dataCorrupted(let ctx):
                        Log.error("Onboarding '\(key)' decode: corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
                    @unknown default:
                        Log.error("Onboarding '\(key)' decode: \(decodingError)")
                    }
                } catch {
                    Log.error("Failed to decode onboarding flow '\(key)': \(error)")
                }
            }
        }

        queue.async {
            self.onboardingFlows = parsed
            self.activeOnboardingFlowId = activeId
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
            configCache.storeOnboarding(jsonData)
        }
    }

    private func parseMessages(_ data: [String: Any]) {
        // Parse messages map (may be nested under "messages" key)
        let messagesDict = data["messages"] as? [String: Any] ?? data
        var parsed: [String: MessageConfig] = [:]
        for (key, value) in messagesDict {
            guard key != "version" else { continue }
            guard let dict = value as? [String: Any],
                  let jsonData = try? Self.sanitizedJSONData(dict),
                  let config = try? Self.snakeCaseDecoder.decode(MessageConfig.self, from: jsonData) else {
                continue
            }
            parsed[key] = config
        }

        queue.async { self.messages = parsed }

        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
            configCache.storeMessages(jsonData)
        }
    }

    private func parseSurveys(_ data: [String: Any]) {
        let surveysDict = data["surveys"] as? [String: Any] ?? data
        var parsed: [String: SurveyConfig] = [:]
        for (key, value) in surveysDict {
            guard key != "version" else { continue }
            guard let dict = value as? [String: Any],
                  let jsonData = try? Self.sanitizedJSONData(dict),
                  let config = try? Self.snakeCaseDecoder.decode(SurveyConfig.self, from: jsonData) else {
                continue
            }
            parsed[key] = config
        }

        queue.async {
            self.surveys = parsed
            self.surveyUpdateHandler?(parsed)
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
            configCache.storeSurveys(jsonData)
        }
    }

    // MARK: - SPEC-089c: Screen Index

    private func parseScreenIndex(_ data: [String: Any]) {
        do {
            let jsonData = try Self.sanitizedJSONData(data)
            let index = try Self.snakeCaseDecoder.decode(ScreenIndex.self, from: jsonData)
            ScreenManager.shared.updateIndex(index)
            Log.info("Screen index loaded: \(index.screens?.count ?? 0) screens, \(index.flows?.count ?? 0) flows, \(index.slots?.count ?? 0) slots")
        } catch {
            Log.error("Failed to parse screen_index: \(error)")
        }
    }

    // MARK: - Disk cache sync

    /// Re-serialize in-memory configs to disk cache in mega-doc format.
    /// Called after all Firestore fetches complete so the disk cache is always
    /// fresh, regardless of whether configs came from per-item docs or mega-doc.
    private func cacheAllFetchedConfigs() {
        queue.async {
            let encoder = JSONEncoder()

            // Paywalls → { "paywalls": { id: config, ... } }
            if !self.paywalls.isEmpty {
                var dict: [String: Any] = [:]
                for (id, config) in self.paywalls {
                    if let data = try? encoder.encode(config),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        dict[id] = obj
                    }
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: ["paywalls": dict]) {
                    self.configCache.storePaywalls(jsonData)
                }
            }

            // Onboarding → { "active_flow_id": ..., "flows": { id: config, ... } }
            if !self.onboardingFlows.isEmpty {
                var dict: [String: Any] = [:]
                for (id, config) in self.onboardingFlows {
                    if let data = try? encoder.encode(config),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        dict[id] = obj
                    }
                }
                var payload: [String: Any] = ["flows": dict]
                if let activeId = self.activeOnboardingFlowId { payload["active_flow_id"] = activeId }
                if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
                    self.configCache.storeOnboarding(jsonData)
                }
            }

            // Surveys → { "surveys": { id: config, ... } }
            if !self.surveys.isEmpty {
                var dict: [String: Any] = [:]
                for (id, config) in self.surveys {
                    if let data = try? encoder.encode(config),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        dict[id] = obj
                    }
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: ["surveys": dict]) {
                    self.configCache.storeSurveys(jsonData)
                }
            }

            // SPEC-036-H — flags + messages now arrive via per-item index, so re-cache them here too
            // (the old mega-doc handlers cached inline; the per-item parsers don't). Flags stored as the
            // bare map (loadCachedConfigs does `self.flags = dict`); messages wrapped under "messages"
            // (loadCachedConfigs → parseMessages, which unwraps it). Written UNCONDITIONALLY (no !isEmpty
            // guard): when the last flag/message is removed, the per-item index prunes self.flags/messages
            // to empty and we MUST clear the disk cache too (else a cold start resurrects them). A failed
            // fetch leaves the PRIOR in-memory values intact (the parsers only run on success), so writing
            // unconditionally never clobbers a good cache with a transient-empty one.
            do {
                if let jsonData = try? JSONSerialization.data(withJSONObject: self.flags) {
                    self.configCache.storeFlags(jsonData)
                }
            }
            do {
                var dict: [String: Any] = [:]
                for (id, config) in self.messages {
                    if let data = try? encoder.encode(config),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        dict[id] = obj
                    }
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: ["messages": dict]) {
                    self.configCache.storeMessages(jsonData)
                }
            }
        }
    }

    // MARK: - Per-item fetch via index (enterprise-grade)

    /// Generic helper: try to load items via a lightweight index document.
    /// If the index exists, fan out to individual per-item documents.
    /// If no index, fall back to the legacy mega-document.
    ///
    /// This avoids the 1MB Firestore limit for config types with many items
    /// (paywalls, onboarding flows, surveys) while staying backward-compatible
    /// with older backends that only write the mega-doc.
    private func fetchViaIndex(
        db: Firestore,
        basePath: String,
        indexPath: String,
        indexKey: String,
        itemCollection: String,
        megaDocPath: String,
        parseItem: @escaping (String, [String: Any]) -> Void,
        parseMegaDoc: @escaping ([String: Any]) -> Void,
        extraIndexParse: (([String: Any]) -> Void)? = nil,
        // SPEC-036-H — when provided, the index is AUTHORITATIVE: in-memory entries whose key is not in
        // the current index are pruned (so a removed item stops serving), and an EMPTY index takes the
        // index branch (prune-to-empty) instead of falling back to the mega-doc. Surfaces that previously
        // full-replaced via the mega-doc (flags, messages) pass this so per-item serving keeps the same
        // removal semantics. Surfaces without it keep the legacy additive behavior.
        pruneToKeys: ((Set<String>) -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        db.document("\(basePath)/\(indexPath)").getDocument { [weak self] snapshot, error in
            guard let self else { onComplete(); return }

            if let indexData = snapshot?.data(),
               let itemsMap = indexData[indexKey] as? [String: Any],
               (!itemsMap.isEmpty || pruneToKeys != nil) {
                // Index exists — fetch individual docs in parallel. Prune stale in-memory entries first.
                Log.debug("[\(indexPath)] Found index with \(itemsMap.count) items, fetching individually")
                extraIndexParse?(indexData)
                pruneToKeys?(Set(itemsMap.keys))

                let itemGroup = DispatchGroup()
                for itemId in itemsMap.keys {
                    itemGroup.enter()
                    db.document("\(basePath)/\(itemCollection)/\(itemId)").getDocument { itemSnapshot, itemError in
                        defer { itemGroup.leave() }
                        if let itemData = itemSnapshot?.data() {
                            parseItem(itemId, itemData)
                        } else if let itemError {
                            Log.warning("[\(indexPath)] Failed to fetch item \(itemId): \(itemError.localizedDescription)")
                        }
                    }
                }
                itemGroup.notify(queue: .global()) {
                    onComplete()
                }
            } else {
                // No index — fall back to legacy mega-doc
                Log.debug("[\(indexPath)] No index found, falling back to mega-doc \(megaDocPath)")
                db.document("\(basePath)/\(megaDocPath)").getDocument { megaSnapshot, megaError in
                    defer { onComplete() }
                    if let data = megaSnapshot?.data() {
                        parseMegaDoc(data)
                    } else if let megaError {
                        Log.error("Failed to fetch \(megaDocPath) config: \(megaError.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Per-item parsers (for index-based fetching)

    private func parseSinglePaywall(id: String, data: [String: Any]) {
        do {
            let jsonData = try Self.sanitizedJSONData(data)
            let config = try Self.snakeCaseDecoder.decode(PaywallConfig.self, from: jsonData)
            queue.async { self.paywalls[id] = config }
        } catch {
            Log.error("Failed to decode individual paywall '\(id)': \(error)")
        }
    }

    private func parseSingleOnboardingFlow(id: String, data: [String: Any]) {
        do {
            let jsonData = try Self.sanitizedJSONData(data)
            let config = try Self.snakeCaseDecoder.decode(OnboardingFlowConfig.self, from: jsonData)
            queue.async { self.onboardingFlows[id] = config }
        } catch {
            Log.error("Failed to decode individual onboarding flow '\(id)': \(error)")
        }
    }

    /// Unwrap a served flag entry to its RAW value. The server serves each flag as
    /// `{value, type, description, updated_at}`; `FeatureFlagManager`/`getConfig` expect the raw value
    /// (Bool/Number/String/json), so store `flags[key] = entry.value`. Defensive: if an entry is already
    /// a raw scalar (legacy / future flat shape), keep it as-is.
    /// Returns nil for a wrapper whose `value` is null/NSNull (unset flag — omitted, matching Android),
    /// the raw value for a normal wrapper, or the entry itself if it isn't a `{value,...}` wrapper.
    private static func flagRawValue(_ entry: Any) -> Any? {
        guard let dict = entry as? [String: Any], let v = dict["value"] else { return entry }
        return (v is NSNull) ? nil : v
    }

    /// SPEC-036-H — mega-doc flags fallback (`{flags:{key:{value,...}}}`), normalized to raw values
    /// (null-valued flags omitted).
    private func parseFlags(_ data: [String: Any]) {
        let unwrapped = (data["flags"] as? [String: Any]) ?? data
        var normalized: [String: Any] = [:]
        for (k, v) in unwrapped { if let raw = Self.flagRawValue(v) { normalized[k] = raw } }
        queue.async { self.flags = normalized }
    }

    /// SPEC-036-H — per-item flag doc `config/flag_index/flags/{key}` = `{key,value,type,description,updated_at}`.
    /// Stored as the RAW value under `flags[key]` (what FeatureFlagManager.isEnabled/getValue consume);
    /// a null value unsets the key.
    private func parseSingleFlag(key: String, data: [String: Any]) {
        let value = Self.flagRawValue(data)
        queue.async { self.flags[key] = value }  // nil ⇒ removes the key (Swift dict semantics)
    }

    /// SPEC-036-H — per-item message doc `config/message_index/messages/{id}` (same shape the mega-doc
    /// packed per id). Incremental (matches paywall/onboarding/survey per-item parsers).
    private func parseSingleMessage(id: String, data: [String: Any]) {
        do {
            let jsonData = try Self.sanitizedJSONData(data)
            let config = try Self.snakeCaseDecoder.decode(MessageConfig.self, from: jsonData)
            queue.async { self.messages[id] = config }
        } catch {
            Log.error("Failed to decode individual message '\(id)': \(error)")
        }
    }

    private func parseSingleSurvey(id: String, data: [String: Any]) {
        do {
            let jsonData = try Self.sanitizedJSONData(data)
            let config = try Self.snakeCaseDecoder.decode(SurveyConfig.self, from: jsonData)
            queue.async {
                self.surveys[id] = config
                self.surveyUpdateHandler?(self.surveys)
            }
        } catch {
            Log.error("Failed to decode individual survey '\(id)': \(error)")
        }
    }

    /// Fetch a single paywall config on-demand by ID (for lazy loading).
    func fetchPaywallConfig(id: String, completion: @escaping (PaywallConfig?) -> Void) {
        guard let firestorePath else { completion(nil); return }
        guard let db = AppDNA.firestoreDB else { completion(nil); return }
        let basePath = "\(firestorePath)/config"
        db.document("\(basePath)/paywall_index/paywalls/\(id)").getDocument { [weak self] snapshot, error in
            guard let data = snapshot?.data() else {
                completion(nil)
                return
            }
            do {
                let jsonData = try Self.sanitizedJSONData(data)
                let config = try Self.snakeCaseDecoder.decode(PaywallConfig.self, from: jsonData)
                self?.queue.async { self?.paywalls[id] = config }
                completion(config)
            } catch {
                Log.error("Failed to decode paywall '\(id)': \(error)")
                completion(nil)
            }
        }
    }

    /// Fetch a single onboarding flow on-demand by ID (for lazy loading).
    func fetchOnboardingConfig(id: String, completion: @escaping (OnboardingFlowConfig?) -> Void) {
        guard let firestorePath else { completion(nil); return }
        guard let db = AppDNA.firestoreDB else { completion(nil); return }
        let basePath = "\(firestorePath)/config"
        db.document("\(basePath)/onboarding_index/flows/\(id)").getDocument { [weak self] snapshot, error in
            guard let data = snapshot?.data() else {
                completion(nil)
                return
            }
            do {
                let jsonData = try Self.sanitizedJSONData(data)
                let config = try Self.snakeCaseDecoder.decode(OnboardingFlowConfig.self, from: jsonData)
                self?.queue.async { self?.onboardingFlows[id] = config }
                completion(config)
            } catch {
                Log.error("Failed to decode onboarding flow '\(id)': \(error)")
                completion(nil)
            }
        }
    }

    /// Fetch a single screen config on-demand by ID.
    func fetchScreenConfig(screenId: String, completion: @escaping (ScreenConfig?) -> Void) {
        guard let firestorePath else {
            completion(nil)
            return
        }
        guard let db = AppDNA.firestoreDB else { completion(nil); return }
        let basePath = "\(firestorePath)/config"
        // screens/{screenId} is a subcollection document under the screen_index doc
        db.document("\(basePath)/screen_index/screens/\(screenId)").getDocument { snapshot, error in
            guard let data = snapshot?.data() else {
                completion(nil)
                return
            }
            do {
                let jsonData = try Self.sanitizedJSONData(data)
                let wrapper = try Self.snakeCaseDecoder.decode(ScreenFirestoreWrapper.self, from: jsonData)
                let config = wrapper.config
                ScreenManager.shared.cacheScreen(screenId, config: config)
                completion(config)
            } catch {
                // Try parsing the data directly as a ScreenConfig
                do {
                    let jsonData = try Self.sanitizedJSONData(data)
                    let config = try Self.snakeCaseDecoder.decode(ScreenConfig.self, from: jsonData)
                    ScreenManager.shared.cacheScreen(screenId, config: config)
                    completion(config)
                } catch {
                    Log.error("Failed to parse screen config \(screenId): \(error)")
                    completion(nil)
                }
            }
        }
    }
}

/// Wrapper for Firestore screen document (has `config` field inside).
private struct ScreenFirestoreWrapper: Codable {
    let config: ScreenConfig
}

// MARK: - Experiment config model

struct ExperimentConfig: Codable {
    let id: String?
    let name: String?
    let status: String? // "running", "paused", "completed"
    // SPEC-036-F §1.2 — the served `type` (surface kind the experiment targets,
    // e.g. "paywall", "onboarding_flow", "in_app_message", "survey"). Used by the
    // experiment-aware presentation hook to match a running experiment against
    // the surface+entity being presented. Defaulted so the memberwise init
    // stays source-compatible with existing call sites / fixtures.
    var type: String? = nil
    let salt: String?
    let platforms: [String]?
    let variants: [ExperimentVariant]?
    var segments: [String]? = nil
}

public struct ExperimentVariant: Codable {
    let id: String?
    let weight: Double?
    let payload: [String: AnyCodable]?
    // SPEC-036-F §1.2 — `config_ref` is the entity id this variant maps to:
    // for the control it's the live active entity id (rendered via the surface
    // index, no payload); for the treatment it's the materialized draft entity
    // whose renderable config the server inlined into `payload`. `is_control`
    // distinguishes the two. Both nullable + defaulted for backward-compat with
    // docs that predate the field-map fix and existing memberwise call sites.
    var config_ref: String? = nil
    var is_control: Bool? = nil
    // SPEC-036-H — `per_item` serving: a POINTER (Firestore doc path) to this treatment's isolated,
    // index-less variant doc (`config/experiment_variants/{expId}/{variantId}`) instead of an
    // inline `payload`. The SDK prefetches the doc by this exact path (never via an index) and renders
    // its `config`. Absent in `inline` mode (036-F) where `payload` carries the config. Defaulted for
    // backward-compat with docs that predate the field + existing memberwise call sites.
    var variant_doc: String? = nil
}
