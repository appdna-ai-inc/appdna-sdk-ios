import Foundation
import SwiftUI
import UIKit
import WidgetKit

/*
 * THE "ADD WIDGET" BUTTON ACTION ON iOS: TEACH, THEN DETECT.
 *
 * No public iOS API lets an app add a widget to the Home Screen, or even offer to: `WidgetCenter`
 * can read the widgets the user has placed and reload their timelines, and nothing else. So an
 * `add_widget` button opens the how-to the author wrote (`howto_blocks_ios`) in a bottom sheet over
 * the step, and the SDK watches, best effort, for a new widget of the app's to appear.
 *
 * Detection is a SET DIFFERENCE of widget ids, read at the tap and again on return / on Done — never
 * a count compare, so a widget removed and another added in the same trip still reads as added, and
 * the new widget's `family` is well defined.
 *
 * The outcome reaches the step's answers as `widget_status` (`added` | `not_added` | `unavailable`),
 * merged through the ordinary advance, so `next_step_rules` branch on it like any other answer.
 *
 * Seams: `WidgetHostProbe` (does the app ship a WidgetKit extension?) takes a bundle, because under
 * XCTest `Bundle.main` is the test runner; `WidgetConfigurationsSource` wraps
 * `WidgetCenter.shared.getCurrentConfigurations(_:)`. `WidgetAddAttempt` is the state machine, driven
 * by the step router in production and by the tests and the shared-fixture runner through the seams.
 */

/// The step's answer key, and its values.
enum WidgetStatus: String {
    case added
    case notAdded = "not_added"
    case unavailable

    static let answerKey = "widget_status"
}

// MARK: - The step-scoped channel

/// How an `add_widget` button reaches the step it sits on, at ANY depth (row, stack, section
/// background, carousel page, multi-buttons child). The action string alone cannot carry the button's
/// how-to blocks, so the button hands over the decoded BLOCK itself — which is also why a child button
/// authored without an `id` works: nothing is looked up.
///
/// Provided by the onboarding step router at its root. Nil on Screens / SDUI and inside every sheet
/// (option sheet, how-to), where the button falls back to the ordinary action path.
struct WidgetActionChannel {
    static let actionName = "add_widget"

    private let onTap: (ContentBlock) -> Void

    init(_ onTap: @escaping (ContentBlock) -> Void) {
        self.onTap = onTap
    }

    func tap(_ block: ContentBlock) {
        onTap(block)
    }
}

private struct WidgetActionChannelKey: EnvironmentKey {
    static let defaultValue: WidgetActionChannel? = nil
}

extension EnvironmentValues {
    var appdnaWidgetAction: WidgetActionChannel? {
        get { self[WidgetActionChannelKey.self] }
        set { self[WidgetActionChannelKey.self] = newValue }
    }
}

// MARK: - Does the host app ship a widget?

/// Whether the host app embeds a WidgetKit extension: an `.appex` in the bundle's PlugIns whose
/// `NSExtension.NSExtensionPointIdentifier` is `com.apple.widgetkit-extension`.
struct WidgetHostProbe {
    static let widgetKitExtensionPoint = "com.apple.widgetkit-extension"

    var bundle: Bundle = .main

    func hasWidgetExtension() -> Bool {
        guard let plugIns = bundle.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: plugIns, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return false }
        for appex in entries where appex.pathExtension == "appex" {
            guard let info = NSDictionary(contentsOf: appex.appendingPathComponent("Info.plist")) as? [String: Any],
                  let ext = info["NSExtension"] as? [String: Any],
                  (ext["NSExtensionPointIdentifier"] as? String) == Self.widgetKitExtensionPoint else { continue }
            return true
        }
        return false
    }
}

// MARK: - What widgets the user has placed

/// One placed widget of the host app, as the SDK compares it. `id` stands for the widget's stable
/// identity (`WidgetInfo.id`); the set difference is taken over these values.
struct WidgetInstance: Hashable {
    let id: String
    let kind: String
    let family: String
}

