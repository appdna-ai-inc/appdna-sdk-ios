import SwiftUI

/// The step's half of the advance-while-resolving rule. Every location field on a step registers its
/// holder here; the step settles them when it ADVANCES — after its own required gate has passed,
/// before it hands its answers on — so a field whose resolve is still in flight stores the text the
/// user typed (`LocationSuggestionSearch.settleResolveInFlight`).
///
/// The holder's own `detach()` cannot do this alone: the views call it from `onDisappear`, which runs
/// after the step's Continue has already built and submitted its payload.
///
/// Provided through `\.locationAdvanceSettlement` by the form step (`FormStepView`) and by the
/// block-based step (`OnboardingStepRouter`). A field rendered with no step around it registers
/// nowhere and relies on `detach()`. Android's `LocationAdvanceSettlement` is the Kotlin twin.
final class LocationAdvanceSettlement {

    private struct Entry {
        let fieldId: String
        weak var holder: LocationSuggestionSearch?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(fieldId: String, holder: LocationSuggestionSearch) {
        entries[ObjectIdentifier(holder)] = Entry(fieldId: fieldId, holder: holder)
        Self.registeredForTesting?(fieldId, holder)
    }

    /// Test seam: told of every field that registers with a step, so a test driving a real step can
    /// reach a field it cannot touch through the accessibility tree (one inside a scroll view). Never
    /// set in production.
    static var registeredForTesting: ((String, LocationSuggestionSearch) -> Void)?

    func unregister(_ holder: LocationSuggestionSearch) {
        entries.removeValue(forKey: ObjectIdentifier(holder))
    }

    /// Settles every registered field. Each one with a resolve in flight writes its typed text
    /// through its own store (the step's answers) and is returned here as `field id → answer`.
    @discardableResult
    func settle() -> [String: Any] {
        var settled: [String: Any] = [:]
        for entry in entries.values {
            guard let holder = entry.holder else { continue }
            if let answer = holder.settleResolveInFlight() {
                settled[entry.fieldId] = answer
            }
        }
        return settled
    }

    /// Settles, then adds each settled answer to `data` where `data` holds none for that field.
    /// The payloads here are built from a `@State` copy of the answers, so the store's write is not
    /// relied on to have reached them. A key the payload already carries is kept — the SDK's own keys
    /// (`action`, …) win over a field id, as they do when the payload is built.
    func settleInto(_ data: [String: Any]?) -> [String: Any]? {
        let settled = settle()
        guard !settled.isEmpty else { return data }
        var merged = data ?? [:]
        for (fieldId, answer) in settled {
            if merged[fieldId] == nil || (merged[fieldId] as? String) == "" {
                merged[fieldId] = answer
            }
        }
        return merged
    }
}

private struct LocationAdvanceSettlementKey: EnvironmentKey {
    static let defaultValue: LocationAdvanceSettlement? = nil
}

extension EnvironmentValues {
    /// The step's `LocationAdvanceSettlement`; nil where no step provides one.
    var locationAdvanceSettlement: LocationAdvanceSettlement? {
        get { self[LocationAdvanceSettlementKey.self] }
        set { self[LocationAdvanceSettlementKey.self] = newValue }
    }
}
