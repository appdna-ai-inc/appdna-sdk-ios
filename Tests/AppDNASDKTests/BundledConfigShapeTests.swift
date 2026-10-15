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

    // MARK: - #856 — a bundle the SDK cannot read must say so

    /*
     * Every section above is optional, so a bundle carrying none of them parsed in silence and the
     * SDK carried on with no config at all: valid JSON, right size, right place, and inert.
     *
     * 🔴 That silence is the defect, not the wrong bundle. The console's CI/CD snippet saved the
     * RAW response from `/api/v1/sdk/config-bundle`, whose payload sits under `.data.content`, so
     * every key the loader looks for was one level too deep. Measured on an Android device,
     * airplane mode, fresh install each time: the raw-response asset gave `presentOnboarding →
     * false` at T+95s while `.data.content + {bundle_version}` gave `true` at T+40s — and not one
     * line was logged to tell the two apart. Mirrors `BundledConfigShapeTest` on Android.
     */
    private func logs(loading json: [String: Any]) -> String {
        var captured: [String] = []
        Log.testSink = { captured.append($0) }
        defer { Log.testSink = nil }
        _ = load(json)
        return captured.joined(separator: "\n")
    }

    func testABundleWithNoRecognisedSectionWarnsAndNamesTheLikelyCause() {
        // Exactly what the wrong snippet produced: the envelope rather than its content.
        let raw: [String: Any] = ["data": ["content": ["onboarding": [:]]], "bundle_version": 7]
        let out = logs(loading: raw)
        XCTAssertTrue(out.contains("none of the sections"),
                      "a bundle the SDK cannot read must warn — logs were:\n\(out)")
        XCTAssertTrue(out.contains("data"), "the warning must name the keys that WERE present")
        XCTAssertTrue(out.contains(".data.content"), "the warning must name the likely cause")
    }

    func testACorrectBundleStaysQuiet() {
        // The guard must not cry wolf, or it becomes a line people learn to scroll past.
        let out = logs(loading: ["onboarding": [:], "bundle_version": 7])
        XCTAssertFalse(out.contains("none of the sections"),
                       "a correct bundle must NOT warn — logs were:\n\(out)")
    }

    func testAnEmptyBundleWarnsToo() {
        XCTAssertTrue(logs(loading: [:]).contains("none of the sections"))
    }
}

