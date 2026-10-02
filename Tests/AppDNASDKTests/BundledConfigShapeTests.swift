// BundledConfigShapeTests.swift
//
// The embedded `appdna-config.json` in the shape the server builds it: every section in its mega-doc shape
// (`{paywalls:{id:…}}`, `{active_flow_id, flows:{…}}`, `{surveys:{…}}`, `{messages:{…}}`), flags as RAW
// values, and a paywall set well over 1 MB — the size at which the server's old source (the legacy paywall
// mega-doc) was skipped. Every section loads; the flags read back as their values. Android
// `BundledConfigShapeTest`, same bundle.
//
// The negative control is kept as a test: a bundle whose flags are `{value, type}` wrappers (what the old
// bundle carried) reaches the flag getter as a dictionary — the bundle loader assigns the map as-is, which
// is why the server now writes raw values.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class BundledConfigShapeTests: XCTestCase {

    static let paywallCount = 40

    /// A paywall set of `paywallCount` paywalls, each carrying a ~30 KB localized string.
    static func bundle(flags: [String: Any]) -> [String: Any] {
        let pad = String(repeating: "x", count: 30_000)
        var paywalls: [String: Any] = [:]
        for i in 0..<paywallCount {
            let id = "pw_\(i)"
            paywalls[id] = [
                "id": id, "name": "Paywall \(i)", "placement": "placement_\(i)", "version": 1,
                "localizations": ["en": ["pad": pad]], "default_locale": "en",
            ] as [String: Any]
        }
        return [
            "paywalls": ["paywalls": paywalls],
            "onboarding": ["active_flow_id": "f1", "flows": ["f1": ["id": "f1", "name": "Flow", "version": 1, "steps": []]]],
            "surveys": ["surveys": ["s1": ["name": "Survey", "survey_type": "nps", "questions": []]]],
            "messages": ["messages": ["m1": ["name": "Message", "message_type": "modal"]]],
            "remote_config": flags,
            "feature_flags": flags,
            "experiments": [:] as [String: Any],
            "screen_index": [:] as [String: Any],
            "brand": [:] as [String: Any],
            "bundle_version": 7,
        ]
    }

    private func load(_ json: [String: Any]) -> RemoteConfigManager {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.bundleshape.\(UUID().uuidString)")
        let rcm = RemoteConfigManager(firestorePath: nil, configCache: cache, configTTL: 3600)
        rcm.loadBundledConfig(json)
        return rcm
    }

    func testEverySectionOfAServerBuiltBundleLoadsIncludingAPaywallSetOverOneMegabyte() throws {
        let json = Self.bundle(flags: ["k_bool": true, "k_num": 3, "k_str": "x"])
        let size = try JSONSerialization.data(withJSONObject: json).count
        XCTAssertGreaterThan(size, 1_048_576, "the bundle must be over 1 MB to prove anything")

        // Through JSON bytes, as the SDK reads the file.
        let reread = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: json)) as? [String: Any])
        let rcm = load(reread)

        XCTAssertEqual(rcm.getAllPaywalls().count, Self.paywallCount, "paywalls lost from a > 1 MB bundle")
        XCTAssertEqual(rcm.getPaywallConfig(id: "pw_39")?.localizations?["en"]?["pad"]?.count, 30_000)
        XCTAssertEqual(Set(rcm.getAllOnboardingFlows().keys), ["f1"])
        XCTAssertEqual(Set(rcm.getSurveyConfigs().keys), ["s1"])
        XCTAssertEqual(Set(rcm._getMessagesForTesting().keys), ["m1"])

        let flags = FeatureFlagManager(remoteConfigManager: rcm)
        XCTAssertEqual(flags.getValue(flag: "k_bool") as? Bool, true)
        XCTAssertTrue(flags.isEnabled(flag: "k_bool"))
        XCTAssertEqual((flags.getValue(flag: "k_num") as? NSNumber)?.intValue, 3)
        XCTAssertEqual(flags.getValue(flag: "k_str") as? String, "x")
    }

    /// Negative control: wrapped flag entries reach the getter as dictionaries, not values.
    func testWrappedFlagsInABundleReachTheGetterAsDictionaries() {
        let rcm = load(Self.bundle(flags: ["k_bool": ["value": true, "type": "boolean"]]))
        let flags = FeatureFlagManager(remoteConfigManager: rcm)
        XCTAssertNotNil(flags.getValue(flag: "k_bool") as? [String: Any],
                        "the loader unwraps flags now — the server could go back to wrapped entries")
        XCTAssertNil(flags.getValue(flag: "k_bool") as? Bool)
    }
}
