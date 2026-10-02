import Foundation

/// Manages experiment variant assignment via deterministic MurmurHash3 bucketing.
/// A user is in an experiment only when it is running, targets this platform, every targeting rule passes and the
/// user falls inside the traffic allocation (`ExperimentEligibility`); only then is a variant assigned and an exposure
/// tracked. Exposures are tracked once per experiment until `reset()` or the next app launch (they are kept in memory).
final class ExperimentManager {
    private let queue = DispatchQueue(label: "ai.appdna.sdk.experiments")

    /// The bucketing salt: the configured salt if it has any non-whitespace content, else the
    /// experimentId. Mirrors Android's `config.salt.ifBlank { experimentId }` — iOS used `?? experimentId`
    /// (nil ONLY), so an empty/whitespace salt (a hand-edited/imported/legacy Firestore doc) hashed with
    /// the literal empty salt on iOS but substituted experimentId on Android → the same user bucketed to
    /// different variants across platforms.
    private static func resolvedSalt(_ salt: String?, _ experimentId: String) -> String {
        if let s = salt, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        return experimentId
    }
    private let remoteConfigManager: RemoteConfigManager
    private let identityManager: IdentityManager
    private let eventTracker: EventTracker
    /// The device facts targeting is evaluated against (injectable for tests).
    private let eligibilityContext: (_ traits: [String: Any]) -> ExperimentEligibilityContext

    /// Map of experiment IDs to variant IDs for which exposure has been tracked since the last `reset()` / launch.
    private var exposedExperiments: [String: String] = [:]

    init(
        remoteConfigManager: RemoteConfigManager,
        identityManager: IdentityManager,
        eventTracker: EventTracker,
        eligibilityContext: @escaping (_ traits: [String: Any]) -> ExperimentEligibilityContext = ExperimentEligibilityContext.current(traits:)
    ) {
        self.remoteConfigManager = remoteConfigManager
        self.identityManager = identityManager
        self.eventTracker = eventTracker
        self.eligibilityContext = eligibilityContext
    }

    /// Get the variant for an experiment. Returns nil if the user is not in it (not running, platform / targeting /
    /// traffic allocation excludes them). Auto-tracks the exposure on the first assignment.
    func getVariant(experimentId: String) -> String? {
        let identity = identityManager.currentIdentity
        let userId = identity.userId ?? identity.anonId
        guard let config = resolveConfig(experimentId: experimentId, userId: userId) else { return nil }

        // Deterministic bucketing via ExperimentBucketer
        guard let variant = ExperimentBucketer.assignVariant(
            experimentId: experimentId,
            userId: userId,
            salt: Self.resolvedSalt(config.salt, experimentId),
            variants: config.variants ?? []
        ) else {
            return nil
        }

        // Track exposure (once per experiment until reset() / relaunch)
        trackExposure(experimentId: experimentId, variant: variant)

        return variant
    }

    /// Check if the user is assigned to a specific variant.
    func isInVariant(experimentId: String, variantId: String) -> Bool {
        return getVariant(experimentId: experimentId) == variantId
    }

    /// Get a specific config value from the assigned variant's payload.
    func getExperimentConfig(experimentId: String, key: String) -> Any? {
        let identity = identityManager.currentIdentity
        let userId = identity.userId ?? identity.anonId
        guard let config = resolveConfig(experimentId: experimentId, userId: userId) else { return nil }

        guard let variantId = ExperimentBucketer.assignVariant(
            experimentId: experimentId,
            userId: userId,
            salt: Self.resolvedSalt(config.salt, experimentId),
            variants: config.variants ?? []
        ) else {
            return nil
        }

        // Track exposure (once per experiment until reset() / relaunch)
        trackExposure(experimentId: experimentId, variant: variantId)

        // Find variant and return config value
        guard let variant = (config.variants ?? []).first(where: { $0.id == variantId }),
              let payload = variant.payload else {
            return nil
        }

        return payload[key]?.value
    }

