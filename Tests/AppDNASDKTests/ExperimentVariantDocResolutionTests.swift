import XCTest
@testable import AppDNASDK

/// `resolveSurfacePresentation` per-item variant-doc serving.
///
/// In `per_item` mode the experiments doc carries a `variant_doc` POINTER (a Firestore path) instead of
/// an inline `payload`; the SDK prefetches that doc's `config` into `RemoteConfigManager` and resolves
/// the treatment from it. These tests pin:
///   - treatment bucket + prefetched variant doc → `.renderTreatment` with the doc's config as payload
///   - treatment bucket + variant_doc NOT prefetched (cache miss / fetch failure) → `.renderActive`
///     (failure degradation — never broken, never cross-cohort)
///   - `inline` mode (payload present, no variant_doc) still resolves via the inline payload (036-F)
///   - control bucket never resolves to a variant doc
///
/// Bucketing is forced deterministically by weighting one variant 1.0 and the other 0.0, so every user
/// lands in the intended bucket regardless of their hashed id.
final class ExperimentVariantDocResolutionTests: XCTestCase {

    private func makeManagers() -> (ExperimentManager, RemoteConfigManager) {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let keychain = KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let identity = IdentityManager(keychainStore: keychain)
        let tracker = EventTracker(identityManager: identity)
        let em = ExperimentManager(remoteConfigManager: rcm, identityManager: identity, eventTracker: tracker)
        return (em, rcm)
    }

    // Even-segment document path the backend actually writes (config/experiment_variants/{expId}/{variantId}).
    private let docPath = "orgs/o/apps/a/config/experiment_variants/exp-1/treatment"

    /// Build a paywall experiment whose control points at `pw-live`. `treatmentWeight` controls which
    /// bucket every user lands in; `variantDoc`/`inlinePayload` configure the treatment's serving mode.
    private func makeExperiment(
        treatmentWeight: Double,
        variantDoc: String? = nil,
        inlinePayload: [String: AnyCodable]? = nil
    ) -> [String: ExperimentConfig] {
        let control = ExperimentVariant(
            id: "control", weight: 1.0 - treatmentWeight, payload: nil,
            config_ref: "pw-live", is_control: true
        )
        let treatment = ExperimentVariant(
            id: "treatment", weight: treatmentWeight, payload: inlinePayload,
            config_ref: "pw-draft", is_control: false, variant_doc: variantDoc
        )
        let cfg = ExperimentConfig(
            id: "exp-1", name: "Paywall copy", status: "running", type: "paywall",
            salt: "salt-1", platforms: ["ios"], variants: [control, treatment]
        )
        return ["exp-1": cfg]
    }

    func testPerItem_treatmentBucket_rendersPrefetchedVariantDoc() {
        let (em, rcm) = makeManagers()
        rcm._injectExperimentsForTesting(makeExperiment(treatmentWeight: 1.0, variantDoc: docPath))
        rcm._injectVariantDocForTesting(path: docPath, config: ["id": "pw-draft", "layout": ["kind": "paywall"]])

        let resolution = em.resolveSurfacePresentation(surfaceType: "paywall", entityId: "pw-live")
        guard case let .renderTreatment(experimentId, variantId, payload) = resolution else {
            return XCTFail("expected .renderTreatment, got \(resolution)")
        }
        XCTAssertEqual(experimentId, "exp-1")
        XCTAssertEqual(variantId, "treatment")
        XCTAssertEqual(payload["id"] as? String, "pw-draft")
        XCTAssertNotNil(payload["layout"])
    }

