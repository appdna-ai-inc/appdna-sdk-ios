// RemoteValidation.swift
//
// Live validation — live validation of a single-line text input through the host app (`onValidateInput`).
//
// The SDK opens no connection of its own: the host answers whether a value is valid. This file holds the whole
// behaviour, so the shared fixtures (`step_advance/remote_validation_*`) drive the SAME code the step runs:
//
//   * `InputValidationResult` — the host's answer, and the one decoder every wrapper bridge forwards a reply through.
//   * `RemoteValidationConfig` — `field_config.remote_validation`, decoded with its defaults.
//   * `RemoteValidationCoordinator` — one per step presentation: the per-field state machine (debounce, one call in
//     flight, stale replies dropped, timeout, offline + re-check, cache, no delegate) and the CTA gate (owner decision
//     165: an invalid value blocks; a tap while a check runs waits; no answer lets the user continue unless the field
//     says "block").
//
// Android mirrors this file in `onboarding/RemoteValidation.kt`.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import SwiftUI

// MARK: - The host's answer

/// What `AppDNAOnboardingDelegate.onValidateInput` returns. `nil` means "no answer": the field ends unavailable and,
/// unless its author chose "block", the user can continue.
public enum InputValidationResult: Equatable {
    /// The value is accepted. `message`, when set, is shown under the field in place of the authored valid text.
    case valid(message: String? = nil)
    /// The value is refused. `message`, when set, is shown under the field in place of the authored invalid text.
    case invalid(message: String? = nil)

    /// The status a wrapper bridge sends when the host registered no `onValidateInput` handler.
    public static let notImplementedStatus = "not_implemented"

    /// The ONE decoder for a reply that crossed a wrapper bridge: `{"status": "valid"|"invalid", "message"?: String}`.
    /// The status is case-sensitive; any other shape is nil. A non-string or empty message is no message.
    /// `{"status": "not_implemented"}` (the wrapper's "no handler") returns nil AND tells the step the host does
    /// not implement the hook, so the field behaves as if there were no delegate.
    public static func decodeBridgeReply(_ reply: Any?) -> InputValidationResult? {
        switch decodeWire(reply) {
        case .result(let r): return r
        case .notImplemented:
            RemoteValidationProbe.markNotImplemented()
            return nil
        case .none: return nil
        }
    }

    /// How long a wrapper bridge should wait for its host: the field's own timeout, plus a second so the step's timer
    /// (which ends the check) always decides first. Read inside `onValidateInput`; 6 s outside a check.
    public static var bridgeTimeout: TimeInterval { (RemoteValidationProbe.timeout ?? 5) + 1 }

    enum Wire: Equatable { case result(InputValidationResult), notImplemented }

    /// The pure decode, without the side channel (the fixture reads it).
    static func decodeWire(_ reply: Any?) -> Wire? {
        guard let map = reply as? [String: Any], let status = map["status"] as? String else { return nil }
        let raw = map["message"] as? String
        let message = (raw?.isEmpty == false) ? raw : nil
        switch status {
        case "valid": return .result(.valid(message: message))
        case "invalid": return .result(.invalid(message: message))
        case notImplementedStatus: return .notImplemented
        default: return nil
        }
    }
}

/// How the step learns that the delegate it called did not implement `onValidateInput`. The protocol's default
/// implementation (and `decodeBridgeReply` for a wrapper with no handler) marks the task-local box the coordinator's
/// call runs inside; a Swift protocol gives no other way to tell a default from a host's own method.
enum RemoteValidationProbe {
    final class Box { var notImplemented = false }
    @TaskLocal static var box: Box?
    /// The field's timeout, in seconds, for the call in progress (a wrapper bridge waits that long).
    @TaskLocal static var timeout: TimeInterval?

    static func markNotImplemented() { box?.notImplemented = true }

    /// What the step has learned about each delegate instance: true = it answers, false = it does not implement the
    /// hook. Re-learned on every completed call, so a wrapper whose host registers a handler later is picked up.
    private static var answers: [ObjectIdentifier: Bool] = [:]
    private static let lock = NSLock()

