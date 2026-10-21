import RiveRuntime
import SwiftUI

public struct RiveBlock: Codable {
    public let rive_url: String
    public let artboard: String?
    public let state_machine: String?
    public let autoplay: Bool
    public let height: Double
    public let alignment: String
    public let inputs: [String: AnyCodable]?
    public let trigger_on_step_complete: String?
}

public struct RiveBlockView: View {
    let block: RiveBlock

    /*
     * 🔴 `SwiftUI.Alignment`, qualified. `RiveRuntime` exports an `Alignment` of its own, so the
     * bare name is ambiguous the moment this file imports it — and the error ("'Alignment' is
     * ambiguous for type lookup in this context") names the line, not the cause.
     */
    private var alignmentValue: SwiftUI.Alignment {
        switch block.alignment {
        case "left": return .leading
        case "right": return .trailing
        default: return .center
        }
    }

    public var body: some View {
        /*
         #982 — THE REAL ENGINE. This drew a blue placeholder box reading "Rive Animation" for as
         long as the block type has existed, while Android drove a real `RiveAnimationView`.

         🔴 `RiveViewModel` is built ONCE per block and held in `@StateObject`, not rebuilt in
         `body`. A view model recreated on every re-render restarts the animation each time the
         parent redraws — which on an onboarding step is every keystroke in a field beside it.

         🔴 A URL that fails to load draws NOTHING rather than a broken frame. Rive reports the
         failure asynchronously, so the model is asked for its state rather than assumed good, and
         the block collapses the way a missing image does.
        */
        RiveBlockHost(block: block)
            .frame(height: CGFloat(block.height))
            .frame(maxWidth: .infinity, alignment: alignmentValue)
    }
}

/// Holds the `RiveViewModel` for one block's lifetime.
///
/// Split from `RiveBlockView` because `@StateObject` has to be initialised from the block's own
/// values exactly once, and a `public` view that other modules construct cannot own that
/// initialisation without exposing the model type in its signature.
private struct RiveBlockHost: View {
    let block: RiveBlock

    @StateObject private var model: RiveModelBox

    init(block: RiveBlock) {
        self.block = block
        _model = StateObject(wrappedValue: RiveModelBox(block: block))
    }

    var body: some View {
        Group {
            if let viewModel = model.viewModel {
                viewModel.view()
                    /*
                     🔴 #1024 — AFTER THE FILE HAS LOADED, NOT ON APPEAR.
                     *
                     `RiveViewModel(webURL:)` fetches over the network, so at `.onAppear` there is
                     no artboard and no state machine to set an input on: every `setInput` went
                     nowhere and the animation drew its default state. Measured on a device —
                     three artboards authored `BlendAmount` 0 / 100 / 0 came back PIXEL-IDENTICAL
                     on this platform (mean |diff| 0.0 on every channel) while Android, which
                     applies inputs in its load callback, drew the 0 and the 100 differently with
                     an exactly-0.0 control between the two 0s.
                     *
                     The wait is bounded: a file that never loads draws nothing anyway, and
                     blocking forever on it would leak a task per block.
                     *
                     `task(id:)` re-runs when the authored inputs change, which is the parity for
                     Android's `update` block re-applying them on recomposition — a question answer
                     driving an input is the case both exist for.
                     */
                    .task(id: inputsSignature) {
                        guard let inputs = block.inputs, !inputs.isEmpty else { return }
                        /*
                         🔴 A FEW SPACED ATTEMPTS, NOT A TIGHT POLL. The first version of this
                         looped every 50ms until the artboard appeared, and TWO OF THREE artboards
                         on the walk's screen stopped drawing at all — three views each waking the
                         main actor twenty times a second is exactly the window in which Rive is
                         parsing and standing up its Metal view. Measured: one artboard drew where
                         three had before.
                         *
                         Applying an input twice is harmless (it is a set, not an increment), so
                         the cheap and safe shape is a handful of attempts over a few seconds.
                         */
                        for delayMs in RiveInputApply.attemptDelaysMs {
                            if delayMs > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                            }
                            if Task.isCancelled { return }
                            /*
                             🔴 THE STATE MACHINE, NOT THE ARTBOARD. An artboard exists before the
                             machine is instantiated, and an input set in that window lands
                             somewhere between the two: measured, the three artboards on the walk's
                             screen each caught a different moment and came back at three different
                             poses — two that should have been identical 29px apart, and the third
                             still at its default. Waiting for the thing the input is actually set
                             ON makes all three deterministic.
                             *
                             A block with no `state_machine` named has no machine to wait for, and
                             its inputs cannot apply at all (Rive's setters are per machine) — so
                             the artboard is the right thing to wait for there, and the apply below
                             is what logs the failure.
                             */
                            let ready = block.state_machine?.isEmpty == false
                                ? viewModel.riveModel?.stateMachine != nil
                                : viewModel.riveModel?.artboard != nil
                            guard ready else { continue }
                            applyInputs(inputs, to: viewModel)
                            return
                        }
                        Log.warning(
                            "RiveBlockView: \(inputs.count) authored input(s) were SKIPPED — "
                            + "\(block.rive_url) had no artboard after "
                            + "\(RiveInputApply.attemptDelaysMs.reduce(0, +))ms, so there was "
                            + "nothing to set them on.",
                        )
                    }
            } else {
                // Not loaded (bad URL, wrong artboard, failed fetch) — draw nothing, as a missing
                // image does, rather than a frame with our text in it.
                EmptyView()
            }
        }
    }

    /**
     Authored state-machine inputs, applied once the machine is running.

     Rive distinguishes three input kinds and the SDK only ever receives JSON, so the mapping is by
     VALUE TYPE: a bool sets a boolean input, a number sets a number input, and anything else is
     treated as a trigger — which is what an author writing `{"jump": true}` against a trigger
     expects, and the only interpretation that cannot silently do nothing.
    */
    private func applyInputs(_ inputs: [String: AnyCodable], to viewModel: RiveViewModel) {
        /*
         🔴 #1024 — THE KIND COMES FROM `RiveInputKind`, which Android calls too. The mapping was
         written twice in two languages and the two disagreed: a STRING fired a trigger here and
         was ignored entirely on Android, so one authored document produced two behaviours and the
         silent one was the other platform's.
         */
        for (name, value) in inputs {
            switch RiveInputKind.of(value.value) {
            case .boolean: viewModel.setInput(name, value: (value.value as? Bool) ?? false)
            case .number: viewModel.setInput(name, value: riveNumber(value.value) ?? 0)
            case .trigger: viewModel.triggerInput(name)
            case nil: continue  // a null is not an instruction
            }
        }
    }

    /// A value that changes when the AUTHORED inputs do, so `task(id:)` re-applies them.
    /// Sorted, because a dictionary's order is not stable and an unstable id would re-run forever.
    private var inputsSignature: String {
        (block.inputs ?? [:])
            .map { "\($0.key)=\(String(describing: $0.value.value))" }
            .sorted()
            .joined(separator: "\u{1F}")
    }

    /// Every JSON number shape this can arrive as, as a `Double`.
    private func riveNumber(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let f as Float: return Double(f)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
}

/// `RiveViewModel` is not an `ObservableObject`, so it is boxed in one to live in `@StateObject`.
private final class RiveModelBox: ObservableObject {
    let viewModel: RiveViewModel?

    init(block: RiveBlock) {
        guard URL(string: block.rive_url) != nil else {
            viewModel = nil
            return
        }
        viewModel = RiveViewModel(
            webURL: block.rive_url,
            stateMachineName: block.state_machine,
            autoPlay: block.autoplay,
            artboardName: block.artboard
        )
    }
}
