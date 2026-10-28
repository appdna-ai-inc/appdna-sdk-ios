// LocationSearchRig.swift
//
// Drives the REAL `LocationSuggestionSearch`, the one state holder both iOS
// location surfaces bind to, with its three dependencies injected:
//
//   - the debounce clock is MANUAL: a debounced search stays pending until `advance(ms:)` passes its
//     due time, so CI timing can never fire it early (a held stub would already have counted it);
//   - the autocomplete fetch answers at once from a table keyed by query, through the REAL suggestion
//     decoder (`LocationAnswer.decodeSuggestionItems`), and records every listing request;
//   - the resolve call is HELD: `tap` records the body the holder built, and `reply(…)` answers it
//     through the REAL reply parser (`LocationResolve.outcome`).
//
// The holder's writes are captured the way a view's `attach(store:)` persists them.
//
// `echo()` is what SwiftUI's `.onChange(of:)` does after a programmatic set: it calls `textChanged`
// with the holder's text — and only when that text differs from the last value delivered, because
// SwiftUI sends nothing for an unchanged value. A script that never calls it is the Compose shape.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

final class LocationSearchRig {

    private(set) var holder: LocationSuggestionSearch!
    let settings: LocationSearchSettings

    /// Every listing request the fetch was asked for, in order.
    private(set) var listings: [LocationListingRequest] = []
    var autocompleteQueries: [String] { listings.map(\.query) }
    /// Every resolve body sent, in order.
    private(set) var resolveBodies: [[String: Any]] = []
    /// Answers for resolves still in flight, oldest first.
    private var pendingResolves: [(LocationResolveOutcome) -> Void] = []
    var resolvesInFlight: Int { pendingResolves.count }

    /// What the view would have persisted. `nil` = no answer.
    private(set) var stored: Any?
    private(set) var storeWrites = 0
    /// Every typed text (a String answer) the holder stored, in order.
    private(set) var storedTexts: [String] = []

    /// The autocomplete stub's replies, by query. An unlisted query answers [].
    var autocomplete: [String: [[String: Any]]]

    // The manual clock.
    private(set) var now = 0
    private var timers: [PendingWork] = []
    private var timerSeq = 0
    private final class PendingWork {
        let due: Int; let seq: Int; let work: () -> Void
        var cancelled = false
        init(due: Int, seq: Int, work: @escaping () -> Void) { self.due = due; self.seq = seq; self.work = work }
    }

    /// The last text `textChanged` was given — what SwiftUI's `.onChange` compares against.
    private var lastDelivered: String

    init(
        settings: LocationSearchSettings,
        storedAnswer: Any? = nil,
        autocomplete: [String: [[String: Any]]] = [:]
    ) {
        self.settings = settings
        self.autocomplete = autocomplete
        self.stored = storedAnswer
        self.lastDelivered = ""
        holder = LocationSuggestionSearch(
            storedAnswer: storedAnswer,
            fetch: { [unowned self] listing, done in
                self.listings.append(listing)
                done(LocationAnswer.decodeSuggestionItems(self.autocomplete[listing.query] ?? []))
            },
            resolve: { [unowned self] body, done in
                self.resolveBodies.append(body)
                self.pendingResolves.append(done)
            },
            schedule: { [unowned self] delayMs, work in
                self.timerSeq += 1
                let timer = PendingWork(due: self.now + delayMs, seq: self.timerSeq, work: work)
                self.timers.append(timer)
                return { timer.cancelled = true }
            }
        )
        // The view's first render sees the (possibly restored) text without an `.onChange`.
        lastDelivered = holder.text
        holder.attach(store: { [unowned self] value in
            self.stored = value
            self.storeWrites += 1
            if let text = value as? String { self.storedTexts.append(text) }
        })
    }

    // MARK: - Ops

    /// A user edit: the text field changed, and the view forwards it.
    func type(_ text: String) {
        lastDelivered = text
        holder.textChanged(text, settings: settings)
    }

    /// SwiftUI's `.onChange` after the holder set its own text. No-op when the text is unchanged.
    /// An edit while the input method composes (or, with `composing` false, a commit that changed
    /// the text), as the text field delivers it: the field writes the text through the binding, then
    /// reports whether marked text remains (`compositionChanged`), then SwiftUI's `.onChange` delivers
    /// the text the holder holds by then — once, and only if it changed.
    func typeComposing(_ text: String, composing: Bool) {
        holder.text = text
        holder.compositionChanged(composing, settings: settings)
        deliverChange()
    }

    /// The input method commits without changing the text: the field reports no marked text, and
    /// `.onChange` delivers the text only if the commit changed it.
    func commit() {
        holder.compositionChanged(false, settings: settings)
        deliverChange()
    }

    /// The user moves the caret (or the selection) without typing. The text field reports its
    /// composition from the selection change (`textFieldDidChangeSelection`); SwiftUI's `.onChange`
    /// sends nothing, because the text did not change.
    func moveCaret() {
        holder.compositionChanged(false, settings: settings)
        deliverChange()
    }

    /// The input method sets or clears marked text without changing the text: the field reports the
    /// composition, and `.onChange` sends nothing.
    func compositionOnly(_ composing: Bool) {
        holder.compositionChanged(composing, settings: settings)
        deliverChange()
    }

    private func deliverChange() {
        guard holder.text != lastDelivered else { return }
        lastDelivered = holder.text
        holder.textChanged(holder.text, settings: settings)
    }

    func echo() {
        guard holder.text != lastDelivered else { return }
        lastDelivered = holder.text
        holder.textChanged(holder.text, settings: settings)
    }

    /// Advances the clock, firing every debounced search that falls due, in due order.
    func advance(ms: Int) {
        let target = now + ms
        while let next = timers
            .filter({ !$0.cancelled && $0.due <= target })
            .min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) {
            timers.removeAll { $0 === next }
            now = next.due
            next.work()
        }
        timers.removeAll { $0.cancelled || $0.due <= target }
        now = target
    }

    /// The user taps row `index` of the list on screen.
    func tap(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard holder.results.indices.contains(index) else {
            XCTFail("tap(\(index)): the list on screen has \(holder.results.count) row(s)", file: file, line: line)
            return
        }
        holder.select(at: index)
    }

    /// The oldest resolve in flight answers with `status` and the route's JSON `body`.
    func reply(status: Int, body: Any, file: StaticString = #filePath, line: UInt = #line) {
        guard !pendingResolves.isEmpty else {
            XCTFail("reply: no resolve call is in flight", file: file, line: line)
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        pendingResolves.removeFirst()(LocationResolve.outcome(status: status, data: data))
    }

    /// The oldest resolve in flight fails at the network.
    func replyNetworkError(file: StaticString = #filePath, line: UInt = #line) {
        guard !pendingResolves.isEmpty else {
            XCTFail("replyNetworkError: no resolve call is in flight", file: file, line: line)
            return
        }
        pendingResolves.removeFirst()(.failed(reason: "network"))
    }

    /// The stored answer changes outside the holder (a parent seeding it), as the view reports it.
    /// A restore it causes is a programmatic set: call `echo()` to deliver SwiftUI's `.onChange`.
    func storeFromOutside(_ value: Any?) {
        stored = value
        holder.storedAnswerChanged(value)
    }
}
