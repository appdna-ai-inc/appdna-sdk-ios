import Foundation

/// Which button the user pressed to leave the current step, for a navigation rule that routes by it.
///
/// A rule branches on the press as an ordinary `answer_equals` on ``key``, so a flow authored this way
/// degrades safely on an older SDK: there is no such answer, the rule does not match, and the flow walks
/// on in order. The id lives here and is supplied only while the rules are evaluated, so it never
/// reaches `responses`, which is what webhooks and `onOnboardingCompleted` receive.
///
/// SINGLE-SHOT, like `PendingCompletionRoute`: `take()` reads and clears, so an advance that a press did
/// not cause (a timer, a Select) cannot route on a press from earlier.
final class OnboardingPressedButton: @unchecked Sendable {
    /// The reserved answer key the console writes on a button-pressed rule.
    static let key = "__button_pressed"

    static let shared = OnboardingPressedButton()

    private let lock = NSLock()
    private var buttonId: String?

    private init() {}

    /// The actions a press advances the step with. A press that stays (`link`, `rate_app`, a host
    /// action, `refresh_step`) must not be remembered for the advance that follows it.
    static func advances(action: String) -> Bool {
        ["next", "continue", OnboardingCTAFlag.actionName, PendingCompletionRoute.actionName, "permission"].contains(action)
    }

    func record(_ id: String, action: String) {
        guard Self.advances(action: action) else { return }
        lock.lock(); defer { lock.unlock() }
        buttonId = id
    }

    func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        let out = buttonId
        buttonId = nil
        return out
    }

    /// A press the required-field gate refused, or a new flow presented.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        buttonId = nil
    }

    /// `responses` with the press visible to the rules for `stepId`. Unchanged when no button was pressed.
    static func forRules(_ responses: [String: Any], stepId: String, pressed: String?) -> [String: Any] {
        guard let pressed else { return responses }
        var out = responses
        var own = out[stepId] as? [String: Any] ?? [:]
        own[key] = pressed
        out[stepId] = own
        return out
    }
}
