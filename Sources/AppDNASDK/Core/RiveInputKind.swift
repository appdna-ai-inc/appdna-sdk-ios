import Foundation

/*
 WHAT KIND OF RIVE INPUT AN AUTHORED VALUE MEANS, as one rule both platforms call.

 Rive distinguishes three input kinds — boolean, number and trigger — and the SDK only ever
 receives JSON, which has no way to say which one is meant. So the kind is inferred from the VALUE
 TYPE, and the two platforms inferred it differently:

   authored value      iOS before            Android before
   true / false        boolean input         boolean input
   42 / 3.5            number input          number input
   "go"                TRIGGER               ignored entirely

 One authored document, two behaviours — and the ignored case is the silent one: the animation
 plays its default state and nothing says the input did nothing.

 🔴 A STRING MEANS A TRIGGER, which is iOS's reading and the one kept. A trigger has no value to
 carry, so there is nothing else a string could sensibly mean, and an author who writes
 `{"celebrate": "now"}` against a trigger input has no other way to say it: the alternative is that
 triggers are unauthorable, which is what Android shipped.

 🔴 Android ALSO bailed before any of this when no `state_machine` was named — `block.state_machine
 ?: return` — so an authored input did nothing at all on that platform unless the machine was named
 too. Its setters need the name, so the requirement is real; what was wrong is that it was silent.
 Both platforms now log the skip, and the console says the field is required for inputs.
 */
public enum RiveInputKind: String {
    case boolean
    case number
    case trigger

    /**
     The kind an authored JSON value means. `nil` is not an instruction and sets nothing.

     🔴 Written as `if`s rather than a `switch`, because `case is Double, is Int, is NSNumber
     where !(value is Bool):` binds its `where` to the LAST pattern only — a Swift trap that reads
     as if it guards the whole list. The order below does the guarding instead, and it has to:
     a Swift `Bool` bridges to `NSNumber`, so `value is NSNumber` is TRUE for `true`, and asking
     about Bool second would make every boolean input a number input.
     */
    public static func of(_ value: Any?) -> RiveInputKind? {
        guard let value, !(value is NSNull) else { return nil }
        if value is Bool { return .boolean }
        if value is Double || value is Int || value is Float || value is NSNumber { return .number }
        return .trigger
    }
}

/*
 WHEN an authored input is applied, which is a question about the LOAD and not about the value.

 `RiveViewModel(webURL:)` fetches over the network, so at `.onAppear` there is no artboard and no
 state machine to set an input on. Android applies its inputs inside the load callback; this
 platform had nothing equivalent, so every `setInput` went nowhere and the animation drew its
 default state — measured on a device as three artboards authored 0 / 100 / 0 coming back
 PIXEL-IDENTICAL (mean |diff| 0.0 on every channel).
 */
public enum RiveInputApply {
    /// Delays before each attempt, in milliseconds. The first is immediate, for a model that is
    /// already loaded; the rest cover a cold fetch without waking the main actor in a tight loop.
    public static let attemptDelaysMs: [Int] = [0, 250, 750, 1500, 3000]
}
