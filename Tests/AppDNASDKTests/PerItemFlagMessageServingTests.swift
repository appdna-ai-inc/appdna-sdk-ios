import XCTest
@testable import AppDNASDK

/// Per-item flag + message serving on the SDK read side. Covers the exact logic where the
/// R1/R2 audit bugs lived: flag `.value` unwrap, null-flag → unset, prune-to-index-keyset (removal),
/// empty-set clear, and per-item message decode. Drives the REAL parsers via test seams.
final class PerItemFlagMessageServingTests: XCTestCase {

    private func makeRCM() -> RemoteConfigManager {
        let cache = ConfigCache(ttl: 3600, suiteName: "ai.appdna.sdk.test.\(UUID().uuidString)")
        return RemoteConfigManager(firestorePath: "orgs/o/apps/a", configCache: cache, configTTL: 3600)
    }

    // ── Flags: .value unwrap + isEnabled/getValue ──
    func testFlagValueUnwrap_boolTrue() {
        let rcm = makeRCM(); let ff = FeatureFlagManager(remoteConfigManager: rcm)
        rcm._parseFlagDocForTesting(key: "f", data: ["key": "f", "value": true, "type": "boolean"])
        XCTAssertEqual(rcm.getConfig(key: "f") as? Bool, true)   // raw value, NOT the wrapper dict
        XCTAssertTrue(ff.isEnabled(flag: "f"))
    }

    func testFlagValueUnwrap_boolFalseNotDropped() {
        let rcm = makeRCM(); let ff = FeatureFlagManager(remoteConfigManager: rcm)
        rcm._parseFlagDocForTesting(key: "f", data: ["key": "f", "value": false, "type": "boolean"])
        XCTAssertEqual(rcm.getConfig(key: "f") as? Bool, false)  // false preserved (not treated as unset)
        XCTAssertFalse(ff.isEnabled(flag: "f"))
    }

    func testFlagValueUnwrap_numberAndString() {
        let rcm = makeRCM()
        rcm._parseFlagDocForTesting(key: "n", data: ["key": "n", "value": 7, "type": "number"])
        rcm._parseFlagDocForTesting(key: "s", data: ["key": "s", "value": "blue", "type": "string"])
        XCTAssertEqual(rcm.getConfig(key: "n") as? Int, 7)
        XCTAssertEqual(rcm.getConfig(key: "s") as? String, "blue")
    }

    func testNullValuedFlagIsUnset() {
        let rcm = makeRCM()
        rcm._parseFlagDocForTesting(key: "x", data: ["key": "x", "value": NSNull(), "type": "string"])
        XCTAssertNil(rcm.getConfig(key: "x"))  // null value ⇒ key omitted (parity with Android)
    }

    // ── Removal / empty-set: prune to the index keyset ──
    func testPruneRemovesFlagNotInIndex() {
        let rcm = makeRCM()
        rcm._parseFlagDocForTesting(key: "a", data: ["value": true])
        rcm._parseFlagDocForTesting(key: "b", data: ["value": true])
        rcm._pruneFlagsForTesting(["a"])               // index now lists only "a"
        XCTAssertEqual(rcm.getConfig(key: "a") as? Bool, true)
        XCTAssertNil(rcm.getConfig(key: "b"))          // removed flag stops serving
    }

    func testEmptyIndexClearsAllFlags() {
        let rcm = makeRCM()
        rcm._parseFlagDocForTesting(key: "a", data: ["value": true])
        rcm._pruneFlagsForTesting([])                  // empty index ⇒ clear
        XCTAssertNil(rcm.getConfig(key: "a"))
        XCTAssertTrue(rcm.getAllFlags().isEmpty)
    }

    // ── Messages: per-item decode + prune ──
    func testPerItemMessageDecodes() {
        let rcm = makeRCM()
        rcm._parseMessageDocForTesting(id: "m1", data: [
            "name": "Winback", "message_type": "modal",
            "content": ["title": "Come back", "body": "We miss you"],
            "trigger_rules": ["event": "app_open"],
        ])
        let msgs = rcm._getMessagesForTesting()
        XCTAssertEqual(msgs["m1"]?.name, "Winback")
        XCTAssertEqual(msgs["m1"]?.content?.title, "Come back")
    }

    func testPruneRemovesMessageNotInIndex() {
        let rcm = makeRCM()
        rcm._parseMessageDocForTesting(id: "m1", data: ["name": "A", "message_type": "modal"])
        rcm._parseMessageDocForTesting(id: "m2", data: ["name": "B", "message_type": "modal"])
        rcm._pruneMessagesForTesting(["m1"])
        XCTAssertNotNil(rcm._getMessagesForTesting()["m1"])
        XCTAssertNil(rcm._getMessagesForTesting()["m2"])  // removed message stops serving
    }
}