    // MARK: - SPEC-036-F §1.2 — experiment-aware surface presentation

    /// The outcome of resolving whether a running experiment governs how a
    /// given surface entity should be presented.
    enum SurfaceResolution {
        /// No running experiment targets this surface+entity, the user wasn't
        /// bucketed, or the SDK fell to the control bucket → render the live
        /// active entity through the normal (index-backed) path.
        case renderActive
        /// The user is bucketed into the treatment variant → render the inlined
        /// `payload` config instead of the active entity. The dictionary is the
        /// raw Firestore-shaped config map (same shape `parsePaywalls` etc.
        /// consume), ready to run through `sanitizedJSONData`.
        case renderTreatment(experimentId: String, variantId: String, payload: [String: Any])
    }

    /// SPEC-036-F §1.2 — decide whether a `running` experiment governs the
    /// presentation of `entityId` for the given surface `type`. Matches an
    /// experiment whose served `type` == `surfaceType` AND whose control
    /// variant's `config_ref` == `entityId` (the entity the host is about to
    /// present). On a match the user is bucketed via the SAME
    /// `ExperimentBucketer.assignVariant` path (+ exposure tracked):
    ///   - control bucket / no payload → `.renderActive`
    ///   - treatment bucket with payload → `.renderTreatment(...)`
    /// Cohort isolation (§1.3): the treatment config lives ONLY in the
    /// experiment doc payload, so a non-bucketed / control / old-SDK user can
    /// never resolve to it — they always fall to `.renderActive`.
    func resolveSurfacePresentation(surfaceType: String, entityId: String) -> SurfaceResolution {
        let allExperiments = remoteConfigManager.getAllExperiments()

        for (experimentId, config) in allExperiments {
            // Only `running` experiments serve, and only on the requested
            // platform (`resolveConfig` enforces both — reuse it).
            guard config.status == "running" else { continue }
            guard config.type == surfaceType else { continue }
            guard (config.platforms ?? ["ios"]).contains("ios") else { continue }

            // The control variant's config_ref names the live active entity.
            let variants = config.variants ?? []
            guard variants.contains(where: { ($0.is_control ?? false) && $0.config_ref == entityId }) else {
                continue
            }

            // Targeting + traffic allocation (same gate as getVariant): a user who is not in the experiment sees the
            // live entity and is not exposed.
            let identity = identityManager.currentIdentity
            let userId = identity.userId ?? identity.anonId
            guard isInExperiment(experimentId: experimentId, config: config, userId: userId) else { continue }

            // Bucket the user deterministically (same path as getVariant).
            guard let variantId = ExperimentBucketer.assignVariant(
                experimentId: experimentId,
                userId: userId,
                salt: Self.resolvedSalt(config.salt, experimentId),
                variants: variants
            ) else {
                continue
            }

            // Track the exposure once, regardless of bucket — the user WAS exposed to the experiment by virtue of
            // seeing this surface.
            trackExposure(experimentId: experimentId, variant: variantId)

            guard let variant = variants.first(where: { $0.id == variantId }) else {
                return .renderActive
            }

            // Control bucket → render the live active entity. Treatment WITHOUT
            // a payload (e.g. an old/over-limit served doc that dropped it) →
            // safe fallback to active. Only a treatment WITH a payload renders
            // the variant config.
            if (variant.is_control ?? false) {
                return .renderActive
            }
            // SPEC-036-H — `per_item` serving: the treatment config lives in an isolated variant doc
            // pointed to by `variant_doc` (prefetched into the RemoteConfigManager cache). Prefer it;
            // fall back to the `inline` 036-F `payload`. A not-yet-fetched / failed variant doc → render
            // the active item (never broken, never cross-cohort).
            if let docPath = variant.variant_doc {
                guard let payload = remoteConfigManager.getVariantDoc(path: docPath) else {
                    return .renderActive
                }
                return .renderTreatment(experimentId: experimentId, variantId: variantId, payload: payload)
            }
            guard let payloadCodable = variant.payload else {
                return .renderActive
            }
            // Unwrap [String: AnyCodable] → [String: Any] for the typed-config
            // decode pipeline (sanitizedJSONData) the surface managers run.
            let payload = payloadCodable.mapValues { $0.value }
            return .renderTreatment(experimentId: experimentId, variantId: variantId, payload: payload)
        }

        return .renderActive
    }

