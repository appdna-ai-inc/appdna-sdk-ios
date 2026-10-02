import XCTest
@testable import AppDNASDK

/**
 SPEC-070-B W13 / AC-31(b) — *"injecting a paywall/onboarding subsystem init failure leaves ANALYTICS
 WORKING: events still enqueue and land."*

 ## What was missing

 iOS has had `initSubsystem` wired into `configure()` for five subsystems since PN row 17. What it did
 NOT have was a test that ran a `configure()` with a failure injected. `Spec070BNativeAdditionsTests`
 tests the helper IN ISOLATION — it calls `AppDNA.initSubsystem("paywall") { "built" }` and checks the
 return is nil and the error was reported. AC-31(b) rules on exactly that: *"AC-31(a) asserts only that
 the error is surfaced; that is not isolation."* Nothing on this platform had ever asserted that the
 event pipeline survives, because nothing on this platform had ever run a real `configure()`.

 Android proves it end to end (`SubsystemInitIsolationTest.kt` — "every subsystem failing at once still
 leaves a configured, tracking SDK"): it asserts `up["events"]` and then drives `AppDNA.track`. This is
 the iOS twin, and it drives the REAL `configure()` through the same `subsystemInitFailures` seam.

 Analytics is the floor guarantee. The tracker and the queue are wired in `performConfigure` BEFORE any
 subsystem is constructed; a paywall that cannot start must cost the host its paywall and nothing else.

 ## ⚠ Process-global state

 `AppDNA` is a singleton and these tests drive the real `configure()`/`shutdown()`. Every one of them
 tears the SDK back down and waits for the teardown to actually land on the SDK's serial queue —
 `shutdown()` is asynchronous, and returning from it does NOT mean it has run. A test that skipped that
 wait would leave the next `configure()` rejected by the double-configure guard, and the failure would
 surface in some other file.
 */
final class SubsystemInitIsolationTests: XCTestCase {

    /// The dropped-events counter as it was before this test (see `ShutdownUploadIsolation`).
    private var savedDropped = 0

    override func setUp() {
        super.setUp()
        savedDropped = ShutdownUploadIsolation.save()
    }

    override func tearDown() {
        super.tearDown()
        AppDNA.subsystemInitFailures = []
        AppDNA.resetInitStateForTesting()
        AppDNA.shutdown()
        // `shutdown()` hops onto the SDK's serial queue. Wait for it to actually take effect, or the
        // next `configure()` — here or in another file — is silently ignored by the isConfigured guard.
        waitUntil("the SDK is torn down") { AppDNA.subsystemsUp()["events"] == false }
        ShutdownUploadIsolation.restore(savedDropped)
    }

    /// Poll a condition on the main run loop. Not a sleep: it returns as soon as the condition holds.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 30,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return XCTFail("timed out after \(timeout)s waiting for: \(what)", file: file, line: line)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Configure the real SDK with the named subsystems failing, and wait until it is ready.
    ///
    /// `onReady` fires from BOTH exits of `performBootstrap` — success and failure — so this settles
    /// with or without a network. A test host has no API key, so the bootstrap will fail; that is
    /// exactly the degraded launch every offline user has, and the managers are wired either way.
    private func configureWith(failing: Set<String>) {
        AppDNA.subsystemInitFailures = failing
        AppDNA.configure(apiKey: "adn_test_placeholder", environment: .sandbox)
        // 🔴 WAIT FOR THE SDK'S OWN READY SIGNAL, NOT FOR ONE SUBSYSTEM.
        //
        // This used to wait for `subsystemsUp()["events"] == true`. The event tracker is built EARLY
        // in `configure()` — the paywall, onboarding, message, survey and web-entitlement managers are
        // assigned AFTER it. So the wait returned while those five were still nil, and every assertion
        // about them read `false` no matter which subsystem had been injected.
        //
        // It looked exactly like an isolation bug — "a failing paywall takes onboarding with it" —
        // and it was a race in the test. The init chain IS isolated: each `initSubsystem` closure
        // takes only locals, so no subsystem can drop another. I checked before believing the test.
        //
        // `isReady` is set at the END of `initializeManagers`, after every manager is assigned
        // (`check:onready-semantics` pins that, and pins that `initializeManagers` is reachable only
        // from `performBootstrap`). It is the SDK's own answer to "am I built yet", so it is the only
        // honest thing to wait on.
        let ready = expectation(description: "configure() finished building every subsystem")
        AppDNA.onReady { ready.fulfill() }
        wait(for: [ready], timeout: 30)
    }