    static func known(_ host: AnyObject) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return answers[ObjectIdentifier(host)]
    }

    static func learn(_ host: AnyObject, implements: Bool) {
        lock.lock(); answers[ObjectIdentifier(host)] = implements; lock.unlock()
    }
}

// MARK: - Config

/// `field_config.remote_validation` on `input_text` / `input_email` / `input_phone` / `input_number` / `input_url`.
struct RemoteValidationConfig: Equatable {
    enum Trigger: String { case typing, confirm }

    var trigger: Trigger = .typing
    var debounceMs: Int = 600
    var minChars: Int = 1
    var timeoutMs: Int = 5000
    /// "If the app can't answer": false = let the user continue (the default, owner decision 165), true = block.
    var blocksWhenUnavailable = false
    var checkingText: String?
    var validText: String?
    var invalidText: String?
    var unavailableText: String?
    var offlineText: String?

    static let validatedTypes: Set<String> = ["input_text", "input_email", "input_phone", "input_number", "input_url"]

    static let builtInInvalid = "This value isn't available"
    static let builtInUnavailable = "We couldn't check this right now."
    static let builtInOffline = "You're offline. We'll check again when you're back online."

    /// The config of a block, or nil when the block does not validate remotely (not one of the five types, no
    /// `remote_validation`, or `enabled` not true). `loc` localises the five texts
    /// (`block.<id>.remote_validation.<key>`).
    static func of(_ block: ContentBlock, loc: ((String, String) -> String)? = nil) -> RemoteValidationConfig? {
        guard validatedTypes.contains(block.type.rawValue) else { return nil }
        return from(block.field_config?["remote_validation"]?.value, blockId: block.id, loc: loc)
    }

    static func from(_ raw: Any?, blockId: String = "", loc: ((String, String) -> String)? = nil) -> RemoteValidationConfig? {
        guard let map = raw as? [String: Any], (map["enabled"] as? Bool) == true else { return nil }
        func int(_ key: String, _ fallback: Int, _ lo: Int, _ hi: Int) -> Int {
            let v: Int?
            if let i = map[key] as? Int { v = i } else if let d = map[key] as? Double { v = Int(d) } else { v = nil }
            return min(hi, max(lo, v ?? fallback))
        }
        func text(_ key: String) -> String? {
            guard let s = map[key] as? String, !s.isEmpty else { return nil }
            return loc?("block.\(blockId).remote_validation.\(key)", s) ?? s
        }
        var c = RemoteValidationConfig()
        c.trigger = Trigger(rawValue: map["trigger"] as? String ?? "") ?? .typing
        c.debounceMs = int("debounce_ms", 600, 300, 2000)
        c.minChars = int("min_chars", 1, 1, 50)
        c.timeoutMs = int("timeout_ms", 5000, 1000, 15000)
        c.blocksWhenUnavailable = (map["when_unavailable"] as? String) == "block"
        c.checkingText = text("checking_text")
        c.validText = text("valid_text")
        c.invalidText = text("invalid_text")
        c.unavailableText = text("unavailable_text")
        c.offlineText = text("offline_text")
        return c
    }

    /// Characters as the user typed them, counted in Unicode scalars (Android counts code points: the same number).
    static func length(_ value: String) -> Int { value.unicodeScalars.count }
}

// MARK: - The coordinator

/// One step presentation's live validation. Main-thread only, like the step that owns it.
final class RemoteValidationCoordinator: ObservableObject {
    enum Phase: String {
        /// Empty, or shorter than `min_chars`: nothing to check.
        case idle
        /// `confirm` trigger: a value waits for return / focus lost.
        case unchecked
        /// `typing` trigger: the debounce is running.
        case waiting
        case checking
        case valid
        case invalid
        case unavailable
    }

    struct FieldState: Equatable {
        var phase: Phase = .idle
        var value: String = ""
        /// What is drawn under the field; nil = nothing.
        var message: String?
        /// `unavailable` only: timeout | offline | error | no_delegate.
        var reason: String?
        var config = RemoteValidationConfig()

        /// Drawn as in progress (spinner, checking border).
        var showsProgress: Bool { phase == .waiting || phase == .checking }
    }

