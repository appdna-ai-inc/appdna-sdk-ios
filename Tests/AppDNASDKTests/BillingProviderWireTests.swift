import XCTest
@testable import AppDNASDK

/// `BillingProvider` wire format.
///
/// THE BUG: iOS's `BillingProvider` wasn't `Codable` and had no wire form at all, so the one case
/// that carries data — `.adapty(apiKey:)` — could not cross a wrapper channel: the key had nowhere
/// to go. Android has carried `fromWire` / `toWire` for a long time
/// (`Configuration.kt:71` / `:95`). The shared fixture
/// `dto_parsing/billing_provider_adapty_tagged_map` claims `ios` and asserts a LOSSLESS round-trip.
///
/// Contract, read off Android and matched exactly:
///   - value-less cases cross as BARE STRINGS: "storeKit2" | "revenueCat" | "none"
///   - `adapty` crosses as a TAGGED MAP: {"type": "adapty", "apiKey": "..."}
///   - a bare "adapty" is NOT decodable (it carries no key) — nil, not a silent default
final class BillingProviderWireTests: XCTestCase {

    // MARK: - fromWire

    func testTaggedMapDecodesToAdaptyWithTheKeyPreserved() {
        let wire: [String: Any] = ["type": "adapty", "apiKey": "public_live_abc123XYZ"]
        let provider = BillingProvider.fromWire(wire)
        XCTAssertEqual(provider, BillingProvider.adapty(apiKey: "public_live_abc123XYZ"))
        XCTAssertEqual(provider?.type, "adapty")
        XCTAssertEqual(provider?.apiKey, "public_live_abc123XYZ")
    }

    func testBareStringsDecodeToTheValuelessCases() {
        XCTAssertEqual(BillingProvider.fromWire("storeKit2"), BillingProvider.storeKit2)
        XCTAssertEqual(BillingProvider.fromWire("revenueCat"), BillingProvider.revenueCat)
        // Asserted through `.type`, NOT `XCTAssertEqual(fromWire("none"), .none)`: in a
        // `BillingProvider?` position `.none` means `Optional.none`, so that comparison collapses to
        // `nil == nil` and passed for months while `fromWire("none")` actually returned nil.
        XCTAssertEqual(BillingProvider.fromWire("none")?.type, "none")
        XCTAssertNotNil(BillingProvider.fromWire("none"))
    }

    /// A bare "adapty" carries no key, so it cannot be honored. Returning nil lets the caller choose
    /// between a default and an error instead of silently starting Adapty with no credentials.
    func testBareAdaptyIsRejected() {
        XCTAssertNil(BillingProvider.fromWire("adapty"))
        XCTAssertNil(BillingProvider.fromWire(["type": "adapty"]))
        XCTAssertNil(BillingProvider.fromWire(["type": "adapty", "apiKey": ""]))
    }

    func testGarbageIsRejected() {
        XCTAssertNil(BillingProvider.fromWire(nil))
        XCTAssertNil(BillingProvider.fromWire(42))
        XCTAssertNil(BillingProvider.fromWire("StoreKit2"))  // case-sensitive tag
        XCTAssertNil(BillingProvider.fromWire(["type": "stripe"]))
    }

    // MARK: - toWire

    func testAdaptyReencodesToTheIdenticalTaggedMap() throws {
        let provider = BillingProvider.adapty(apiKey: "public_live_abc123XYZ")
        let wire = try XCTUnwrap(provider.toWire() as? [String: Any])
        XCTAssertEqual(wire["type"] as? String, "adapty")
        XCTAssertEqual(wire["apiKey"] as? String, "public_live_abc123XYZ")
        XCTAssertEqual(wire.count, 2, "no extra keys — Android emits exactly these two")
    }

    func testValuelessCasesReencodeToBareStrings() {
        XCTAssertEqual(BillingProvider.storeKit2.toWire() as? String, "storeKit2")
        XCTAssertEqual(BillingProvider.revenueCat.toWire() as? String, "revenueCat")
        XCTAssertEqual(BillingProvider.none.toWire() as? String, "none")
    }

    /// The fixture's actual assertion: decode → re-encode → identical.
    func testLosslessRoundTrip() throws {
        let original: [String: Any] = ["type": "adapty", "apiKey": "public_live_abc123XYZ"]
        let provider = try XCTUnwrap(BillingProvider.fromWire(original))
        let reencoded = try XCTUnwrap(provider.toWire() as? [String: Any])
        XCTAssertEqual(reencoded["type"] as? String, original["type"] as? String)
        XCTAssertEqual(reencoded["apiKey"] as? String, original["apiKey"] as? String)

        for bare in ["storeKit2", "revenueCat", "none"] {
            let decoded = try XCTUnwrap(BillingProvider.fromWire(bare))
            XCTAssertEqual(decoded.toWire() as? String, bare)
        }
    }

    // MARK: - Codable (JSON must agree with the channel form)

    func testJSONRoundTripAdapty() throws {
        let encoded = try JSONEncoder().encode(BillingProvider.adapty(apiKey: "k1"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "adapty")
        XCTAssertEqual(json["apiKey"] as? String, "k1")

        let decoded = try JSONDecoder().decode(BillingProvider.self, from: encoded)
        XCTAssertEqual(decoded, BillingProvider.adapty(apiKey: "k1"))
    }

    func testJSONRoundTripBareCases() throws {
        for provider: BillingProvider in [.storeKit2, .revenueCat, .none] {
            let encoded = try JSONEncoder().encode(provider)
            XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"\(provider.type)\"")
            XCTAssertEqual(try JSONDecoder().decode(BillingProvider.self, from: encoded), provider)
        }
    }

    func testJSONDecodeRejectsBareAdapty() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(BillingProvider.self, from: Data("\"adapty\"".utf8))
        )
    }

    // MARK: - Options default

    func testDefaultOptionsProviderIsStoreKit2() {
        XCTAssertEqual(AppDNAOptions().billingProvider.type, "storeKit2")
    }
}