/// Reads the host app's placed widgets. `nil` means the read failed or timed out: detection is then
/// unavailable, never guessed.
protocol WidgetConfigurationsSource {
    func read(_ completion: @escaping (Set<WidgetInstance>?) -> Void)
}

/// `WidgetCenter.shared.getCurrentConfigurations(_:)` (iOS 14+, so usable on the SDK's iOS 16 floor),
/// bounded: a read that has not answered within `timeout` counts as failed. The completion always runs
/// on the main thread, exactly once.
struct WidgetCenterConfigurationsSource: WidgetConfigurationsSource {
    static let defaultTimeout: TimeInterval = 1.0

    var timeout: TimeInterval = Self.defaultTimeout

    func read(_ completion: @escaping (Set<WidgetInstance>?) -> Void) {
        let once = WidgetReadOnce(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if once.finish(nil) {
                Log.debug("[Onboarding] add_widget: the widget configuration read timed out — detection unavailable for this read")
            }
        }
        WidgetCenter.shared.getCurrentConfigurations { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let infos):
                    Log.debug("[Onboarding] add_widget: \(infos.count) widget(s) placed: \(infos.map { String(describing: $0) })")
                    once.finish(Set(infos.map(WidgetInstance.init(info:))))
                case .failure(let error):
                    Log.debug("[Onboarding] add_widget: the widget configuration read failed (\(error)) — detection unavailable for this read")
                    once.finish(nil)
                }
            }
        }
    }
}

/// Main-thread single-shot completion: whichever of the answer and the timeout comes first wins.
private final class WidgetReadOnce {
    private var completion: ((Set<WidgetInstance>?) -> Void)?
    init(_ completion: @escaping (Set<WidgetInstance>?) -> Void) { self.completion = completion }
    @discardableResult
    func finish(_ value: Set<WidgetInstance>?) -> Bool {
        guard let c = completion else { return false }
        completion = nil
        c(value)
        return true
    }
}

extension WidgetInstance {
    /// `WidgetInfo` is `Identifiable` with itself as its id ("the stable identity of the widget") and
    /// `Hashable`, but exposes no identifier value. Its hash is that identity, and every read of an
    /// attempt happens in one process, where a hash is stable — so the hash is the id compared here.
    init(info: WidgetInfo) {
        self.init(id: "\(info.kind)#\(info.id.hashValue)", kind: info.kind, family: String(describing: info.family))
    }
}

// MARK: - The attempt state machine

/// One step's `add_widget` attempts. States `idle → howto → checking → done`, plus `reading`: the
/// bounded read of the widgets placed at the tap, before any event, during which a second tap is
/// ignored like any other.
///
/// | state    | event                      | effect → next |
/// |----------|----------------------------|---------------|
/// | idle     | tap, gate refused          | validation toast → idle (nothing emitted) |
/// | idle     | tap, no widget extension   | `widget_add_unavailable`, advance `unavailable` → done |
/// | idle     | tap                        | read S0 → `widget_add_tapped`, present how-to, `widget_howto_shown` → howto |
/// | howto    | active, S0 known           | read S1; S1−S0 non-empty → close(detected), `widget_howto_dismissed{detected}`, `widget_added{howto}`, advance `added` → done; else stay |
/// | howto    | Done                       | → checking; read S1 |
/// | checking | S1 read                    | `widget_added` / `widget_not_added`, close(cta), `widget_howto_dismissed{cta}`, advance → done |
/// | howto    | close (swipe / Close)      | `widget_howto_dismissed{via}` → idle (attempt retired, step NOT advanced) |
/// | any      | the step goes away         | attempt discarded, nothing emitted → idle |
///
/// A tap in any state but idle is ignored. `done` is terminal until the step is presented again.
/// A programmatic close (Done, detection) records its reason BEFORE dismissing, so the sheet's
/// `onDismiss` does not report it a second time as a swipe.
final class WidgetAddAttempt: ObservableObject {
    enum Phase: Equatable { case idle, reading, howto, checking, done }

    /// How a how-to was closed — the `via` of `widget_howto_dismissed`.
    enum CloseVia: String { case cta, detected, swipe, dismiss }