    /// Track an event and return the envelope the pipeline actually built for it, or nil.
    ///
    /// The oracle is `EventTracker.eventSink`, which fires on ENQUEUE — so this observes the event
    /// reaching the queue, not merely `track()` returning without throwing. `AppDNA.track` is async
    /// (it hops onto the SDK queue), hence the expectation.
    private func trackAndCapture(_ event: String) -> SDKEvent? {
        guard let tracker = AppDNA.eventTrackerForTesting else {
            XCTFail("no EventTracker after configure() — the event pipeline never came up at all")
            return nil
        }
        var captured: SDKEvent?
        let landed = expectation(description: "the event reaches the queue")
        tracker.eventSink = { ev in
            guard ev.event_name == event else { return }   // ignore sdk_initialized et al
            captured = ev
            landed.fulfill()
        }
        defer { tracker.eventSink = nil }

        AppDNA.track(event: event, properties: ["k": "v"])
        wait(for: [landed], timeout: 10)
        return captured
    }

    // MARK: - One subsystem down

    func testAFailingPaywallLeavesAnalyticsWorking() {
        configureWith(failing: ["paywall"])

        let up = AppDNA.subsystemsUp()
        XCTAssertEqual(up["paywall"], false, "the failing subsystem must not produce an instance")

        // Everything constructed AFTER the paywall still came up: the failure is contained, not fatal.
        XCTAssertEqual(up["onboarding"], true, "onboarding is built after the paywall and must survive it")
        XCTAssertEqual(up["surveys"], true)
        XCTAssertEqual(up["web_entitlements"], true)

        // …and the floor guarantee.
        XCTAssertEqual(up["events"], true, "the event pipeline must survive any subsystem failure")
        let ev = trackAndCapture("post_paywall_failure_event")
        XCTAssertNotNil(ev, "the event never reached the queue — a broken paywall took analytics with it")
        XCTAssertEqual(ev?.properties?["k"]?.value as? String, "v", "the envelope was built, but empty")
    }

    func testAFailingOnboardingLeavesAnalyticsWorking() {
        configureWith(failing: ["onboarding"])

        let up = AppDNA.subsystemsUp()
        XCTAssertEqual(up["onboarding"], false)
        XCTAssertEqual(up["paywall"], true, "the paywall is built BEFORE onboarding and must be untouched")
        XCTAssertEqual(up["events"], true)
        XCTAssertNotNil(trackAndCapture("post_onboarding_failure_event"))
    }

    // MARK: - Every subsystem down at once

    /// 🔴 THE FAILING SET IS DERIVED FROM THE SDK, NOT HARD-CODED.
    ///
    /// It used to be a literal list of five names. So "every subsystem" quietly meant "these five", and a
    /// subsystem added later was simply never injected — the test kept passing, and kept claiming
    /// coverage it did not have.
    ///
    /// That is exactly what happened with `billing`: it was built by a bare `switch` OUTSIDE
    /// `initSubsystem`, so it could not be isolated or injected at all, and `subsystemsUp()` had no
    /// `billing` key to report it with. Two blind spots lining up to look like green. The moment the key
    /// existed, this test failed with `["billing"] is not equal to []` — the subsystem that had never
    /// been in the seam.
    ///
    /// Deriving the set from `subsystemsUp()` means the next subsystem is injected the day it is
    /// reportable, without anyone remembering to add it here.
    func testEverySubsystemFailingAtOnceStillLeavesATrackingSDK() {
        // `events` is the floor guarantee, not a failable subsystem — it is the thing that must survive.
        let everySubsystem = Set(AppDNA.subsystemsUp().keys).subtracting(["events"])
        XCTAssertGreaterThan(everySubsystem.count, 4, "the SDK reports suspiciously few subsystems")

        configureWith(failing: everySubsystem)

        let up = AppDNA.subsystemsUp()
        XCTAssertEqual(
            up.filter { $0.key != "events" && $0.value }.keys.sorted(), [],
            "no subsystem should have come up"
        )
        XCTAssertEqual(up["events"], true, "analytics is the floor guarantee and must still be up")

        // The host's own analytics keep working — which is the entire claim of AC-31(b).
        let ev = trackAndCapture("everything_broken_but_analytics")
        XCTAssertNotNil(ev, "with every subsystem down, the SDK stopped tracking — the failure was NOT isolated")
        XCTAssertEqual(ev?.event_name, "everything_broken_but_analytics")
    }

    // MARK: - …and the failure is still surfaced (AC-31(a)), not swallowed by the isolation

    func testTheFailureIsReportedAsDegradedRatherThanSwallowed() {
        final class Spy: AppDNAInitDelegate {
            var seen: [Error] = []
            func onInitDegraded(reason: Error) { seen.append(reason) }
        }
        let spy = Spy()
        AppDNA.initDelegate = spy

        configureWith(failing: ["surveys"])

        // The delegate is notified on the main queue.
        waitUntil("the host's init delegate is told which subsystem degraded") {
            spy.seen.contains { error in
                guard let e = error as? AppDNAInitError,
                      case .subsystemFailed(let name, _) = e else { return false }
                return name == "surveys"
            }
        }
        XCTAssertEqual(AppDNA.subsystemsUp()["surveys"], false)
        XCTAssertEqual(AppDNA.subsystemsUp()["events"], true)
    }
}
