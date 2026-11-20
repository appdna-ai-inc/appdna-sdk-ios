import XCTest
@testable import AppDNASDK

/// `identity/anonymous_id_*`: the public anonymous id (`AppDNA.anonymousId`, whose rule is
/// `AppDNA.resolveAnonymousId`) read across the steps a host goes through. REAL: IdentityManager over an in-memory
/// Keychain double; `relaunch` builds a new IdentityManager on the same Keychain, `reinstall` on an empty one.
/// The reads are reported as letters in order of first appearance ("A", "A", "B"), because the id itself is minted.
extension SharedFixtureTests {
    @MainActor
    func driveIdentityFixtures(_ f: Fixture, _ h: Harness) -> Bool {
        guard f.action.kind == "anonymous_id_lifecycle" else { return false }
        guard let steps = f.action.raw["calls"]?.arrayValue?.compactMap({ $0.stringValue }) else {
            XCTFail("[\(f.id)] anonymous_id_lifecycle needs action.calls")
            return true
        }
        var store: KeychainStoring = ConsentFixtureKeychain()
        var manager = IdentityManager(keychainStore: store)
        var reads: [String] = []
        for step in steps {
            switch step {
            case "read":
                let current = store
                reads.append(AppDNA.resolveAnonymousId(manager: manager) { current })
            case "read_before_configure":
                let current = store
                reads.append(AppDNA.resolveAnonymousId(manager: nil) { current })
            case "identify": manager.identify(userId: f.action.raw["userId"]?.stringValue ?? "fixture_user")
            case "reset": manager.reset()
            case "relaunch": manager = IdentityManager(keychainStore: store)
            case "reinstall":
                store = ConsentFixtureKeychain()
                manager = IdentityManager(keychainStore: store)
            default:
                XCTFail("[\(f.id)] unknown step '\(step)'")
            }
        }
        var letters: [String: String] = [:]
        h.state["anonymous_id_reads"] = reads.map { id -> String in
            if let l = letters[id] { return l }
            let l = String(UnicodeScalar(UInt8(65 + letters.count)))
            letters[id] = l
            return l
        }
        let uuid = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        let allUuid = reads.allSatisfy { uuid.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        h.state["anonymous_id_format"] = allUuid ? "uuid_lowercase" : "other"
        return true
    }
}
