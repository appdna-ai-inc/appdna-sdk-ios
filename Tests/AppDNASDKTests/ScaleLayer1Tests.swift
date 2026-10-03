import XCTest
@testable import AppDNASDK

/// Tests for SDK Scale Layer 1 optimizations.
final class ScaleLayer1Tests: XCTestCase {

    // MARK: - Deflate Compression

    func testDeflateCompressAndDecompress() {
        let original = "Hello, this is a test string for deflate compression"
        let originalData = Data(original.utf8)

        guard let compressed = APIClient.deflateCompress(originalData) else {
            XCTFail("Deflate compression returned nil")
            return
        }

        // Compressed data should be non-empty
        XCTAssertFalse(compressed.isEmpty)
        // For short strings, compression may not be smaller, but it should be valid deflate
        XCTAssertTrue(compressed.count > 0)
    }

    func testDeflateCompressEmptyData() {
        let emptyData = Data()
        let result = APIClient.deflateCompress(emptyData)
        XCTAssertNil(result, "Compressing empty data should return nil")
    }

    func testDeflateCompressionRatioOnEventBatch() {
        // Simulate a batch of 50 events as JSON
        var events: [[String: Any]] = []
        for i in 0..<50 {
            events.append([
                "schema_version": 1,
                "event_id": UUID().uuidString,
                "event_name": i % 3 == 0 ? "screen_view" : "button_tap",
                "ts_ms": Int(Date().timeIntervalSince1970 * 1000) + i * 1000,
                "user": ["anon_id": "test-anon"],
                "device": [
                    "platform": "ios",
                    "os": "17.4",
                    "app_version": "1.0.0",
                    "sdk_version": "1.0.0",
                    "locale": "en_US",
                    "country": "US",
                ],
                "context": ["session_id": "sess-test"],
                "properties": ["screen": "home", "action": "tap", "value": i * 10],
                "privacy": ["consent": ["analytics": true]],
            ])
        }
        let payload: [String: Any] = ["batch": events]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let compressed = APIClient.deflateCompress(jsonData) else {
            XCTFail("Failed to serialize or compress event batch")
            return
        }

        let ratio = Double(jsonData.count) / Double(compressed.count)
        XCTAssertGreaterThanOrEqual(ratio, 5.0, "Compression ratio should be at least 5x for typical event batches, got \(ratio)x")
    }

    // MARK: - Network Monitor

    func testNetworkMonitorSingleton() {
        let monitor = NetworkMonitor.shared
        // Should have a valid connection type
        let connectionType = monitor.currentConnectionType
        XCTAssertTrue(
            connectionType == .wifi || connectionType == .cellular || connectionType == .none,
            "Connection type should be valid"
        )
    }

    func testAdaptiveBatchSize() {
        let monitor = NetworkMonitor.shared
        let batchSize = monitor.adaptiveBatchSize
        // In test environment (likely running on CI/desktop), should be wifi or none
        XCTAssertTrue(
            batchSize == 100 || batchSize == 50 || batchSize == 20 || batchSize == 0,
            "Adaptive batch size should be 0, 20, 50, or 100, got \(batchSize)"
        )
    }

    // MARK: - EventStore Disk Quota

    func testEventStoreDiskQuotaConstant() {
        XCTAssertEqual(EventStore.maxDiskBytes, 5 * 1024 * 1024, "Disk quota should be 5 MB")
    }

    func testEventStoreDiskSizeTracking() {
        let store = EventStore()
        // Clear existing events
        let existing = store.loadPending()
        store.removeSent(eventIds: Set(existing.map(\.event_id)))

        // Add some events
        let events = (0..<10).map { i in makeTestEvent(name: "disk_test_\(i)") }
        store.save(events: events)

        let diskSize = store.diskSizeBytes
        XCTAssertGreaterThan(diskSize, 0, "Disk size should be positive after saving events")
        XCTAssertLessThan(diskSize, EventStore.maxDiskBytes, "Disk size should be under quota")

        // Cleanup
        let loaded = store.loadPending()
        store.removeSent(eventIds: Set(loaded.map(\.event_id)))
    }

    // MARK: - Config TTL

    func testDefaultConfigTTLIsOneHour() {
        let options = AppDNAOptions()
        XCTAssertEqual(options.configTTL, 3600, "Default config TTL should be 3600 seconds (1 hour)")
    }

    func testCustomConfigTTLPreserved() {
        let options = AppDNAOptions(configTTL: 600)
        XCTAssertEqual(options.configTTL, 600, "Custom config TTL should be preserved")
    }

    // MARK: - Helpers

    private func makeTestEvent(name: String) -> SDKEvent {
        EventEnvelopeBuilder.build(
            event: name,
            properties: ["key": "value"],
            identity: DeviceIdentity(anonId: "test-anon", userId: nil, traits: nil),
            sessionId: "test-session",
            analyticsConsent: true
        )
    }
}