    enum Decision: Equatable { case allow, wait, block(String) }

    /// One field the CTA weighs: its id, its current value and its config.
    struct Entry: Equatable {
        let id: String
        let value: String
        let config: RemoteValidationConfig
    }

    /// The outcome of one host call.
    enum HostOutcome { case answered(InputValidationResult?), notImplemented, threw }

    typealias Schedule = (_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void
    /// Starts the host call for `(fieldId, value)` and returns its cancel. `complete` may run synchronously.
    typealias StartCall = (_ fieldId: String, _ value: String, _ timeout: TimeInterval, _ complete: @escaping (HostOutcome) -> Void) -> () -> Void

    @Published private(set) var fields: [String: FieldState] = [:]
    /// A CTA tap is waiting for a check to end (the CTA draws its loading state).
    @Published private(set) var ctaWaiting = false

    /// Whether there is a host to ask: false = no delegate, or one known not to implement the hook.
    var hasHost: () -> Bool
    /// Whether to draw progress before the host is known to answer (iOS: the first call to a delegate tells).
    var hostKnownToAnswer: () -> Bool = { true }
    var startCall: StartCall
    var isOnline: () -> Bool
    var track: (_ properties: [String: Any]) -> Void
    var warn: (String) -> Void
    var now: () -> TimeInterval
    private let schedule: Schedule

    private var debounce: [String: () -> Void] = [:]
    private var flights: [String: (seq: Int, cancel: () -> Void, cancelTimeout: () -> Void, started: TimeInterval)] = [:]
    private var seq = 0
    private var cache: [String: InputValidationResult] = [:]
    private var cacheOrder: [String] = []
    private var warned: Set<String> = []
    private var pendingTap: (fields: () -> [Entry], done: (Decision) -> Void)?
    private var ended = false
    private var reevaluating = false

    static let cacheLimit = 20

    init(
        schedule: Schedule? = nil,
        hasHost: @escaping () -> Bool = { false },
        startCall: @escaping StartCall = { _, _, _, complete in complete(.notImplemented); return {} },
        isOnline: @escaping () -> Bool = { true },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        track: @escaping ([String: Any]) -> Void = { _ in },
        warn: @escaping (String) -> Void = { Log.warning($0) }
    ) {
        self.schedule = schedule ?? { seconds, fire in
            let t = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !Task.isCancelled { fire() }
            }
            return { t.cancel() }
        }
        self.hasHost = hasHost
        self.startCall = startCall
        self.isOnline = isOnline
        self.now = now
        self.track = track
        self.warn = warn
    }

    func state(_ fieldId: String) -> FieldState? { fields[fieldId] }

    /// Whether the field's border and spinner should show progress now.
    func showsProgress(_ fieldId: String) -> Bool {
        (fields[fieldId]?.showsProgress ?? false) && hostKnownToAnswer()
    }

    // MARK: Inputs

    /// The user edited the field (or a saved value was restored: `immediate` skips the debounce).
    func valueChanged(_ fieldId: String, _ value: String, config: RemoteValidationConfig, immediate: Bool = false) {
        guard !ended else { return }
        if let s = fields[fieldId], s.value == value, s.config == config { return }
        cancelDebounce(fieldId)
        cancelFlight(fieldId)
        var s = FieldState(phase: .idle, value: value, message: nil, reason: nil, config: config)
        defer { reevaluateTap() }
        guard !value.isEmpty, RemoteValidationConfig.length(value) >= config.minChars else {
            fields[fieldId] = s
            return
        }
        guard hasHost() else {
            fields[fieldId] = s
            endWithoutHost(fieldId)
            return
        }
        if let hit = cache[cacheKey(fieldId, value)] {
            s = apply(hit, to: s)
            fields[fieldId] = s
            return
        }
        if config.trigger == .confirm && !immediate {
            s.phase = .unchecked
            fields[fieldId] = s
            return
        }
        if immediate {
            fields[fieldId] = s
            startCheck(fieldId)
            return
        }
        s.phase = .waiting
        s.message = config.checkingText
        fields[fieldId] = s
        debounce[fieldId] = schedule(Double(config.debounceMs) / 1000) { [weak self] in
            guard let self, self.fields[fieldId]?.phase == .waiting, self.fields[fieldId]?.value == value else { return }
            self.debounce[fieldId] = nil
            self.startCheck(fieldId)
        }
    }

