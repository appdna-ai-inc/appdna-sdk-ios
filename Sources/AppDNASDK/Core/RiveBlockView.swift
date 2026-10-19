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
                    .onAppear {
                        guard let inputs = block.inputs, !inputs.isEmpty else { return }
                        applyInputs(inputs, to: viewModel)
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
        for (name, value) in inputs {
            switch value.value {
            case let flag as Bool: viewModel.setInput(name, value: flag)
            case let number as Double: viewModel.setInput(name, value: number)
            case let number as Int: viewModel.setInput(name, value: Double(number))
            default: viewModel.triggerInput(name)
            }
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
