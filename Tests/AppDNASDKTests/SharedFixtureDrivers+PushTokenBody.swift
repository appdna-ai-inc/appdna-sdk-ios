import XCTest
@testable import AppDNASDK

extension SharedFixtureTests {
    // build_push_token_body REAL: `PushTokenRegistration.body`, the body both registration and re-registration
    // send. [anon_id or NSNull, user_id or NSNull] per case.
    func runPushTokenBody(_ f: Fixture, _ h: Harness) {
        guard let cases = f.action.raw["cases"]?.arrayValue else {
            XCTFail("[\(f.id)] build_push_token_body needs action.cases")
            return
        }
        h.state["results"] = cases.map { c -> Any in
            let obj = c.objectValue ?? [:]
            let body = PushTokenRegistration.body(
                token: "t", platform: "ios", deviceId: "d", appVersion: "1", sdkVersion: "1", osVersion: "1",
                anonId: obj["anon_id"]?.foundation as? String, userId: obj["user_id"]?.foundation as? String)
            return [body["anon_id"] ?? NSNull(), body["user_id"] ?? NSNull()]
        }
    }
}