    /// Return key or focus lost: a value still waiting is checked now.
    func confirm(_ fieldId: String) {
        guard let p = fields[fieldId]?.phase, p == .waiting || p == .unchecked else { return }
        cancelDebounce(fieldId)
        startCheck(fieldId)
    }

    /// The connection came back: every field that ended offline is checked again, once.
    func connectivityRegained() {
        guard !ended else { return }
        for (id, s) in fields.sorted(by: { $0.key < $1.key }) where s.phase == .unavailable && s.reason == "offline" {
            startCheck(id)
        }
    }

    /// Re-checks offline fields when `monitor` reports the connection is back (on the main thread). The step calls this
    /// on appear and removes the returned observer on disappear.
    func watchConnectivity(_ monitor: NetworkMonitor) -> UUID {
        monitor.addRegainedObserver { [weak self] in
            DispatchQueue.main.async { self?.connectivityRegained() }
        }
    }

    /// Sets how the views learn whether to draw progress (see `hostKnownToAnswer`).
    func configuredHostKnowledge(_ known: @escaping () -> Bool) -> RemoteValidationCoordinator {
        hostKnownToAnswer = known
        return self
    }

    /// The view (re)appeared: a router reused for a new presentation accepts input again.
    func presentationBegan() { ended = false }

    /// The decision without waiting (a path that cannot wait, e.g. `add_widget`): checks still due start now.
    func decideNow(_ entries: [Entry]) -> Decision {
        flushDue(entries)
        return decide(entries)
    }

    /// The presentation ended: nothing in flight may write any more.
    func presentationEnded() {
        ended = true
        for id in Array(debounce.keys) { cancelDebounce(id) }
        for id in Array(flights.keys) { cancelFlight(id) }
        pendingTap = nil
        ctaWaiting = false
    }

    // MARK: The CTA

    /// The decision for the step's fields under live validation, in order. `fields` = (field id, current value) of
    /// every block on the step that validates remotely; an empty value is never checked and never blocks.
    func decide(_ entries: [Entry]) -> Decision {
        var waits = false
        for e in entries where !e.value.isEmpty {
            guard let s = fields[e.id], s.value == e.value else { waits = true; continue }
            switch s.phase {
            case .idle: return .block(s.config.invalidText ?? RemoteValidationConfig.builtInInvalid)
            case .unchecked, .waiting, .checking: waits = true
            case .valid: continue
            case .invalid: return .block(s.message ?? s.config.invalidText ?? RemoteValidationConfig.builtInInvalid)
            case .unavailable:
                guard s.config.blocksWhenUnavailable else { continue }
                return .block(Self.unavailableMessage(s.config, reason: s.reason, blocks: true) ?? RemoteValidationConfig.builtInUnavailable)
            }
        }
        return waits ? .wait : .allow
    }

    /// A CTA tap. Starts every check still due, then calls `done` once with `.allow` or `.block(message)` — at once
    /// when nothing is in progress, else when the checks it waits on end. A tap while one already waits is ignored.
    func tap(fields entries: @escaping () -> [Entry], done: @escaping (Decision) -> Void) {
        guard !ctaWaiting, !ended else { return }
        flushDue(entries())
        let d = decide(entries())
        guard d == .wait else { done(d); return }
        pendingTap = (entries, done)
        ctaWaiting = true
    }

    // MARK: Internals

    private func flushDue(_ entries: [Entry]) {
        for e in entries where !e.value.isEmpty {
            guard let s = fields[e.id], s.value == e.value else {
                valueChanged(e.id, e.value, config: e.config, immediate: true)
                continue
            }
            if s.phase == .waiting || s.phase == .unchecked {
                cancelDebounce(e.id)
                startCheck(e.id)
            }
        }
    }

