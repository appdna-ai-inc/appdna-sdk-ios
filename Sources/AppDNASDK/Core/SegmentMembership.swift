import Foundation

/// An in-app message's segment targeting, as published: `{segments, exclude_segments}`. Blank and duplicate ids are
/// dropped when decoded. Android `SegmentAudience`, same shape.
public struct SegmentAudience: Codable, Equatable {
    public var segments: [String]
    public var exclude_segments: [String]

    public init(segments: [String] = [], exclude_segments: [String] = []) {
        self.segments = Self.clean(segments)
        self.exclude_segments = Self.clean(exclude_segments)
    }

    var ids: Set<String> { Set(segments + exclude_segments) }
    var isEmpty: Bool { segments.isEmpty && exclude_segments.isEmpty }

    private static func clean(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey { case segments, exclude_segments }

    public init(from decoder: Decoder) throws {
        // Not an object (an older or hand-written shape): no targeting, never a decode failure of the whole message.
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self.init(); return }
        // A list that is absent, null or not a list of strings reads as empty (never a decode failure of the message).
        let read: (CodingKeys) -> [String] = { key in
            ((try? c.decodeIfPresent([String?].self, forKey: key)) ?? nil)?.compactMap { $0 } ?? []
        }
        self.init(segments: read(.segments), exclude_segments: read(.exclude_segments))
    }
}

/// Which segments the current user is in, as AppDNA resolved them (`POST /api/v1/sdk/segments`), for the segment
/// targeting of in-app messages: the same definition of a segment a journey uses, resolved on the server (trait
/// segments, behaviour audiences and personas alike). Android `SegmentMembership`, same rules.
///
/// The answer is kept for ONE user (`userKey`) and for the ids it was asked about. It is persisted, so a cold start
/// without a network still has the previous launch's answer, and a different user never reads it. The gate fails
/// closed: a message with segments is not shown until the answer for this user covers its ids.
enum SegmentMembership {
    struct Answer: Codable, Equatable {
        let userKey: String
        let asked: Set<String>
        let memberOf: Set<String>
        let unresolved: Set<String>
        let fetchedAt: Date
    }

    static let path = "/api/v1/sdk/segments"
    /// The server's cap on ids per request.
    static let maxIds = 50
    private static let storageKey = "ai.appdna.segments.answer"
    private static let lock = NSLock()
    private static var _answer: Answer?
    private static var inFlight = false
    private static var loaded = false

    /// The current answer. Setting it is memory-only (the fixtures use it); `store` is the network path.
    static var answer: Answer? {
        get { lock.lock(); defer { lock.unlock() }; return _answer }
        set { lock.lock(); _answer = newValue; lock.unlock() }
    }

    /// The key an answer is kept under: the identified user, else the device's anonymous id.
    static func userKey(anonId: String?, userId: String?) -> String? {
        if let u = userId, !u.isEmpty { return "u:\(u)" }
        if let a = anonId, !a.isEmpty { return "a:\(a)" }
        return nil
    }

    /// Does `audience` admit the user `userKey`, given `answer`? No segments: yes. Otherwise only with an answer for this
    /// user that was asked about every id of the message, none of them unresolved; then the user must be in at least
    /// one `segments` id (when there are any) and in no `exclude_segments` id.
    static func allows(_ audience: SegmentAudience?, userKey: String?, answer: Answer?) -> Bool {
        guard let audience = audience, !audience.isEmpty else { return true }
        guard let answer = answer, let key = userKey, answer.userKey == key else { return false }
        if audience.ids.contains(where: { !answer.asked.contains($0) || answer.unresolved.contains($0) }) { return false }
        if !audience.segments.isEmpty && !audience.segments.contains(where: { answer.memberOf.contains($0) }) { return false }
        return !audience.exclude_segments.contains(where: { answer.memberOf.contains($0) })
    }

    /// Whether the answer for `userKey` covers `ids` and is younger than `ttl`.
    static func isFresh(_ ids: Set<String>, userKey: String?, ttl: TimeInterval, now: Date = Date()) -> Bool {
        guard let a = answer, let key = userKey, a.userKey == key else { return false }
        return ids.isSubset(of: a.asked) && now.timeIntervalSince(a.fetchedAt) < ttl
    }

    /// Load the persisted answer. Called from `configure`.
    static func attach(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        if _answer == nil, let data = defaults.data(forKey: storageKey) {
            _answer = try? JSONDecoder().decode(Answer.self, from: data)
        }
    }

    /// The server's answer for `userKey`, asked about `asked`. Nil when the body is not an answer.
    static func parseAnswer(_ data: Data?, userKey: String, asked: Set<String>, now: Date = Date()) -> Answer? {
        guard let data = data,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let member = o["member_of"] as? [Any] else { return nil }
        let strings: ([Any]) -> Set<String> = { Set($0.compactMap { $0 as? String }) }
        let unresolved = (o["unresolved"] as? [Any]).map(strings) ?? []
        return Answer(userKey: userKey, asked: asked, memberOf: strings(member).intersection(asked),
                      unresolved: unresolved.intersection(asked), fetchedAt: now)
    }

    /// Keep `a` as the current answer, in memory and on disk.
    static func store(_ a: Answer, defaults: UserDefaults = .standard) {
        answer = a
        if let data = try? JSONEncoder().encode(a) { defaults.set(data, forKey: storageKey) }
    }

    /// Forget the answer (sign-out). The next user asks again.
    static func clear(defaults: UserDefaults = .standard) {
        answer = nil
        defaults.removeObject(forKey: storageKey)
    }

    /// Ask the server about `ids` for this user unless a fresh answer already covers them, one request at a time. On a
    /// failed request the previous answer stays (for its own user only); the gate keeps failing closed otherwise.
    static func refresh(
        ids: Set<String>, anonId: String, userId: String?, ttl: TimeInterval,
        post: @escaping (_ path: String, _ body: [String: Any]) async -> (status: Int?, data: Data?)
    ) async {
        guard let key = userKey(anonId: anonId, userId: userId) else { return }
        let wanted = Set(ids.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.sorted().prefix(maxIds))
        guard !wanted.isEmpty, !isFresh(wanted, userKey: key, ttl: ttl) else { return }
        lock.lock()
        if inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        defer { lock.lock(); inFlight = false; lock.unlock() }

        let body: [String: Any] = ["anon_id": anonId, "user_id": userId ?? NSNull(), "segment_ids": wanted.sorted()]
        let (status, data) = await post(path, body)
        if let s = status, (200..<300).contains(s) {
            if let a = parseAnswer(data, userKey: key, asked: wanted) { store(a) }
            else { Log.warning("[Segments] unreadable membership answer") }
        } else {
            Log.debug("[Segments] membership request failed (\(status.map(String.init) ?? "network")); segment-targeted messages stay hidden")
        }
    }

    static func resetForTesting() {
        lock.lock(); _answer = nil; inFlight = false; loaded = false; lock.unlock()
    }
}
