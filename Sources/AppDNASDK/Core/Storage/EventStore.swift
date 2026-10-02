import Foundation

/// File-based event persistence in Application Support directory.
/// Ensures events survive app termination.
///
/// SPEC-067: Enforces both event count cap (10K) and disk quota (5 MB).
/// SPEC-428 CL-8/D8: storage is an APPEND-LOG (NDJSON — one event per line). `save()` appends in
/// O(1) amortized instead of the old O(n) full-file decode+append+encode on every `track()` (a
/// battery/CPU cliff at scale). Caps are enforced by periodic compaction, amortizing the O(n) rewrite.
final class EventStore {
    /// ONE serial queue per store FILE, shared by every `EventStore` on it — not one per instance.
    ///
    /// `shutdown(); configure()` builds a new `EventStore` on the same file while the old queue's last
    /// upload is still in flight; `BackgroundUploader` holds another. With a queue each, the old store's
    /// `removeSent` (read the file, filter, rewrite it) could run between the new store's append and its
    /// return, and the rewrite dropped the event the new store had just appended. Every read-modify-write
    /// of one file now runs on that file's queue, whichever instance asks.
    private static let queuesLock = NSLock()
    private static var queuesByPath: [String: DispatchQueue] = [:]
    static func sharedQueue(for url: URL) -> DispatchQueue {
        queuesLock.lock(); defer { queuesLock.unlock() }
        let key = url.standardizedFileURL.path
        if let q = queuesByPath[key] { return q }
        let q = DispatchQueue(label: "ai.appdna.sdk.eventstore.\(url.lastPathComponent)")
        queuesByPath[key] = q
        return q
    }

    private let queue: DispatchQueue
    private let fileURL: URL
    private let maxEvents: Int
    /// SPEC-067: Maximum disk usage for event storage (5 MB).
    static let maxDiskBytes = 5 * 1024 * 1024
    /// SPEC-428 CL-8: compact (enforce caps by rewriting) at most every N appends → amortized O(1).
    private let compactionInterval: Int
    private var appendsSinceCompaction = 0