    /// The how-to the router presents.
    struct HowtoSheet: Identifiable {
        let id = UUID()
        let blockId: String
        let blocks: [ContentBlock]
    }

    /// What the attempt asks of the platform.
    struct Platform {
        var hasWidgetExtension: () -> Bool
        var configurations: WidgetConfigurationsSource

        static var live: Platform {
            Platform(hasWidgetExtension: { WidgetHostProbe().hasWidgetExtension() },
                     configurations: WidgetCenterConfigurationsSource())
        }
    }

    /// What the attempt asks of the step. Set on every tap by the router (`configure`).
    struct StepHooks {
        var flowId: String
        var stepId: String
        /// The step's required-field gate — the SAME gate the advance uses.
        var gate: () -> Bool
        /// The gate refused: show the step's validation toast.
        var onGateRefused: () -> Void
        var track: (String, [String: Any]) -> Void
        /// One advance per attempt, carrying the outcome as `widget_status`.
        var advance: (WidgetStatus) -> Void

        static let inert = StepHooks(flowId: "", stepId: "", gate: { false }, onGateRefused: {},
                                     track: { _, _ in }, advance: { _ in })
    }

    /// The presented how-to. Settable because SwiftUI's `.sheet(item:)` writes nil on a swipe.
    @Published var sheet: HowtoSheet?
    @Published private(set) var phase: Phase = .idle

    var platform: Platform
    private var hooks: StepHooks = .inert
    private var presentation: Int?
    /// The widgets placed at the tap. Nil when that read failed or timed out: detection is off for
    /// the attempt.
    private var before: Set<WidgetInstance>?
    private var blockId = ""
    /// Bumped whenever an attempt starts or is retired, so a read that answers late is dropped.
    private var serial = 0
    private var pendingClose: PendingClose?

    private enum PendingClose { case via(CloseVia), discarded }

    /// Test seam: the platform an attempt created without one uses (the step router creates its own).
    /// Nil in production.
    static var platformForTesting: Platform?

    init(platform: Platform? = nil) {
        self.platform = platform ?? Self.platformForTesting ?? .live
    }

    /// Hand the attempt the step it belongs to. A different `presentation` (the step shown again)
    /// starts from `idle`, whatever the previous presentation's attempt reached.
    func configure(presentation: Int, hooks: StepHooks) {
        if self.presentation != presentation {
            self.presentation = presentation
            retire()
            phase = .idle
        }
        self.hooks = hooks
    }

    // MARK: Events

    func tap(_ block: ContentBlock) {
        guard phase == .idle else {
            Log.debug("[Onboarding] add_widget tapped while an attempt is live (\(phase)) — ignored")
            return
        }
        // The gate comes first: a refused gate starts nothing and emits nothing.
        guard hooks.gate() else {
            hooks.onGateRefused()
            return
        }
        guard platform.hasWidgetExtension() else {
            Log.warning("add_widget: this app ships no WidgetKit extension, so there is no widget to add; "
                + "advancing with widget_status=unavailable")
            self.track(event: "widget_add_unavailable", properties: ["reason": "no_widget"])
            finish(.unavailable)
            return
        }
        serial += 1
        let attempt = serial
        blockId = block.id
        let howto = block.howto_blocks_ios ?? []
        phase = .reading
        platform.configurations.read { [weak self] placed in
            guard let self, self.serial == attempt, self.phase == .reading else { return }
            self.before = placed
            self.track(event: "widget_add_tapped", properties: [
                "block_id": self.blockId,
                "existing_count": placed.map { $0.count as Any } ?? NSNull(),
            ])
            guard !howto.isEmpty else {
                // A flow authored before the how-to existed: there is nothing to teach and no Done to
                // wait for, so the attempt ends as Done would, without a sheet.
                Log.warning("add_widget: the button has no iOS how-to; ending the attempt without one")
                self.phase = .checking
                self.check(attempt: attempt, closeSheet: false)
                return
            }
            self.sheet = HowtoSheet(blockId: self.blockId, blocks: howto)
            self.phase = .howto
            self.track(event: "widget_howto_shown", properties: ["block_id": self.blockId])
        }
    }