    /// Get all active experiment exposures as (experimentId, variant) tuples.
    func getExposures() -> [(experimentId: String, variant: String)] {
        queue.sync {
            exposedExperiments.map { (experimentId: $0.key, variant: $0.value) }
        }
    }

    /// Reset exposure tracking (called by `reset()`; exposures are otherwise kept until the app is relaunched — a new
    /// session does not reset them).
    func resetExposures() {
        queue.sync { exposedExperiments.removeAll() }
    }

    // MARK: - Private

    /// Running, on this platform, and the user is in the experiment (targeting + traffic allocation).
    private func resolveConfig(experimentId: String, userId: String) -> ExperimentConfig? {
        guard let config = remoteConfigManager.getExperimentConfig(id: experimentId) else {
            Log.debug("Experiment '\(experimentId)' not found in config")
            return nil
        }

        guard config.status == "running" else {
            Log.debug("Experiment '\(experimentId)' is not running (status: \(config.status ?? "unknown"))")
            return nil
        }

        guard (config.platforms ?? ["ios"]).contains("ios") else {
            Log.debug("Experiment '\(experimentId)' does not target iOS")
            return nil
        }

        guard isInExperiment(experimentId: experimentId, config: config, userId: userId) else { return nil }
        return config
    }

    /// Targeting rules, then the traffic allocation. Logs why a user is out.
    private func isInExperiment(experimentId: String, config: ExperimentConfig, userId: String) -> Bool {
        let traits = identityManager.currentIdentity.traits ?? [:]
        if let failed = ExperimentEligibility.failedRule(
            targeting: config.targeting,
            startedAtMs: config.started_at_ms,
            context: eligibilityContext(traits)
        ) {
            Log.debug("Experiment '\(experimentId)': user not in the audience (\(failed.rawValue))")
            return false
        }
        guard ExperimentEligibility.isAllocated(
            experimentId: experimentId,
            salt: Self.resolvedSalt(config.salt, experimentId),
            userId: userId,
            trafficAllocation: config.traffic_allocation
        ) else {
            Log.debug("Experiment '\(experimentId)': user outside the traffic allocation")
            return false
        }
        return true
    }

    private func trackExposure(experimentId: String, variant: String) {
        // Record the exposure under the lock, capturing whether it is NEW (since reset() / launch).
        let isNew: Bool = queue.sync {
            guard exposedExperiments[experimentId] == nil else { return false }
            exposedExperiments[experimentId] = variant
            return true
        }
        guard isNew else { return }
        // 🔴 track() MUST be called OUTSIDE `queue.sync`. Every event now attaches experiment exposures
        // via the provider, which calls `getExposures()` → `queue.sync` on THIS serial queue. Calling
        // track() while still holding the queue re-enters it and deadlocks (GCD serial queues are
        // non-reentrant) — hanging the first getVariant()/isInVariant() of the session on the caller's
        // (usually main) thread. Emitting after the critical section closes breaks the cycle; the
        // check-and-set above already made this exposure exactly-once.
        eventTracker.track(event: "experiment_exposure", properties: [
            "experiment_id": experimentId,
            "variant": variant,
            "source": "sdk",
        ])
    }
}

// MARK: - MurmurHash3 (kept for backward compatibility; delegates to ExperimentBucketer)

enum MurmurHash3 {
    static func hash32(_ key: String, seed: UInt32 = 0) -> UInt32 {
        ExperimentBucketer.hash32(key, seed: seed)
    }
}
