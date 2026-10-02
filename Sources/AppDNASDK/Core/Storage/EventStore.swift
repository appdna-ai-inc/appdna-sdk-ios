import Foundation

/// File-based event persistence in Application Support directory.
/// Ensures events survive app termination.
///
/// SPEC-067: Enforces both event count cap (10K) and disk quota (5 MB).
/// SPEC-428 CL-8/D8: storage is an APPEND-LOG (NDJSON — one event per line). `save()` appends in
/// O(1) amortized instead of the old O(n) full-file decode+append+encode on every `track()` (a
/// battery/CPU cliff at scale). Caps are enforced by periodic compaction, amortizing the O(n) rewrite.
///
/// A flush costs what its batch costs, not what the backlog costs. Every store on one file shares one
/// in-memory INDEX of that file (`FileState`: each line's `event_id`, `ts_ms`, byte range, and the carried
/// count of a `_sdk_events_dropped` meta), built once per process from a light per-line decode. With it:
///   - `pruneStale` reads timestamps from the index (no decode; O(1) when nothing can be stale);
///   - `removeSent` appends ONE removal record (`{"appdna_removed":[ids]}`) instead of decoding and
///     rewriting the whole file;
///   - `loadOldest` / `loadNewest` decode only the lines they return; `pendingCount` decodes nothing.
/// Removed and pruned lines stay in the file as dead bytes until a compaction copies the live lines' raw
/// bytes into a fresh file (no JSON work). Compaction runs only when it has something to do — the caps are
/// exceeded, or the dead bytes pass `deadBytesSlack` (or outweigh the live ones) — so its O(file) cost is
/// amortized over many flushes. Before this, every flush decoded the whole file twice (prune, then the
/// removal's read-filter-rewrite), and since all stores on one file share a serial queue, a
/// `shutdown(); configure()` pair waited 15–30 s behind the old queue's last flush on a 10,000-event file.
///
/// The index tracks the file it was built from (size, modification date, file number). Anything else that
/// changes the file — a test deleting it, a crash between our write and our bookkeeping — makes the next
/// operation rebuild it, so the index never answers for a file it did not read.
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
    private static var statesByPath: [String: FileState] = [:]
    static func sharedQueue(for url: URL) -> DispatchQueue {
        queuesLock.lock(); defer { queuesLock.unlock() }
        let key = url.standardizedFileURL.path
        if let q = queuesByPath[key] { return q }
        let q = DispatchQueue(label: "ai.appdna.sdk.eventstore.\(url.lastPathComponent)")
        queuesByPath[key] = q
        return q
    }

    /// The one index of a file, shared like its queue. Only ever touched on that queue.
    private static func sharedState(for url: URL) -> FileState {
        queuesLock.lock(); defer { queuesLock.unlock() }
        let key = url.standardizedFileURL.path
        if let s = statesByPath[key] { return s }
        let s = FileState()
        statesByPath[key] = s
        return s
    }

    private let queue: DispatchQueue
    private let state: FileState
    private let fileURL: URL
    private let maxEvents: Int
    /// SPEC-067: Maximum disk usage for event storage (5 MB).
    static let maxDiskBytes = 5 * 1024 * 1024
    /// Removed / pruned lines the file may carry before a compaction reclaims them. The 5 MB quota caps the
    /// LIVE events; the file can be up to this much larger between compactions. A compaction also runs once
    /// the dead bytes outweigh the live ones (and pass `minDeadBytesToCompact`), so a small queue's file
    /// stays small.
    static let deadBytesSlack = 1024 * 1024
    static let minDeadBytesToCompact = 64 * 1024
    /// SPEC-428 CL-8: compact (enforce caps by rewriting) at most every N appends → amortized O(1).
    private let compactionInterval: Int

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
        self.state = Self.sharedState(for: self.fileURL)
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
        queue.sync { Int(Self.signature(of: fileURL)?.size ?? 0) }
    }

    /// The number of pending (unsent) events. Decodes nothing.
    var pendingCount: Int {
        queue.sync {
            ensureIndexed()
            return state.liveCount
        }
    }

    /// SPEC-428 CL-8/D8: O(1) amortized append (was O(n) full read-modify-write per event). Caps are
    /// enforced by a compaction (every `compactionInterval` appends, or immediately once the live events
    /// pass the disk quota — an O(1) check on the index), which rewrites only when a cap is exceeded or the
    /// dead bytes call for it.
    func save(events: [SDKEvent]) {
        queue.sync {
            ensureIndexed()
            appendEvents(events)
            state.appendsSinceCompaction += events.count
            if state.appendsSinceCompaction >= self.compactionInterval
                || state.liveBytes > Self.maxDiskBytes
                || state.fileLength > Self.maxDiskBytes + Self.deadBytesSlack {
                compact()
            }
        }
    }

    /// Load all pending (unsent) events from disk, oldest first. Decodes every pending line — the event
    /// queue and the background uploader use `loadNewest` / `loadOldest`, which decode only what they take.
    func loadPending() -> [SDKEvent] {
        queue.sync {
            ensureIndexed()
            return decodeLive(state.liveIndices())
        }
    }

    /// The `limit` oldest pending events (the background uploader's batch). Decodes only those lines.
    func loadOldest(_ limit: Int) -> [SDKEvent] {
        queue.sync {
            ensureIndexed()
            return decodeLive(state.liveIndices(oldest: limit))
        }
    }

    /// The `limit` newest pending events, oldest first (the event queue's in-memory window). Decodes only
    /// those lines.
    func loadNewest(_ limit: Int) -> [SDKEvent] {
        queue.sync {
            ensureIndexed()
            return decodeLive(state.liveIndices(newest: limit))
        }
    }

    /// Remove sent events by their IDs: one appended removal record, O(batch) — not a rewrite of the file.
    func removeSent(eventIds: Set<String>) {
        queue.sync {
            ensureIndexed()
            let removed = markDead(ids: eventIds)
            guard !removed.isEmpty else { return }
            appendRemovalRecord(removed)
            reclaimDeadBytesIfNeeded()
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

    /// Reads the timestamps from the index — no decode. When even the oldest timestamp the index has seen
    /// is inside the horizon, nothing can be stale and it returns without looking at a line.
    @discardableResult
    func pruneStale(horizonMs: Int64 = EventStore.redeliveryHorizonMs) -> Int {
        queue.sync {
            ensureIndexed()
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            // `minLiveTsMs` is a lower bound of every live timestamp: nothing older than the horizon → done.
            guard state.liveCount > 0, state.minLiveTsMs < nowMs - horizonMs else { return 0 }
            var staleIds: Set<String> = []
            var staleLines = 0
            var lost = 0
            var newMin = Int64.max
            for i in state.liveIndices() {
                let line = state.lines[i]
                if Self.isStale(tsMs: line.tsMs, nowMs: nowMs, horizonMs: horizonMs) {
                    staleIds.insert(line.eventId)
                    staleLines += 1
                    // SPEC-428 STEP-4: count the loss meta-aware — 1 per normal event, but the carried N for an
                    // evicted `_sdk_events_dropped` meta (so a meta aged past the horizon doesn't lose its N).
                    lost += line.metaCount ?? 1
                } else {
                    newMin = min(newMin, line.tsMs)
                }
            }
            state.minLiveTsMs = newMin
            guard !staleIds.isEmpty else { return 0 }
            appendRemovalRecord(markDead(ids: staleIds))
            reclaimDeadBytesIfNeeded()
            if lost > 0 { DroppedEventsCounter.increment(lost) }
            Log.warning("Pruned \(staleLines) events past the redelivery horizon (loss metric +\(lost))")
            return staleLines
        }
    }

    /// SPEC-424 STEP-1a (CL-7): purge ALL persisted events WITHOUT uploading them — analytics
    /// consent was revoked, so queued-but-unsent events must never be transmitted.
    func clearAll() {
        queue.sync {
            writeFresh(Data())
            state.reset(signature: Self.signature(of: fileURL))
        }
    }

    // MARK: - Test seams

    /// Lines JSON-decoded by this file's store since the process started (index builds count every line;
    /// loads count the lines they return). A flush must add only its batch.
    var decodedLinesForTesting: Int { queue.sync { state.decodedLines } }
    /// Times this file's index was built from the file (the first use in a process, or after the file
    /// changed behind the store's back).
    var indexBuildsForTesting: Int { queue.sync { state.indexBuilds } }
    /// Full-file rewrites (compactions, legacy-format migration).
    var rewritesForTesting: Int { queue.sync { state.rewrites } }
    /// Forget the in-memory index, as a new process would: the next operation rebuilds it from the file.
    func dropIndexForTesting() { queue.sync { state.loaded = false } }

    // MARK: - Index

    /// One line of the file.
    struct Line {
        let eventId: String
        let tsMs: Int64
        /// The `count` a `_sdk_events_dropped` meta carries; nil for a normal event.
        let metaCount: Int?
        var offset: Int
        /// The JSON object's bytes, without the newline.
        let jsonLength: Int
        /// The line's bytes in the file: `jsonLength`, plus the newline when it has one.
        var length: Int
        var live: Bool
    }

    /// The shared, in-memory index of one file. Every member is read and written on the file's queue.
    final class FileState {
        var loaded = false
        var lines: [Line] = []
        /// Live lines by `event_id` (a duplicate id maps to every live line carrying it).
        var liveById: [String: [Int]] = [:]
        var liveCount = 0
        var liveBytes = 0
        var deadBytes = 0
        var fileLength = 0
        /// Lower bound of the live lines' `ts_ms` (exact after a prune scan; may be lower after removals).
        var minLiveTsMs = Int64.max
        /// A crash mid-append left the file without a final newline: the next append starts with one.
        var needsLeadingNewline = false
        var signature: FileSignature?
        var appendsSinceCompaction = 0
        /// First line index that may still be live (lines before it are all dead) — keeps `oldest` O(batch).
        var firstLiveHint = 0
        // Test counters.
        var decodedLines = 0
        var indexBuilds = 0
        var rewrites = 0

        func reset(signature: FileSignature?) {
            loaded = true
            lines = []; liveById = [:]
            liveCount = 0; liveBytes = 0; deadBytes = 0; fileLength = Int(signature?.size ?? 0)
            minLiveTsMs = .max; needsLeadingNewline = false; firstLiveHint = 0
            appendsSinceCompaction = 0
            self.signature = signature
        }

        func liveIndices() -> [Int] {
            var out: [Int] = []
            out.reserveCapacity(liveCount)
            var i = firstLiveHint
            while i < lines.count { if lines[i].live { out.append(i) }; i += 1 }
            return out
        }

        func liveIndices(oldest limit: Int) -> [Int] {
            var out: [Int] = []
            var i = firstLiveHint
            while i < lines.count && out.count < limit {
                if lines[i].live { if out.isEmpty { firstLiveHint = i }; out.append(i) }
                i += 1
            }
            if out.isEmpty { firstLiveHint = lines.count }
            return out
        }

        func liveIndices(newest limit: Int) -> [Int] {
            var out: [Int] = []
            var i = lines.count - 1
            while i >= firstLiveHint && out.count < limit {
                if lines[i].live { out.append(i) }
                i -= 1
            }
            return out.reversed()
        }
    }

    struct FileSignature: Equatable {
        let size: UInt64
        let modified: Date?
        let fileNumber: UInt64?
    }

    static func signature(of url: URL) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileSignature(
            size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attrs[.modificationDate] as? Date,
            fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    /// On `queue`. Builds the index the first time, and again whenever the file is not the one it describes.
    private func ensureIndexed() {
        let current = Self.signature(of: fileURL)
        if state.loaded && current == state.signature { return }
        rebuildIndex(current)
    }

    /// The light per-line decode: `event_id`, `ts_ms`, and for a dropped-events meta its `count` — not the
    /// envelope. Or a removal record's ids.
    private struct LineHead: Decodable {
        let eventId: String?
        let tsMs: Int64?
        let metaCount: Int?
        let removed: [String]?

        enum Keys: String, CodingKey { case event_id, ts_ms, event_name, properties, appdna_removed }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            removed = try? c.decodeIfPresent([String].self, forKey: .appdna_removed)
            eventId = try? c.decodeIfPresent(String.self, forKey: .event_id)
            tsMs = try? c.decodeIfPresent(Int64.self, forKey: .ts_ms)
            if (try? c.decodeIfPresent(String.self, forKey: .event_name)) == "_sdk_events_dropped" {
                let props = (try? c.decodeIfPresent([String: AnyCodable].self, forKey: .properties)) ?? nil
                metaCount = (props?["count"]?.value as? Int) ?? 0
            } else {
                metaCount = nil
            }
        }
    }

    private static let removalKey = "appdna_removed"

    /// SPEC-428 CL-8: parse the NDJSON log (one event per line). A crash mid-append can leave a
    /// trailing partial line — unparseable lines are dead bytes, so the log is self-healing. Back-compat:
    /// an older single-JSON-array file is decoded once and rewritten as NDJSON.
    private func rebuildIndex(_ current: FileSignature?) {
        state.reset(signature: current)
        state.indexBuilds += 1
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            state.fileLength = 0
            return
        }
        if data.first == UInt8(ascii: "["),
           let arr = try? JSONDecoder().decode([SDKEvent].self, from: data) {
            state.decodedLines += arr.count
            writeFresh(Data())
            state.reset(signature: Self.signature(of: fileURL))
            state.rewrites += 1
            appendEvents(arr)
            return
        }
        let decoder = JSONDecoder()
        var offset = 0
        let bytes = [UInt8](data)
        let n = bytes.count
        while offset < n {
            var end = offset
            while end < n && bytes[end] != 0x0A { end += 1 }
            let hasNewline = end < n
            let length = end - offset + (hasNewline ? 1 : 0)
            if end > offset {
                state.decodedLines += 1
                let head = try? decoder.decode(LineHead.self, from: data.subdata(in: offset..<end))
                if let ids = head?.removed {
                    state.deadBytes += length
                    for id in ids { markDead(id: id) }
                } else if let head, let id = head.eventId, let ts = head.tsMs {
                    // (A complete final line without its newline is kept; the next append adds the newline.)
                    appendLine(Line(eventId: id, tsMs: ts, metaCount: head.metaCount,
                                    offset: offset, jsonLength: end - offset, length: length, live: true))
                } else {
                    // A malformed line, or a final line a crash cut short: dead bytes.
                    state.deadBytes += length
                }
            } else if hasNewline {
                state.deadBytes += 1
            }
            offset += length
        }
        state.fileLength = n
        state.needsLeadingNewline = bytes.last != 0x0A
    }

    private func appendLine(_ line: Line) {
        state.lines.append(line)
        state.liveById[line.eventId, default: []].append(state.lines.count - 1)
        state.liveCount += 1
        state.liveBytes += line.length
        state.minLiveTsMs = min(state.minLiveTsMs, line.tsMs)
    }

    @discardableResult
    private func markDead(id: String) -> Bool {
        guard let idxs = state.liveById.removeValue(forKey: id) else { return false }
        for i in idxs where state.lines[i].live {
            state.lines[i].live = false
            state.liveCount -= 1
            state.liveBytes -= state.lines[i].length
            state.deadBytes += state.lines[i].length
        }
        return true
    }

    /// Marks the live lines of `ids` dead; returns the ids that had one.
    private func markDead(ids: Set<String>) -> [String] {
        var removed: [String] = []
        for id in ids where markDead(id: id) { removed.append(id) }
        return removed
    }

    // MARK: - File writes

    /// SPEC-428 CL-8: append events as NDJSON lines (O(1) — seek to end + write). Creates the file on
    /// first write.
    private func appendEvents(_ events: [SDKEvent]) {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        var encoded: [(SDKEvent, Data)] = []
        for event in events {
            guard let data = try? encoder.encode(event) else { continue }
            encoded.append((event, data))
        }
        guard !encoded.isEmpty else { return }
        var blob = Data()
        if state.needsLeadingNewline { blob.append(0x0A) }
        var pending: [(SDKEvent, Int, Int)] = []   // event, offset within blob, length
        for (event, data) in encoded {
            pending.append((event, blob.count, data.count + 1))
            blob.append(data)
            blob.append(0x0A) // '\n'
        }
        guard let base = appendRaw(blob) else { return }
        if state.needsLeadingNewline { state.deadBytes += 1; state.needsLeadingNewline = false }
        for (event, rel, len) in pending {
            let metaCount: Int? = event.event_name == "_sdk_events_dropped"
                ? ((event.properties?["count"]?.value as? Int) ?? 0) : nil
            appendLine(Line(eventId: event.event_id, tsMs: event.ts_ms, metaCount: metaCount,
                            offset: base + rel, jsonLength: len - 1, length: len, live: true))
        }
    }

    /// One removal record for `ids`.
    private func appendRemovalRecord(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        if state.liveCount == 0 {
            // Nothing left: an empty file is cheaper than any record.
            writeFresh(Data())
            state.reset(signature: Self.signature(of: fileURL))
            return
        }
        guard var data = try? JSONSerialization.data(withJSONObject: [Self.removalKey: ids]) else { return }
        data.append(0x0A)
        if state.needsLeadingNewline { data.insert(0x0A, at: 0) }
        if appendRaw(data) != nil {
            state.needsLeadingNewline = false
            state.deadBytes += data.count
        }
    }

    /// Appends `blob` at the end of the file; returns the offset it landed at (nil when nothing was written,
    /// in which case the index is rebuilt by the next operation).
    private func appendRaw(_ blob: Data) -> Int? {
        var base: Int?
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            if let end = try? handle.seekToEnd(), (try? handle.write(contentsOf: blob)) != nil {
                base = Int(end)
            }
        } else if (try? blob.write(to: fileURL, options: .atomic)) != nil {
            // File doesn't exist yet — create it atomically with these lines.
            base = 0
        }
        guard let base else {
            state.loaded = false
            return nil
        }
        state.fileLength = base + blob.count
        state.signature = Self.signature(of: fileURL)
        return base
    }

    /// Replaces the file (atomic). The caller resets or rebuilds the index.
    private func writeFresh(_ data: Data) {
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Decodes the given live lines into events, oldest first. A line that no longer decodes as an event is
    /// marked dead (it was never sendable).
    private func decodeLive(_ indices: [Int]) -> [SDKEvent] {
        guard let first = indices.first, let last = indices.last else { return [] }
        let start = state.lines[first].offset
        let end = state.lines[last].offset + state.lines[last].length
        guard let chunk = readRange(start, end - start) else {
            state.loaded = false
            return []
        }
        let decoder = JSONDecoder()
        var out: [SDKEvent] = []
        out.reserveCapacity(indices.count)
        var undecodable: [String] = []
        for i in indices {
            let line = state.lines[i]
            let lo = line.offset - start, hi = lo + line.jsonLength
            guard lo >= 0, hi <= chunk.count, lo < hi else { undecodable.append(line.eventId); continue }
            state.decodedLines += 1
            if let ev = try? decoder.decode(SDKEvent.self, from: chunk.subdata(in: lo..<hi)), ev.event_id == line.eventId {
                out.append(ev)
            } else {
                undecodable.append(line.eventId)
            }
        }
        if !undecodable.isEmpty {
            Log.warning("Event store: \(undecodable.count) unreadable line(s) skipped")
            appendRemovalRecord(markDead(ids: Set(undecodable)))
        }
        return out
    }

    private func readRange(_ offset: Int, _ length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: length), data.count == length else { return nil }
        return data
    }

    // MARK: - Compaction

    /// After a removal: reclaim dead bytes once they pass the slack, or outweigh the live events.
    private func reclaimDeadBytesIfNeeded() {
        if deadBytesCallForCompaction { compact() }
    }

    private var deadBytesCallForCompaction: Bool {
        let dead = state.deadBytes
        return dead > Self.deadBytesSlack || (dead > Self.minDeadBytesToCompact && dead > state.liveBytes)
    }

    /// SPEC-428 CL-8: compaction enforces the count + disk caps and reclaims dead bytes by rewriting the
    /// log from the live lines' raw bytes (no JSON work) — the amortized O(n) work. It rewrites only when
    /// there is something to do. Dropped events are counted (CL-1).
    private func compact() {
        state.appendsSinceCompaction = 0
        var live = state.liveIndices()
        let originalCount = live.count

        // Count cap, then the disk quota (drop the oldest 10% until the live bytes fit) — SPEC-067.
        var dropped: [Int] = []
        if live.count > self.maxEvents {
            let excess = live.count - self.maxEvents
            dropped += live.prefix(excess)
            live.removeFirst(excess)
        }
        var liveBytes = live.reduce(0) { $0 + state.lines[$1].length }
        while liveBytes > Self.maxDiskBytes && !live.isEmpty {
            let dropCount = max(live.count / 10, 1)
            for i in live.prefix(dropCount) { liveBytes -= state.lines[i].length }
            dropped += live.prefix(dropCount)
            live.removeFirst(dropCount)
        }

        guard !dropped.isEmpty || deadBytesCallForCompaction else { return }
        rewrite(keeping: live)

        let droppedCount = originalCount - live.count
        if droppedCount > 0 {
            // SPEC-428 STEP-4: never UNDER-count the loss metric. All drops are from the FRONT (oldest), so
            // the evicted set is the prefix. For a normal event count 1; for an evicted `_sdk_events_dropped`
            // META event, RECOVER the N drops it carried (they were already reset to 0 when it was composed,
            // so evicting it before delivery would otherwise lose them) — re-adding N re-emits them later.
            let lost = dropped.reduce(0) { $0 + (state.lines[$1].metaCount ?? 1) }
            if lost > 0 { DroppedEventsCounter.increment(lost) } // CL-1/D2: count the loss (never silent)
            Log.warning("Event store compaction dropped \(droppedCount) oldest events (loss metric +\(lost))")
        }
        // Rebuild the in-memory lines for the rewritten file (every line now ends in a newline).
        var newLines: [Line] = []
        newLines.reserveCapacity(live.count)
        var offset = 0
        for i in live {
            var l = state.lines[i]
            l.offset = offset
            l.length = l.jsonLength + 1
            offset += l.length
            newLines.append(l)
        }
        let signature = Self.signature(of: fileURL)
        state.reset(signature: signature)
        for l in newLines { appendLine(l) }
        state.fileLength = offset
        if Int(signature?.size ?? 0) != offset { state.loaded = false }   // the write failed: re-read the file
    }

    /// Writes a fresh file holding exactly the given live lines, copied byte for byte.
    private func rewrite(keeping live: [Int]) {
        state.rewrites += 1
        guard !live.isEmpty else { writeFresh(Data()); return }
        guard let all = readRange(0, state.fileLength) else {
            state.loaded = false
            return
        }
        var blob = Data()
        blob.reserveCapacity(live.reduce(0) { $0 + state.lines[$1].jsonLength + 1 })
        for i in live {
            let l = state.lines[i]
            blob.append(all.subdata(in: l.offset..<(l.offset + l.jsonLength)))
            blob.append(0x0A)
        }
        writeFresh(blob)
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