    /// SPEC-428: `maxEvents`/`compactionInterval`/`fileName` are injectable so the shared behavioral
    /// fixtures (`events/` category) can drive eviction at a small cap with a clean, isolated store.
    /// Production callers use the defaults (10k cap / compact-every-500 / the canonical file).
    init(maxEvents: Int = 10_000, compactionInterval: Int = 500, fileName: String = "pending_events.json") {
        self.maxEvents = maxEvents
        self.compactionInterval = compactionInterval
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
        let dir = base.appendingPathComponent("ai.appdna.sdk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.excludeFromBackup(dir)
        self.fileURL = dir.appendingPathComponent(fileName)
        self.queue = Self.sharedQueue(for: self.fileURL)
    }

    /// Marks the SDK's storage directory as excluded from iCloud/iTunes backup.
    ///
    /// The pending-event log is plaintext NDJSON containing whatever properties
    /// and traits the host chose to send. Application Support is backed up by
    /// default, so without this the queue is copied into the user's iCloud backup.
    /// Setting the flag on the directory covers every file we create inside it.
    ///
    /// Idempotent: safe to call on every `EventStore` init.
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            // Non-fatal: the directory may not exist yet on a first-run race, or the
            // volume may not support the attribute. Never block event storage on it.
            Log.warning("Could not exclude SDK storage from backup: \(error.localizedDescription)")
        }
    }

    /// Returns the current disk size of the event store file in bytes.
    var diskSizeBytes: Int {
        queue.sync { fileSize() }
    }

    /// SPEC-428 CL-8/D8: O(1) amortized append (was O(n) full read-modify-write per event). Caps are
    /// enforced by a periodic compaction (every `compactionInterval` appends, or immediately once the
    /// on-disk log exceeds the disk quota — a cheap O(1) size check).
    func save(events: [SDKEvent]) {
        queue.sync {
            appendToDisk(events)
            appendsSinceCompaction += events.count
            if appendsSinceCompaction >= self.compactionInterval || fileSize() > Self.maxDiskBytes {
                compact()
            }
        }
    }

    /// Load all pending (unsent) events from disk.
    func loadPending() -> [SDKEvent] {
        queue.sync { loadFromDisk() }
    }

    /// Remove sent events by their IDs. O(n) rewrite — but flush is batch-level, not per-track.
    func removeSent(eventIds: Set<String>) {
        queue.sync {
            var existing = loadFromDisk()
            existing.removeAll { eventIds.contains($0.event_id) }
            writeToDisk(existing)
            appendsSinceCompaction = 0
        }
    }

    /// SPEC-428 CL-2/D5: the client redelivery horizon. Compiled default 7d, tracking SPEC-426's horizon.
    static let redeliveryHorizonMs: Int64 = 7 * 24 * 60 * 60 * 1000

    /// SPEC-428 CL-2/D5: drop events past the redelivery horizon so NO consumer re-sends an event past the
    /// server dedup window (double-count). This lives at the STORE so EVERY load path is protected — the
    /// in-process flush AND the background BGTask/WorkManager uploaders that "fire hours/days later" (the
    /// paths STEP-5 named). Counted (CL-1). Returns the number dropped.
    /// SPEC-070-B PN row 19 (W14) — an age past this is not a stale event, it is a broken clock.
    /// The horizon compares wall clocks, so a forward clock jump makes every queued event look older
    /// than 7 days at once and prunes it **unsent**. Beyond this bound, and for any negative age (the
    /// clock moved backwards), we keep the event: a retained event costs a retry, a pruned one is
    /// gone. 30 days is ~4x the horizon — comfortably past a genuine long-offline device, well short
    /// of the year-scale jumps a wrong RTC produces.
    static let implausibleAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// True when `event` is genuinely past the horizon, as opposed to a victim of a clock jump.
    static func isStale(tsMs: Int64, nowMs: Int64, horizonMs: Int64) -> Bool {
        let age = nowMs - tsMs
        guard age > horizonMs else { return false }
        return age <= implausibleAgeMs
    }

    @discardableResult
    func pruneStale(horizonMs: Int64 = EventStore.redeliveryHorizonMs) -> Int {
        queue.sync {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let existing = loadFromDisk()
            let stale = existing.filter { Self.isStale(tsMs: $0.ts_ms, nowMs: nowMs, horizonMs: horizonMs) }
            guard !stale.isEmpty else { return 0 }
            let staleIds = Set(stale.map(\.event_id))
            writeToDisk(existing.filter { !staleIds.contains($0.event_id) })
            appendsSinceCompaction = 0
            // SPEC-428 STEP-4: count the loss meta-aware — 1 per normal event, but the carried N for an
            // evicted `_sdk_events_dropped` meta (so a meta aged past the horizon doesn't lose its N).
            var lost = 0
            for e in stale {
                if e.event_name == "_sdk_events_dropped" {
                    lost += (e.properties?["count"]?.value as? Int) ?? 0
                } else {
                    lost += 1
                }
            }
            if lost > 0 { DroppedEventsCounter.increment(lost) }
            Log.warning("Pruned \(stale.count) events past the redelivery horizon (loss metric +\(lost))")
            return stale.count
        }
    }

    /// SPEC-424 STEP-1a (CL-7): purge ALL persisted events WITHOUT uploading them — analytics
    /// consent was revoked, so queued-but-unsent events must never be transmitted.
    func clearAll() {
        queue.sync {
            writeToDisk([])
            appendsSinceCompaction = 0
        }
    }

    // MARK: - Private

    private func fileSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    }

    /// SPEC-428 CL-8: parse the NDJSON log (one event per line). A crash mid-append can leave a
    /// trailing partial line — unparseable lines are skipped, so the log is self-healing. Back-compat:
    /// an older single-JSON-array file decodes via the array path (then the next compaction rewrites
    /// it as NDJSON).
    private func loadFromDisk() -> [SDKEvent] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        if let arr = try? JSONDecoder().decode([SDKEvent].self, from: data) { return arr }
        let decoder = JSONDecoder()
        var events: [SDKEvent] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let ev = try? decoder.decode(SDKEvent.self, from: Data(line)) { events.append(ev) }
        }
        return events
    }

    /// SPEC-428 CL-8: append events as NDJSON lines (O(1) — seek to end + write). Creates the file on
    /// first write.
    private func appendToDisk(_ events: [SDKEvent]) {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        var blob = Data()
        for event in events {
            guard let data = try? encoder.encode(event) else { continue }
            blob.append(data)
            blob.append(0x0A) // '\n'
        }
        guard !blob.isEmpty else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(blob)
        } else {
            // File doesn't exist yet — create it atomically with these lines.
            try? blob.write(to: fileURL, options: .atomic)
        }
    }

    /// Full rewrite as NDJSON (atomic). Used by compaction / removeSent / clearAll.
    private func writeToDisk(_ events: [SDKEvent]) {
        let encoder = JSONEncoder()
        var blob = Data()
        for event in events {
            guard let data = try? encoder.encode(event) else { continue }
            blob.append(data)
            blob.append(0x0A)
        }
        try? blob.write(to: fileURL, options: .atomic)
    }

    /// SPEC-428 CL-8: compaction enforces the count + disk caps by rewriting the log — the amortized
    /// O(n) work, run at most every `compactionInterval` appends. Dropped events are counted (CL-1).
    private func compact() {
        var events = loadFromDisk()
        let original = events
        let originalCount = events.count
        if events.count > self.maxEvents {
            events = Array(events.suffix(self.maxEvents))
        }
        writeToDisk(events)

        // SPEC-067: disk-quota — drop oldest 10% until under limit.
        while fileSize() > Self.maxDiskBytes && !events.isEmpty {
            let dropCount = max(events.count / 10, 1)
            events = Array(events.dropFirst(dropCount))
            writeToDisk(events)
        }

        let droppedCount = originalCount - events.count
        if droppedCount > 0 {
            // SPEC-428 STEP-4: never UNDER-count the loss metric. All drops are from the FRONT (oldest), so
            // the evicted set is the prefix. For a normal event count 1; for an evicted `_sdk_events_dropped`
            // META event, RECOVER the N drops it carried (they were already reset to 0 when it was composed,
            // so evicting it before delivery would otherwise lose them) — re-adding N re-emits them later.
            let evicted = original.prefix(droppedCount)
            var lost = 0
            for e in evicted {
                if e.event_name == "_sdk_events_dropped" {
                    lost += (e.properties?["count"]?.value as? Int) ?? 0
                } else {
                    lost += 1
                }
            }
            if lost > 0 { DroppedEventsCounter.increment(lost) } // CL-1/D2: count the loss (never silent)
            Log.warning("Event store compaction dropped \(droppedCount) oldest events (loss metric +\(lost))")
        }
        appendsSinceCompaction = 0
    }
}

