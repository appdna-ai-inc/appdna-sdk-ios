import Foundation

/**
 What a step advance CARRIES, as a pure function both the renderer and the fixture runner
 call. The mirror of Android's `StepAdvancePayload`, added for the same reason.

 🔴 It exists because a test that re-implements the thing under test can only ever agree with it.
 `SharedFixtureTests`'s flag-CTA branch assembled this dictionary itself, so the iOS suite passed
 **1542 tests, 0 failures** with the renderer's own `extra` merge deleted. The fixture was driving
 `OnboardingCTAFlag.parse` and `applyTo` for real — which its comment correctly claims — and nothing
 about the payload. Android had the identical gap and was measured the same way.

 The ordering is the behaviour worth pinning, and it is kept exactly as the renderer had it:

  - `toggle_<key>` entries first, then the form inputs. The prefix is what keeps the two namespaces
    from colliding; Android once merged raw toggle keys and broke cross-platform analytics and any
    `next_step_rules` authored against `toggle_<id>`.
  - `extra` LAST, so a form field cannot silently overwrite a flag the CTA recorded.
  - an empty dictionary answers `nil`, because `onNext(nil)` is how the SDK says "this step carried
    no answers", and an empty dictionary would be recorded as a step that answered nothing.

 🔴 Order is only observable on a key COLLISION, and the `toggle_` prefix means toggles and inputs
 cannot collide — so iOS putting toggles first and Android putting inputs first are equivalent. They
 are deliberately left as each platform had them rather than unified, because changing a live
 ordering to make two files look alike is a behaviour change dressed as tidying.
 */
enum StepAdvancePayload {

    static func build(
        inputValues: [String: Any],
        toggleValues: [String: Any],
        extra: [String: Any] = [:]
    ) -> [String: Any]? {
        var data: [String: Any] = [:]
        for (key, value) in toggleValues {
            data["toggle_\(key)"] = value
        }
        for (key, value) in inputValues {
            data[key] = value
        }
        for (key, value) in extra {
            data[key] = value
        }
        return data.isEmpty ? nil : data
    }
}
