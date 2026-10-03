// EventStoreFaultTests.swift
//
// The pending-events file under the faults a device produces: a file that exists but cannot be read (a
// background launch before the first unlock, with the file under `completeUntilFirstUserAuthentication`), a
// file that cannot be opened for appending, a partial read, a write that never reaches the disk, and a process
// that dies between two writes. Faults are injected per file through `EventStore.faultsForTesting`.
//
// NEGATIVE CONTROLS (build Mac, patched sources — status file round 34):
//   - `testAnUnreadableFileIsNeverIndexedAsEmpty`: with the failed read indexing the file as empty (the old
//     `rebuildIndex`), the flush that empties the index truncates the backlog: 0 of the 30 events are left and
//     the dropped-events counter is 0 (an uncounted loss).
//   - `testALegacyArrayMigrationIsOneAtomicWrite`: with the old migration (truncate, then append), a process
//     that dies after its first write leaves an empty file: 0 of the 4 events.
//   - `testACompactionWhoseReadFailsDropsAndCountsNothing`: with the old compaction (count, then a rewrite that
//     gives up on a failed read), the counter is 5 after the failed compaction and 10 after the next one.
//   - `testAFailedOpenForAppendingNeverOverwritesTheFile`: with the old `.atomic` fallback, the file holds only
//     the one new event; the 20 before it are gone.
//
// © 2026 AppDNA AI, Inc.

import XCTest
@testable import AppDNASDK

final class EventStoreFaultTests: XCTestCase {

    private var files: [String] = []
    private var savedDropped = 0

    override func setUp() {
        super.setUp()
        savedDropped = DroppedEventsCounter.getAndReset()
        EventStore.faultsForTesting = EventStore.Faults()
    }

    override func tearDown() {
        EventStore.faultsForTesting = EventStore.Faults()
        for f in files { EventStore(fileName: f).clearAll() }
        files = []
        _ = DroppedEventsCounter.getAndReset()
        if savedDropped > 0 { DroppedEventsCounter.increment(savedDropped) }
        super.tearDown()
    }

    private func newFile(_ tag: String) -> String {
        let f = "fault-\(tag)-\(UUID().uuidString).json"
        files.append(f)
        return f
    }

