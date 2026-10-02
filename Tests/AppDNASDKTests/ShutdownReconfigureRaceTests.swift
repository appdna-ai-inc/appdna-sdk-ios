import XCTest
@testable import AppDNASDK

/// 🔴 `shutdown()` FOLLOWED BY `configure()` ON THE SAME TICK LEFT THE SDK DEAD FOR THE PROCESS.
///
/// `configure()` checks `isConfigured` synchronously under `initLock` and returns early if it is true.
/// `shutdown()` used to clear that flag ONLY inside its async teardown block. So the ordinary
/// sign-out→sign-in / React-Native-reload sequence —
///
///     AppDNA.shutdown()
///     AppDNA.configure(apiKey: …)   // same tick
///
/// ran `configure()` while the teardown was merely SCHEDULED: `isConfigured` was still true, the
/// configure was ignored with a log line, and then the teardown nilled everything. No event pipeline,
/// no billing, no managers, until the process restarted — and no `shutdown()` completion callback to
/// wait on, so a host could not even work around it.
///
/// This drives the exact back-to-back sequence a host issues and asserts the SDK comes back UP.
final class ShutdownReconfigureRaceTests: XCTestCase {

    /// The dropped-events counter as it was before this test (see `ShutdownUploadIsolation`).
    private var savedDropped = 0

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
    }

    override func tearDown() {
        AppDNA.resetInitStateForTesting()
        AppDNA.shutdown()
        waitUntil("torn down") { AppDNA.subsystemsUp()["events"] == false }
        ShutdownUploadIsolation.restore(savedDropped)
        super.tearDown()
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 30, _ cond: @escaping () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() >= deadline { return XCTFail("timed out: \(what)", file: file, line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testShutdownThenConfigureOnTheSameTickLeavesTheSDKConfigured() {
        // First configure + reach ready.
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        let up1 = expectation(description: "first configure ready")
        AppDNA.onReady { up1.fulfill() }
        wait(for: [up1], timeout: 30)

        // The sequence under test: shutdown() IMMEDIATELY followed by configure(), no thread hop, no
        // wait between them — exactly what a sign-out→sign-in handler does.
        AppDNA.shutdown()
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)

        // If the reconfigure was swallowed by the still-true `isConfigured`, `onReady` never fires again
        // and the SDK is dead. It must come back up.
        let up2 = expectation(description: "reconfigure after shutdown reached ready")
        AppDNA.onReady { up2.fulfill() }
        wait(for: [up2], timeout: 30)

        XCTAssertEqual(
            AppDNA.subsystemsUp()["events"], true,
            "shutdown() immediately before configure() swallowed the reconfigure — the SDK is dead"
        )
    }

    /// The mirror hazard the reconfigure fix introduced: now that `shutdown()` clears `isConfigured`
    /// synchronously, a `configure(); shutdown(); configure()` burst on ONE tick no longer no-ops the
    /// first configure — its `performConfigure` is scheduled and runs (serial-queue order
    /// Teardown → build1 → build2) right before the second's, with NO teardown between them. Since
    /// `performConfigure` rebuilds the pipeline, the `Transaction.updates` observer and the flush
    /// timers unconditionally, two back-to-back builds duplicate all of them. The `configureEpoch`
    /// guard must make the first, superseded build a no-op so exactly the latest configure wins.
    func testConfigureShutdownConfigureOnOneTickBuildsExactlyOnce() {
        AppDNA.resetPerformConfigureCountForTesting()

        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        AppDNA.shutdown()
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)

        let ready = expectation(description: "final configure reached ready")
        AppDNA.onReady { ready.fulfill() }
        wait(for: [ready], timeout: 30)

        XCTAssertEqual(
            AppDNA.subsystemsUp()["events"], true,
            "the final configure must leave the SDK up"
        )
        XCTAssertEqual(
            AppDNA.performConfigureCountForTesting, 1,
            "configure(); shutdown(); configure() built the SDK "
                + "\(AppDNA.performConfigureCountForTesting)× — the first, superseded build must be a "
                + "no-op (epoch guard). 2 means duplicate pipeline/observer/timers."
        )
    }
}
