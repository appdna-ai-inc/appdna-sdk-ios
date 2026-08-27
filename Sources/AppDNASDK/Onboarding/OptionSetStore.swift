import Foundation

/// One item of a dynamic Option Set, as the server sends it.
///
/// Decoded into the SAME `InputOption` the inline options use rather than a parallel type — an
/// option authored in a set and the identical option authored inline must render identically, and
/// a second type here is how that drifts.
struct OptionSetPage: Decodable {
    let set_id: String
    let version: Int
    let total_count: Int
    let next_cursor: String?
    let items: [InputOption]
}

private struct OptionSetEnvelope: Decodable {
    let data: OptionSetPage
}

/// SPEC-448 §A/§C — the device side of a dynamic option list.
///
/// 🔴 The rule this exists to satisfy is "**never looks like it is fetching**". A Select bound to a
/// set must render instantly with whatever it already has, and improve quietly. So the fallback
/// ladder is strict, and it is a ladder rather than a race:
///
///   1. **cache** — a previous fetch for this set at this version
///   2. **embedded page** — the first N items that shipped inside the flow config, which is also
///      the only thing an SDK predating this spec ever sees
///   3. **static options** — whatever the author left authored on the block
///   4. **skip** — the step has nothing to show
///
/// Only step 1 misses on a genuinely cold start, and only then is a skeleton correct.
actor OptionSetStore {
    static let shared = OptionSetStore()

    private struct CacheEntry {
        let version: Int
        let items: [InputOption]
        let totalCount: Int
        let fetchedAt: Date
    }

    /// 🔴 SCALE. Three limits, because this feature is explicitly for lists of thousands and an
    /// unbounded store is how that becomes a memory report rather than a feature.
    ///
    /// - `maxItemsPerSet` caps what paging accumulates. A user scrolling a 20,000-item list would
    ///   otherwise hold all 20,000 decoded options resident; the oldest pages are dropped, and
    ///   scrolling back re-fetches them, which is far cheaper than never releasing them.
    /// - `maxCachedSets` caps how many sets stay resident, evicting least-recently-used. An app
    ///   with a set per screen would otherwise keep every one it ever showed.
    /// - `maxDiskBytes` caps what is persisted, so the SDK cannot grow a user's storage without
    ///   bound on a device that never clears it.
    private static let maxItemsPerSet = 2_000
    private static let maxCachedSets = 8
    private static let maxDiskBytes = 2 * 1_024 * 1_024

    private var cache: [String: CacheEntry] = [:]
    /// Access order for LRU eviction — most recent last.
    private var lru: [String] = []
    /// Next-page cursor per set. Separate from the entry so a merge does not lose it.
    private var cursors: [String: String] = [:]
    /// In-flight fetches, so ten cells appearing at once cause one request rather than ten.
    private var inFlight: [String: Task<[InputOption], Never>] = [:]

    // MARK: - Persistence
    //
    // 🔴 Without this the ladder's FIRST rung is empty on every cold launch, and the spec's promise
    // that a warm run never looks like it is fetching only holds within one process. A user who
    // opens the app fresh would see the embedded 50 items and a re-download every time — on a list
    // of thousands that is both a worse experience and real, repeated bandwidth for the customer.
    //
    // Written to Caches, not Documents: this is re-derivable from the server, so the OS is welcome
    // to reclaim it under pressure. Failures are ignored throughout — a cache that cannot be
    // written must never break a render.

    private static var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("appdna-option-sets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct PersistedEntry: Codable {
        let version: Int
        let totalCount: Int
        let items: [InputOption]
        let cursor: String?
    }

    private func persist(setId: String) {
        guard let dir = Self.cacheDirectory, let entry = cache[setId] else { return }
        let payload = PersistedEntry(
            version: entry.version,
            totalCount: entry.totalCount,
            items: entry.items,
            cursor: cursors[setId]
        )
        guard let data = try? JSONEncoder().encode(payload),
              data.count <= Self.maxDiskBytes else { return }
        try? data.write(to: dir.appendingPathComponent("\(setId).json"), options: .atomic)
    }

    /// Load a persisted set into memory. Called before the ladder is consulted, so a cold launch
    /// still has a real first rung.
    func hydrate(setId: String) {
        guard cache[setId] == nil, let dir = Self.cacheDirectory else { return }
        let url = dir.appendingPathComponent("\(setId).json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(PersistedEntry.self, from: data)
        else { return }
        cache[setId] = CacheEntry(
            version: payload.version,
            items: payload.items,
            totalCount: payload.totalCount,
            fetchedAt: Date()
        )
        if let cursor = payload.cursor { cursors[setId] = cursor }
        touch(setId)
    }

    /// Mark a set as most-recently-used and evict past the cap.
    private func touch(_ setId: String) {
        lru.removeAll { $0 == setId }
        lru.append(setId)
        while lru.count > Self.maxCachedSets, let oldest = lru.first {
            lru.removeFirst()
            cache.removeValue(forKey: oldest)
            cursors.removeValue(forKey: oldest)
            // The DISK copy stays: eviction is about memory, and the file is what makes the next
            // cold start fast. Disk is bounded by its own byte cap instead.
        }
    }

    /// What a Select should render RIGHT NOW, without waiting for anything.
    ///
    /// Synchronous by design: an async call here would make the first frame depend on the network
    /// even when the answer is already in memory, which is the "looks like it is fetching" this
    /// whole design is avoiding.
    func immediateOptions(setId: String, embedded: [InputOption], authored: [InputOption]) -> [InputOption] {
        if let entry = cache[setId], !entry.items.isEmpty { return entry.items }   // 1
        if !embedded.isEmpty { return embedded }                                   // 2
        return authored                                                            // 3 (4 = empty)
    }

    /// True only when there is genuinely nothing to draw — the one case where a skeleton is honest.
    func isColdStart(setId: String, embedded: [InputOption], authored: [InputOption]) -> Bool {
        immediateOptions(setId: setId, embedded: embedded, authored: authored).isEmpty
    }

    /// Refresh in the background. Never throws: a failed refresh must leave the ladder standing,
    /// not replace a working list with an error.
    @discardableResult
    func refresh(setId: String, client: APIClient?, expectedVersion: Int?) async -> [InputOption] {
        // A cached entry at the version the flow config names is current by definition. This is
        // what makes an author's edit land on next launch via the version rather than only after
        // some TTL expires.
        if let entry = cache[setId], let expected = expectedVersion, entry.version >= expected {
            return entry.items
        }
        if let existing = inFlight[setId] { return await existing.value }

        let task = Task<[InputOption], Never> { [weak self] in
            guard let self, let client else { return [] }
            do {
                let page: OptionSetEnvelope = try await client.request(
                    .optionSet(id: setId, cursor: nil, query: nil)
                )
                await self.store(setId: setId, page: page.data)
                return page.data.items
            } catch {
                Log.debug("Option set \(setId) refresh failed: \(error)")
                return []
            }
        }
        inFlight[setId] = task
        let result = await task.value
        inFlight[setId] = nil
        return result
    }

    /// Search the set remotely. Returns nil when the search could not be performed, which the
    /// caller shows as "no progress" rather than "no results" — an empty list would tell the user
    /// their query matched nothing, which is a different and wrong statement.
    func search(setId: String, query: String, client: APIClient?) async -> [InputOption]? {
        guard let client else { return nil }
        do {
            let page: OptionSetEnvelope = try await client.request(
                .optionSet(id: setId, cursor: nil, query: query)
            )
            return page.data.items
        } catch {
            return nil
        }
    }

    /// Next page, for scrolling past the first N.
    func nextPage(setId: String, cursor: String, client: APIClient?) async -> OptionSetPage? {
        guard let client else { return nil }
        do {
            let page: OptionSetEnvelope = try await client.request(
                .optionSet(id: setId, cursor: cursor, query: nil)
            )
            await appendToCache(setId: setId, page: page.data)
            return page.data
        } catch {
            return nil
        }
    }

    /// The cursor for the next page, or nil at the end.
    func cursor(for setId: String) -> String? { cursors[setId] }

    /// Everything cached for this set, after de-duplication.
    func cachedItems(for setId: String) -> [InputOption] { cache[setId]?.items ?? [] }

    private func store(setId: String, page: OptionSetPage) {
        cache[setId] = CacheEntry(
            version: page.version,
            items: page.items,
            totalCount: page.total_count,
            fetchedAt: Date()
        )
        touch(setId)
        persist(setId: setId)
        // Absence means 'no next page'. A `[String: String?]` here would make lookups
        // return String?? and silently never match a plain String?.
        if let next = page.next_cursor, !next.isEmpty { cursors[setId] = next }
        else { cursors.removeValue(forKey: setId) }
    }

    private func appendToCache(setId: String, page: OptionSetPage) {
        guard let existing = cache[setId] else { return store(setId: setId, page: page) }
        // De-duplicate by value: a reorder between two page fetches can legitimately return an
        // item the caller already holds, and showing it twice is worse than showing it late.
        var seen = Set(existing.items.map { $0.resolvedValue })
        var merged = existing.items
        for item in page.items where !seen.contains(item.resolvedValue) {
            merged.append(item)
            seen.insert(item.resolvedValue)
        }
        // Cap what paging accumulates: keep the MOST RECENT window. Scrolling back re-fetches,
        // which is cheaper than holding every page a long session ever touched.
        let capped = merged.count > Self.maxItemsPerSet
            ? Array(merged.suffix(Self.maxItemsPerSet))
            : merged
        cache[setId] = CacheEntry(
            version: page.version,
            items: capped,
            totalCount: page.total_count,
            fetchedAt: existing.fetchedAt
        )
        touch(setId)
        persist(setId: setId)
        // Absence means 'no next page'. A `[String: String?]` here would make lookups
        // return String?? and silently never match a plain String?.
        if let next = page.next_cursor, !next.isEmpty { cursors[setId] = next }
        else { cursors.removeValue(forKey: setId) }
    }

    /// Test seam — the cache is process-lifetime, so tests must be able to start clean.
    func resetForTesting() {
        cache.removeAll()
        cursors.removeAll()
        lru.removeAll()
        inFlight.removeAll()
    }
}