    private func fileURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ai.appdna.sdk", isDirectory: true).appendingPathComponent(name)
    }

    private func backlog(_ n: Int) -> [SDKEvent] { EventStoreBacklogTests.backlog(n) }

    /// M1. A process starts while the file cannot be read: the index must not say "empty" for it. The new event
    /// is appended, the flush of that event removes nothing it cannot see, nothing truncates the file — and once
    /// the file can be read again, every event (the 30 before, the one after) is there.
    func testAnUnreadableFileIsNeverIndexedAsEmpty() {
        let file = newFile("unreadable")
        let before = backlog(30)
        EventStore(fileName: file).save(events: before)

        // A new process (the index is shared per file: forget it), and the file cannot be read.
        let store = EventStore(fileName: file)
        store.dropIndexForTesting()
        EventStore.faultsForTesting.failReads = [file]

        XCTAssertFalse(store.isFullyIndexedForTesting)
        let next = EventStoreBacklogTests.event("while_locked")
        store.save(events: [next])
        XCTAssertFalse(store.isFullyIndexedForTesting, "a store that could not read its file claims to know it")
        // The queue sent the new event: its removal must not empty — truncate — the file.
        store.removeSent(eventIds: [next.event_id])
        store.pruneStale()
        XCTAssertGreaterThan(store.diskSizeBytes, 0, "the unread backlog was truncated")

        // The device is unlocked: the file is read again, in full.
        EventStore.faultsForTesting.failReads = []
        let pending = store.loadPending().map(\.event_id)
        XCTAssertTrue(store.isFullyIndexedForTesting)
        for e in before { XCTAssertTrue(pending.contains(e.event_id), "an event queued before the locked launch was lost") }
        XCTAssertEqual(pending.count, 31, "the 30 events before, and the one appended while locked (sent again: deduplicated server-side)")
        XCTAssertEqual(DroppedEventsCounter.peek(), 0)
    }

    /// M1, the compaction half: while the file is unreadable, the caps cannot rewrite it from a partial index.
    func testAnUnreadableFileIsNeverCompacted() {
        let file = newFile("unreadable-compact")
        EventStore(fileName: file).save(events: backlog(30))
        let store = EventStore(maxEvents: 5, compactionInterval: 1, fileName: file)
        store.dropIndexForTesting()
        EventStore.faultsForTesting.failReads = [file]
        store.save(events: backlog(6))   // over the cap of the partial index: no compaction may run
        XCTAssertEqual(DroppedEventsCounter.peek(), 0, "a compaction ran on a file it had not read")
        EventStore.faultsForTesting.failReads = []
        XCTAssertEqual(EventStore(fileName: file).loadPending().count, 36)
    }

    /// Minor 1. An older SDK's JSON-array file is rewritten in ONE atomic write: a process that dies right
    /// after its first write keeps every event.
    func testALegacyArrayMigrationIsOneAtomicWrite() throws {
        let file = newFile("legacy-crash")
        let events = backlog(4)
        try JSONEncoder().encode(events).write(to: fileURL(file))
        let store = EventStore(fileName: file)
        store.dropIndexForTesting()
        EventStore.faultsForTesting.writesAllowed = [file: 1]   // the process dies after its first write
        _ = store.pendingCount
        EventStore.faultsForTesting.writesAllowed = [:]
        store.dropIndexForTesting()                              // the next launch
        XCTAssertEqual(store.loadPending().map(\.event_id), events.map(\.event_id),
                       "a crash during the legacy migration lost events")
        XCTAssertEqual(try Data(contentsOf: fileURL(file)).first, UInt8(ascii: "{"), "the file is NDJSON now")
    }

    /// Minor 1, the mixed file: lines this SDK appended after an array it had not migrated yet are kept.
    func testALegacyArrayFollowedByLinesIsMigratedWithThem() throws {
        let file = newFile("legacy-mixed")
        let events = backlog(3)
        let appended = backlog(2)
        var blob = try JSONEncoder().encode(events)
        blob.append(0x0A)
        for e in appended { blob.append(try JSONEncoder().encode(e)); blob.append(0x0A) }
        try blob.write(to: fileURL(file))
        let store = EventStore(fileName: file)
        store.dropIndexForTesting()
        XCTAssertEqual(store.loadPending().map(\.event_id), (events + appended).map(\.event_id))
    }

    /// Minor 4. A compaction whose read fails drops nothing and counts nothing; the next one drops and counts
    /// the same events once.
    func testACompactionWhoseReadFailsDropsAndCountsNothing() {
        let file = newFile("compact-read")
        let store = EventStore(maxEvents: 10, compactionInterval: 1, fileName: file)
        let events = backlog(10)
        store.save(events: events)
        EventStore.faultsForTesting.failRangeReads = [file]
        store.save(events: backlog(5))                         // 15 > 10: a compaction that cannot read
        XCTAssertEqual(DroppedEventsCounter.peek(), 0, "a compaction that dropped nothing counted a loss")
        EventStore.faultsForTesting.failRangeReads = []
        store.save(events: [EventStoreBacklogTests.event("next")]) // 16 > 10: the compaction that can
        XCTAssertEqual(DroppedEventsCounter.peek(), 6, "the 6 dropped events must be counted exactly once")
        XCTAssertEqual(store.pendingCount, 10)
    }

    /// Minor 4, the write half: a rewrite that never reaches the disk gives the count back.
    func testACompactionWhoseWriteFailsGivesTheCountBack() {
        let file = newFile("compact-write")
        let store = EventStore(maxEvents: 10, compactionInterval: 1, fileName: file)
        store.save(events: backlog(10))
        EventStore.faultsForTesting.writesAllowed = [file: 1]  // the append lands, the rewrite does not
        store.save(events: backlog(3))
        XCTAssertEqual(DroppedEventsCounter.peek(), 0, "a rewrite that failed left its loss counted")
        EventStore.faultsForTesting.writesAllowed = [:]
        store.save(events: [EventStoreBacklogTests.event("next")])
        XCTAssertEqual(DroppedEventsCounter.peek(), 4)
        XCTAssertEqual(store.pendingCount, 10)
    }

    /// Minor 6. Opening the file for appending fails while it exists: nothing may overwrite it (the fallback
    /// used to write the new lines over the whole file).
    func testAFailedOpenForAppendingNeverOverwritesTheFile() {
        let file = newFile("open-fails")
        let store = EventStore(fileName: file)
        let before = backlog(20)
        store.save(events: before)
        EventStore.faultsForTesting.failWriteHandle = [file]
        store.save(events: [EventStoreBacklogTests.event("not_appended")])
        EventStore.faultsForTesting.failWriteHandle = []
        store.dropIndexForTesting()
        XCTAssertEqual(store.loadPending().map(\.event_id), before.map(\.event_id),
                       "a failed open for appending replaced the file")
        // And the next append works again.
        let next = EventStoreBacklogTests.event("appended")
        store.save(events: [next])
        store.dropIndexForTesting()
        XCTAssertEqual(store.loadPending().last?.event_id, next.event_id)
    }

    /// Minor 6. A file that does not exist yet is still created by the first append.
    func testTheFirstAppendCreatesTheFile() {
        let file = newFile("create")
        let store = EventStore(fileName: file)
        EventStore.faultsForTesting.failWriteHandle = [file]   // no handle on a file that is not there
        let first = EventStoreBacklogTests.event("first")
        store.save(events: [first])
        EventStore.faultsForTesting.failWriteHandle = []
        store.dropIndexForTesting()
        XCTAssertEqual(store.loadPending().map(\.event_id), [first.event_id])
    }

    /// Minor 9 (iOS half). The quota measures the live events' bytes and evicts the oldest 10 % until they fit.
    func testTheDiskQuotaCapsTheLiveBytes() {
        let file = newFile("quota")
        let store = EventStore(compactionInterval: 10_000, fileName: file, maxDiskBytes: 20_000)
        let events = backlog(60)
        for e in events { store.save(events: [e]) }
        XCTAssertLessThanOrEqual(store.liveBytesForTesting, 20_000)
        XCTAssertGreaterThan(store.liveBytesForTesting, 16_000, "evicted far more than the quota needs")
        let left = store.loadPending().map(\.event_id)
        XCTAssertEqual(left, Array(events.suffix(left.count)).map(\.event_id), "the survivors are the newest")
        XCTAssertEqual(DroppedEventsCounter.peek(), 60 - left.count)
    }
}
