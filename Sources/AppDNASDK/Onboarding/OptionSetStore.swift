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

    private var cache: [String: CacheEntry] = [:]
    /// In-flight fetches, so ten cells appearing at once cause one request rather than ten.
    private var inFlight: [String: Task<[InputOption], Never>] = [:]

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

    private func store(setId: String, page: OptionSetPage) {
        cache[setId] = CacheEntry(
            version: page.version,
            items: page.items,
            totalCount: page.total_count,
            fetchedAt: Date()
        )
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
        cache[setId] = CacheEntry(
            version: page.version,
            items: merged,
            totalCount: page.total_count,
            fetchedAt: existing.fetchedAt
        )
    }

    /// Test seam — the cache is process-lifetime, so tests must be able to start clean.
    func resetForTesting() {
        cache.removeAll()
        inFlight.removeAll()
    }
}