/// SPEC-428 CL-1/D2 — durable counter of events dropped by a cap/quota eviction. Persisted in
/// UserDefaults so a restart never loses the count; drained by EventTracker into a
/// `_sdk_events_dropped` meta-event so the loss is SERVER-VISIBLE, not a silent Log.warning.
enum DroppedEventsCounter {
    private static let key = "ai.appdna.sdk.dropped_events"
    private static let lock = NSLock()

    static func increment(_ n: Int) {
        guard n > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let current = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(current + n, forKey: key)
    }

    /// Atomically read + reset. Test helper (fixtures read the accrued count); production uses
    /// peek()+subtract() so the count is only removed AFTER the meta is durable (STEP-4).
    static func getAndReset() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = UserDefaults.standard.integer(forKey: key)
        if current > 0 { UserDefaults.standard.set(0, forKey: key) }
        return current
    }

    /// SPEC-428 STEP-4: read WITHOUT resetting. The count is only removed (subtract) AFTER the
    /// `_sdk_events_dropped` meta carrying it is DURABLY persisted — so a hard kill before the meta lands
    /// re-emits it (never an UNDER-count, which STEP-4 forbids). A concurrent peek may double-emit
    /// (over-count, direction-safe — the spec prioritizes never-under-count).
    static func peek() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.integer(forKey: key)
    }

    /// SPEC-428 STEP-4: atomic DECREMENT-by-N (floored at 0), called once the meta carrying N is durable.
    static func subtract(_ n: Int) {
        guard n > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let current = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(max(0, current - n), forKey: key)
    }
}
