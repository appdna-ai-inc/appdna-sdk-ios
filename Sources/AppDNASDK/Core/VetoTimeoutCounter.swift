import Foundation

/// How many host vetoes have timed out and silently fallen back to
/// their default. A timed-out `onPromoCodeSubmit` drops a sale; a timed-out `shouldShowMessage`
/// bypasses the host's guard. Neither is visible today, which is why the counter exists at all.
/// Surfaced through `diagnose()`; incremented by the wrapper's veto timer.
internal enum VetoTimeoutCounter {
    private static let lock = NSLock()
    private static var _count = 0

    static var count: Int {
        lock.lock(); defer { lock.unlock() }; return _count
    }

    static func increment() {
        lock.lock(); _count += 1; lock.unlock()
    }

    static func reset() {
        lock.lock(); _count = 0; lock.unlock()
    }
}