    private func reevaluateTap() {
        guard !reevaluating, let pending = pendingTap else { return }
        reevaluating = true
        defer { reevaluating = false }
        flushDue(pending.fields())
        guard pendingTap != nil else { return }
        let d = decide(pending.fields())
        guard d != .wait else { return }
        pendingTap = nil
        ctaWaiting = false
        pending.done(d)
    }

    private func startCheck(_ fieldId: String) {
        guard var s = fields[fieldId], !ended else { return }
        guard hasHost() else { endWithoutHost(fieldId); return }
        cancelFlight(fieldId)
        seq += 1
        let mySeq = seq
        let value = s.value
        let started = now()
        flights[fieldId] = (mySeq, {}, {}, started)
        let cancel = startCall(fieldId, value, Double(s.config.timeoutMs) / 1000) { [weak self] outcome in
            self?.complete(fieldId, seq: mySeq, outcome)
        }
        // Completed synchronously (a host known not to implement the hook): nothing more to arm.
        guard flights[fieldId]?.seq == mySeq else { return }
        let cancelTimeout = schedule(Double(s.config.timeoutMs) / 1000) { [weak self] in
            self?.timedOut(fieldId, seq: mySeq)
        }
        flights[fieldId] = (mySeq, cancel, cancelTimeout, started)
        s.phase = .checking
        s.message = s.config.checkingText
        s.reason = nil
        fields[fieldId] = s
    }

    private func complete(_ fieldId: String, seq mySeq: Int, _ outcome: HostOutcome) {
        guard let flight = flights[fieldId], flight.seq == mySeq, !ended else { return }
        flights[fieldId] = nil
        flight.cancelTimeout()
        guard var s = fields[fieldId] else { return }
        defer { reevaluateTap() }
        switch outcome {
        case .notImplemented:
            endWithoutHost(fieldId)
            return
        case .answered(let result?):
            s = apply(result, to: s)
            remember(fieldId, s.value, result)
        case .answered(nil), .threw:
            s = unavailable(s, reason: isOnline() ? "error" : "offline")
        }
        fields[fieldId] = s
        emit(fieldId, s, latency: now() - flight.started)
    }

    private func timedOut(_ fieldId: String, seq mySeq: Int) {
        guard let flight = flights[fieldId], flight.seq == mySeq, !ended, var s = fields[fieldId] else { return }
        flights[fieldId] = nil
        flight.cancel()
        s = unavailable(s, reason: isOnline() ? "timeout" : "offline")
        fields[fieldId] = s
        emit(fieldId, s, latency: now() - flight.started)
        reevaluateTap()
    }

    private func endWithoutHost(_ fieldId: String) {
        guard var s = fields[fieldId] else { return }
        s = unavailable(s, reason: "no_delegate")
        fields[fieldId] = s
        if warned.insert(fieldId).inserted {
            warn("remote_validation is on for field \"\(fieldId)\" but the host app does not implement onValidateInput")
            emit(fieldId, s, latency: 0)
        }
    }

    private func apply(_ result: InputValidationResult, to state: FieldState) -> FieldState {
        var s = state
        s.reason = nil
        switch result {
        case .valid(let m):
            s.phase = .valid
            s.message = m ?? s.config.validText
        case .invalid(let m):
            s.phase = .invalid
            s.message = m ?? s.config.invalidText ?? RemoteValidationConfig.builtInInvalid
        }
        return s
    }

    private func unavailable(_ state: FieldState, reason: String) -> FieldState {
        var s = state
        s.phase = .unavailable
        s.reason = reason
        s.message = Self.unavailableMessage(s.config, reason: reason, blocks: s.config.blocksWhenUnavailable)
        return s
    }

    /// Offline always says so (the field re-checks by itself when the connection returns); any other "no answer"
    /// shows a message only when the field blocks on it.
    static func unavailableMessage(_ c: RemoteValidationConfig, reason: String?, blocks: Bool) -> String? {
        if reason == "offline" { return c.offlineText ?? RemoteValidationConfig.builtInOffline }
        return blocks ? (c.unavailableText ?? RemoteValidationConfig.builtInUnavailable) : nil
    }

