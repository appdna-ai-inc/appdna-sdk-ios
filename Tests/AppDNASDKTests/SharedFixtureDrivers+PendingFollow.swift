// SharedFixtureDrivers+PendingFollow.swift
//
// iOS driver for `follow_pending_messages` (#1731): which ids the journey in-app message listener reads deliveries
// from, across configure / identify / reset. Driven through the REAL `PendingMessageListener.follow` and its REAL
// queueing, de-duplication and retry; only the two edges are replaced — the Firestore subscription (by a store that
// answers the listener's `consumed == false` query the way Firestore does: everything unconsumed at once when a
// listener opens, then each new document) and the screen (a presenter that draws synchronously when a window exists).
//
// `legacyUserOnly` replays the pre-#1731 rule (nothing before identify, the user id only after it) through the same
// listener, for the red control in `PendingMessageFollowTests`.
//
// © 2026 AppDNA AI, Inc.

import Foundation
import XCTest
@testable import AppDNASDK

/// The fake edges of a `follow_pending_messages` run, and what they observed.
final class PendingFollowRig {
    struct Doc { let owner: String; let id: String; let data: [String: Any]; var consumed: Bool }
    private(set) var docs: [Doc] = []
    private var listeners: [String: [UUID: (PendingMessageListener.Delivery) -> Void]] = [:]
    var windowAvailable = true
    private(set) var presented: [String] = []
    private var onScreen: (owner: String, close: () -> Void)?
    private var retries: [() -> Void] = []

    private func delivery(_ index: Int) -> PendingMessageListener.Delivery {
        let d = docs[index]
        return .init(id: d.id, data: d.data, markConsumed: { [weak self] in self?.docs[index].consumed = true })
    }

    lazy var listener: PendingMessageListener = PendingMessageListener(
        eventTracker: nil,
        subscribe: { [unowned self] _, _, id, onAdded in
            let token = UUID()
            self.listeners[id, default: [:]][token] = onAdded
            // Firestore's first snapshot for `consumed == false`: everything unconsumed already there.
            for (i, d) in self.docs.enumerated() where d.owner == id && !d.consumed { onAdded(self.delivery(i)) }
            return { [weak self] in self?.listeners[id]?[token] = nil }
        },
        present: { [unowned self] deliveryId, _, onShown, onClosed in
            guard self.windowAvailable else { return onShown(false) }
            let owner = self.ownerOf(deliveryId)
            self.presented.append("\(owner)/\(deliveryId)")
            self.onScreen = (owner, onClosed)
            onShown(true)
        },
        schedule: { [unowned self] _, block in self.retries.append(block) }
    )

    private func ownerOf(_ deliveryId: String) -> String { docs.last(where: { $0.id == deliveryId })?.owner ?? "?" }

    func deliver(to owner: String, id: String, title: String) {
        docs.append(Doc(owner: owner, id: id, data: [
            "content": ["title": title, "body": "Fixture body.", "cta_text": "OK"],
            "message_type": "modal", "trigger": "journey", "consumed": false,
        ], consumed: false))
        let i = docs.count - 1
        for cb in (listeners[owner] ?? [:]).values { cb(delivery(i)) }
    }

    func redeliver(to owner: String, id: String) {
        guard let i = docs.lastIndex(where: { $0.owner == owner && $0.id == id }) else { return }
        for cb in (listeners[owner] ?? [:]).values { cb(delivery(i)) }
    }

    func close() {
        let s = onScreen; onScreen = nil
        s?.close()
    }

    func runRetries() {
        let r = retries; retries = []
        r.forEach { $0() }
    }

    var unconsumed: [String] { docs.filter { !$0.consumed }.map { "\($0.owner)/\($0.id)" }.sorted() }
}

extension SharedFixtureTests {

    /// Runs a `follow_pending_messages` script; returns the state it produced (`presented`, `listening`, `unconsumed`).
    static func runPendingFollowScript(_ action: [String: AnyJSON], legacyUserOnly: Bool = false) -> [String: Any]? {
        guard let script = action["script"]?.arrayValue,
              let org = action["org_id"]?.stringValue, let app = action["app_id"]?.stringValue else { return nil }
        let rig = PendingFollowRig()
        var listening: [[String]] = []
        let prefix = "\(org)/\(app)/"
        for step in script {
            let o = step.objectValue ?? [:]
            switch o["op"]?.stringValue {
            case "window": rig.windowAvailable = o["available"]?.boolValue ?? true
            case "deliver":
                rig.deliver(to: o["to"]?.stringValue ?? "", id: o["id"]?.stringValue ?? "", title: o["title"]?.stringValue ?? "")
            case "redeliver": rig.redeliver(to: o["to"]?.stringValue ?? "", id: o["id"]?.stringValue ?? "")
            case "follow":
                let anon = o["anon_id"]?.stringValue
                let user = o["user_id"]?.stringValue
                rig.listener.follow(orgId: org, appId: app, anonId: legacyUserOnly ? nil : anon, userId: user)
                listening.append(rig.listener.observedKeys.map { String($0.dropFirst(prefix.count)) })
            case "close": rig.close()
            case "run_retries": rig.runRetries()
            default: return nil
            }
        }
        return ["presented": rig.presented, "listening": listening, "unconsumed": rig.unconsumed]
    }

    func runFollowPendingMessages(_ f: Fixture, _ h: Harness) {
        guard let state = Self.runPendingFollowScript(f.action.raw) else {
            return XCTFail("[\(f.id)] follow_pending_messages needs org_id, app_id and a script of known ops")
        }
        for (k, v) in state { h.state[k] = v }
    }
}