    /// `UIApplication.didBecomeActiveNotification`: the user may be back from the Home Screen.
    func appDidBecomeActive() {
        guard phase == .howto, let before else { return }
        let attempt = serial
        platform.configurations.read { [weak self] placed in
            guard let self, self.serial == attempt, self.phase == .howto, let placed,
                  let added = Self.firstAdded(before: before, after: placed) else { return }
            self.close(.detected)
            self.track(event: "widget_howto_dismissed", properties: ["via": CloseVia.detected.rawValue])
            self.track(event: "widget_added", properties: ["method": "howto", "family": added.family])
            self.finish(.added)
        }
    }

    /// The how-to's Done (`next` / `continue`).
    func doneTapped() {
        guard phase == .howto else { return }
        phase = .checking
        check(attempt: serial, closeSheet: true)
    }

    /// The how-to's Close (`dismiss`) button. Returns to the step without advancing.
    func closeTapped() {
        guard phase == .howto else { return }
        self.track(event: "widget_howto_dismissed", properties: ["via": CloseVia.dismiss.rawValue])
        close(.dismiss)
        retire()
        phase = .idle
    }

    /// The sheet's `onDismiss`. A close the SDK made itself has its reason recorded already; any other
    /// is the user swiping the sheet away.
    func sheetDidDismiss() {
        if pendingClose != nil {
            pendingClose = nil
            return
        }
        guard phase == .howto else {
            // `checking` disables the swipe; if one lands anyway the Done has already decided.
            return
        }
        self.track(event: "widget_howto_dismissed", properties: ["via": CloseVia.swipe.rawValue])
        retire()
        phase = .idle
    }

    /// The step went away: the attempt is discarded, with no status and no event.
    func discard() {
        guard phase != .idle && phase != .done else { return }
        if sheet != nil {
            pendingClose = .discarded
            sheet = nil
        }
        retire()
        phase = .idle
    }

    // MARK: Internals

    /// The new widget, if any: the first of `after − before`, by id so the choice is deterministic.
    static func firstAdded(before: Set<WidgetInstance>, after: Set<WidgetInstance>) -> WidgetInstance? {
        after.subtracting(before).sorted { $0.id < $1.id }.first
    }

    private func check(attempt: Int, closeSheet: Bool) {
        guard let before else {
            conclude(added: nil, detection: "unavailable", closeSheet: closeSheet)
            return
        }
        platform.configurations.read { [weak self] placed in
            guard let self, self.serial == attempt, self.phase == .checking else { return }
            guard let placed else {
                self.conclude(added: nil, detection: "unavailable", closeSheet: closeSheet)
                return
            }
            self.conclude(added: Self.firstAdded(before: before, after: placed), detection: "ok", closeSheet: closeSheet)
        }
    }

    private func conclude(added: WidgetInstance?, detection: String, closeSheet: Bool) {
        if let added {
            self.track(event: "widget_added", properties: ["method": "howto", "family": added.family])
        } else {
            self.track(event: "widget_not_added", properties: ["method": "howto", "detection": detection])
        }
        if closeSheet {
            close(.cta)
            self.track(event: "widget_howto_dismissed", properties: ["via": CloseVia.cta.rawValue])
        }
        finish(added == nil ? .notAdded : .added)
    }

    /// Dismiss the sheet, recording why first so `onDismiss` does not report it again.
    private func close(_ via: CloseVia) {
        guard sheet != nil else { return }
        pendingClose = .via(via)
        sheet = nil
    }

    private func finish(_ status: WidgetStatus) {
        phase = .done
        hooks.advance(status)
    }

    private func retire() {
        serial += 1
        before = nil
    }

    private func track(event name: String, properties extra: [String: Any]) {
        var props: [String: Any] = ["flow_id": hooks.flowId, "step_id": hooks.stepId]
        props.merge(extra) { _, new in new }
        hooks.track(name, props)
    }
}