    private func emit(_ fieldId: String, _ s: FieldState, latency: TimeInterval) {
        var props: [String: Any] = [
            "field_id": fieldId,
            "status": s.phase.rawValue,
            "latency_ms": Int((latency * 1000).rounded()),
        ]
        if let r = s.reason { props["reason"] = r }
        track(props)
    }

    private func cancelDebounce(_ fieldId: String) {
        debounce.removeValue(forKey: fieldId)?()
    }

    private func cancelFlight(_ fieldId: String) {
        guard let f = flights.removeValue(forKey: fieldId) else { return }
        f.cancelTimeout()
        f.cancel()
    }

    private func cacheKey(_ fieldId: String, _ value: String) -> String { "\(fieldId)\u{0}\(value)" }

    private func remember(_ fieldId: String, _ value: String, _ result: InputValidationResult) {
        let key = cacheKey(fieldId, value)
        if cache.updateValue(result, forKey: key) == nil { cacheOrder.append(key) }
        while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }
}

// MARK: - What the views read

/// The step's live-validation state as the block views read it, through the environment. A VALUE, so every change of
/// a field's state or of the CTA wait re-renders the views that read it; the coordinator rides along for the
/// views' own inputs (value changes, return, focus lost) and is not part of the equality.
struct RemoteValidationEnv: Equatable {
    let coordinator: RemoteValidationCoordinator
    let fields: [String: RemoteValidationCoordinator.FieldState]
    let ctaWaiting: Bool
    /// Progress is drawn only once the host is known to answer (iOS learns that from the first call).
    let drawsProgress: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.coordinator === b.coordinator && a.fields == b.fields && a.ctaWaiting == b.ctaWaiting && a.drawsProgress == b.drawsProgress
    }

    /// Whether the step's CTA draws in its disabled colour: a field is invalid, or unavailable under "block".
    func blocksCta(_ blocks: [ContentBlock], inputValues: [String: Any]) -> Bool {
        for b in blocks {
            guard let config = RemoteValidationConfig.of(b), let s = fields[b.field_id ?? b.id] else { continue }
            guard let v = inputValues[b.field_id ?? b.id] as? String, !v.isEmpty, v == s.value else { continue }
            if s.phase == .invalid { return true }
            if s.phase == .unavailable && config.blocksWhenUnavailable { return true }
        }
        return false
    }
}

private struct RemoteValidationEnvKey: EnvironmentKey {
    static let defaultValue: RemoteValidationEnv? = nil
}

extension EnvironmentValues {
    var appdnaRemoteValidation: RemoteValidationEnv? {
        get { self[RemoteValidationEnvKey.self] }
        set { self[RemoteValidationEnvKey.self] = newValue }
    }
}

/// The border a validated text input strokes for its state: invalid → `error_border_color`
/// (#DC2626), valid → `valid_border_color` (#16A34A), in progress → `checking_border_color`, else the focused colour,
/// else the resting rule (`textInputBorderHex`). Idle, unchecked and unavailable draw the ordinary border.
func remoteValidationBorderHex(_ style: FormFieldBlockStyle?, focused: Bool, phase: RemoteValidationCoordinator.Phase?, drawsProgress: Bool) -> String {
    func authored(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
    switch phase {
    case .invalid: return authored(style?.error_border_color) ?? "#DC2626"
    case .valid: return authored(style?.valid_border_color) ?? "#16A34A"
    case .waiting?, .checking? where drawsProgress:
        return authored(style?.checking_border_color) ?? authored(style?.focused_border_color) ?? textInputBorderHex(style, focused: focused, hasError: false)
    default: return textInputBorderHex(style, focused: focused, hasError: false)
    }
}

/// The colour of the message under a validated field.
func remoteValidationMessageHex(_ style: FormFieldBlockStyle?, phase: RemoteValidationCoordinator.Phase, blocksWhenUnavailable: Bool) -> String {
    func authored(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
    switch phase {
    case .invalid: return authored(style?.error_text_color) ?? "#DC2626"
    case .valid: return authored(style?.valid_text_color) ?? authored(style?.valid_border_color) ?? "#16A34A"
    case .unavailable where blocksWhenUnavailable: return authored(style?.error_text_color) ?? "#DC2626"
    default: return "#6B7280"
    }
}
