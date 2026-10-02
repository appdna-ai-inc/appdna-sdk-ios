// UploadPauseBackgroundTests.swift
//
// The event queue's failure pause holds for the OS background uploader. Backgrounding a paused queue used to
// schedule the BGProcessingTask anyway, and the task never looked at the pause, so it uploaded exactly what the
// pause stops. Now backgrounding schedules nothing while paused, and a run that starts while paused (the pause
// is persisted in `UploadPauseGate`, so a run in a fresh process sees it) uploads nothing; a foreground or
// `AppDNA.flush()` clears it. Android `EventShutdownHandoffTest`, same contract; fixture
// `resilience/flush_pause_gate` (`os_upload`).
//
// NEGATIVE CONTROLS (build Mac, status file round 30): without the pause check in `enterBackground` the
// schedule runs; without `UploadPauseGate.set(true)` at the pause `uploadAllowed` stays true.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class UploadPauseBackgroundTests: XCTestCase {

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    override func tearDown() {
        EventQueue.scheduleBackgroundUploadForTesting = nil
        UploadPauseGate.set(false)
        super.tearDown()
    }

    private func makeQueue(_ store: EventStore) -> EventQueue {
        let tracker = EventTracker(identityManager: IdentityManager(
            keychainStore: KeychainStore(service: "ai.appdna.sdk.test.pausebg.\(UUID().uuidString)")))
        return EventQueue(apiClient: APIClient(apiKey: "adn_test_placeholder", environment: .sandbox),
                          eventStore: store, eventTracker: tracker, batchSizeCap: nil, flushInterval: 3600)
    }

    private func waitBriefly(_ seconds: TimeInterval = 1, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testAPausedQueueSchedulesNoBackgroundUploadAndTheBackgroundRunMayNotUpload() {
        let store = EventStore(fileName: "pause-bg-\(UUID().uuidString).json")
        defer { store.clearAll() }
        let scheduled = Counter()
        EventQueue.scheduleBackgroundUploadForTesting = { scheduled.bump() }
        let queue = makeQueue(store)
        XCTAssertTrue(BackgroundUploader.uploadAllowed, "a new queue starts unpaused")

        queue.pauseForTesting()
        XCTAssertFalse(BackgroundUploader.uploadAllowed, "a background run may upload while the queue is paused")
        queue.enterBackground(holdBackgroundTask: false)
        waitBriefly { scheduled.value > 0 }
        XCTAssertEqual(scheduled.value, 0, "backgrounding a paused queue scheduled the background upload")

        // A foreground (or `AppDNA.flush()`) clears the pause, and backgrounding schedules again.
        queue.flushClearingPause()
        waitBriefly { BackgroundUploader.uploadAllowed }
        XCTAssertTrue(BackgroundUploader.uploadAllowed, "the host's flush did not clear the persisted pause")
        queue.enterBackground(holdBackgroundTask: false)
        waitBriefly { scheduled.value > 0 }
        XCTAssertEqual(scheduled.value, 1)
    }
}