    func testPerItem_treatmentBucket_variantDocNotPrefetched_fallsBackToActive() {
        let (em, rcm) = makeManagers()
        // variant_doc present on the variant but NOT injected into the cache → simulate a not-yet-fetched
        // or failed fetch. Must degrade to .renderActive (never render a half-resolved / cross-cohort UI).
        rcm._injectExperimentsForTesting(makeExperiment(treatmentWeight: 1.0, variantDoc: docPath))

        let resolution = em.resolveSurfacePresentation(surfaceType: "paywall", entityId: "pw-live")
        guard case .renderActive = resolution else {
            return XCTFail("expected .renderActive on variant-doc cache miss, got \(resolution)")
        }
    }

    func testInlineMode_treatmentBucket_rendersInlinePayload() {
        let (em, rcm) = makeManagers()
        // 036-F inline mode: no variant_doc, payload carries the config.
        rcm._injectExperimentsForTesting(makeExperiment(
            treatmentWeight: 1.0,
            inlinePayload: ["id": AnyCodable("pw-draft"), "layout": AnyCodable(["kind": "paywall"])]
        ))

        let resolution = em.resolveSurfacePresentation(surfaceType: "paywall", entityId: "pw-live")
        guard case let .renderTreatment(_, _, payload) = resolution else {
            return XCTFail("expected .renderTreatment from inline payload, got \(resolution)")
        }
        XCTAssertEqual(payload["id"] as? String, "pw-draft")
    }

    func testControlBucket_neverResolvesVariantDoc() {
        let (em, rcm) = makeManagers()
        // Everyone buckets to control (treatmentWeight 0.0); a variant doc is even prefetched, but a
        // control bucket must render the active entity and never reach into the variant doc.
        rcm._injectExperimentsForTesting(makeExperiment(treatmentWeight: 0.0, variantDoc: docPath))
        rcm._injectVariantDocForTesting(path: docPath, config: ["id": "pw-draft"])

        let resolution = em.resolveSurfacePresentation(surfaceType: "paywall", entityId: "pw-live")
        guard case .renderActive = resolution else {
            return XCTFail("expected .renderActive for control bucket, got \(resolution)")
        }
    }

    func testGetVariantDoc_returnsInjectedConfig() {
        let (_, rcm) = makeManagers()
        XCTAssertNil(rcm.getVariantDoc(path: docPath))
        rcm._injectVariantDocForTesting(path: docPath, config: ["id": "pw-draft"])
        XCTAssertEqual(rcm.getVariantDoc(path: docPath)?["id"] as? String, "pw-draft")
    }

    /// 🔴 REGRESSION GUARD: wiring the experiment-exposure provider (exactly as `performConfigure` does)
    /// must NOT deadlock. `trackExposure` records the exposure under `queue.sync`; every `track()` now
    /// attaches exposures via the provider → `getExposures()` → `queue.sync` on the SAME serial queue.
    /// If the exposure event is emitted INSIDE the first `queue.sync`, the second re-enters the
    /// (non-reentrant) serial queue and deadlocks the caller — hanging the first `getVariant()` of the
    /// session. The shared-fixture exposure test never sets the provider, so it cannot catch this; this
    /// drives the real wired path and asserts the call returns promptly.
    func testExposureProviderWiredGetVariantDoesNotDeadlock() {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
        let keychain = KeychainStore(service: "ai.appdna.sdk.test.\(UUID().uuidString)")
        let identity = IdentityManager(keychainStore: keychain)
        let tracker = EventTracker(identityManager: identity)
        let em = ExperimentManager(remoteConfigManager: rcm, identityManager: identity, eventTracker: tracker)
        // Wire the provider the same way performConfigure does.
        tracker.setExperimentExposureProvider {
            em.getExposures().map { ExperimentExposure(exp: $0.experimentId, variant: $0.variant) }
        }
        rcm._injectExperimentsForTesting(makeExperiment(treatmentWeight: 1.0))

        let done = expectation(description: "getVariant returned without deadlock")
        // Off the test thread so a deadlock trips the timeout instead of hanging XCTest itself.
        DispatchQueue.global().async {
            _ = em.getVariant(experimentId: "exp-1") // → trackExposure → track → provider → getExposures
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
