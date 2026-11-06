import XCTest
@testable import AppDNASDK

/*
 The push-token registration body carries who the token belongs to, through the real `PushTokenManager`
 (its `send` recorded instead of hitting the network): `anon_id` always, `user_id` once identify ran. A
 re-registration (what identify and reset trigger) sends the identity as it is now. Before, the body had
 neither, and the server stored every token as user `anonymous`.
*/
final class PushTokenIdentityTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [[String: Any]] = []
        func add(_ b: [String: Any]) { lock.lock(); _bodies.append(b); lock.unlock() }
        var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }
    }

    private func waitFor(_ n: Int, _ r: Recorder) -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(10)
        while r.bodies.count < n && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return r.bodies
    }

    func testTheRegistrationBodyCarriesAnonIdAndOnceIdentifiedUserId() {
        let keychain = KeychainStore(service: "ai.appdna.sdk.pushid.\(UUID().uuidString)")
        let recorder = Recorder()
        var userId: String?
        let manager = PushTokenManager(
            keychainStore: keychain, eventTracker: nil, apiClient: nil,
            identity: { ("anon-synthetic-1", userId) },
            send: { recorder.add($0) })

        manager.setPushToken(Data([0xAB, 0xCD]))
        var bodies = waitFor(1, recorder)
        XCTAssertEqual(bodies.first?["anon_id"] as? String, "anon-synthetic-1")
        XCTAssertNil(bodies.first?["user_id"], "no user yet, so no user_id")

        userId = "user-synthetic-9" // identify()
        manager.reregister()
        bodies = waitFor(2, recorder)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.last?["token"] as? String, "abcd")
        XCTAssertEqual(bodies.last?["user_id"] as? String, "user-synthetic-9")
        XCTAssertEqual(bodies.last?["anon_id"] as? String, "anon-synthetic-1")

        userId = nil // reset()
        manager.reregister()
        bodies = waitFor(3, recorder)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertNil(bodies.last?["user_id"], "reset sends no user_id")
    }
}
