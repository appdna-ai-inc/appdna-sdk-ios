import Foundation
import UIKit

// MARK: - Global modal mutex + queue (SDUI engine prerequisite)
// Ensures only one modal (paywall, onboarding, SDUI screen, message, survey)
// is presented at a time, with priority-based queuing.

internal class PresentationCoordinator {
    static let shared = PresentationCoordinator()

    private var isPresenting = false
    private var presentationQueue: [(type: PresentationType, action: () -> Void)] = []
    private var lastAutoTriggerTime: Date?
    private let maxQueueSize = 3
    private let autoTriggerCooldownSeconds: TimeInterval = 60

    private let lock = NSLock()

    enum PresentationType: Int, Comparable {
        case paywall = 0       // Highest priority
        case onboarding = 1
        case screen = 2
        case message = 3
        case survey = 4        // Lowest priority

        static func < (lhs: PresentationType, rhs: PresentationType) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    /// Request to present a modal. Returns true if presentation can proceed immediately.
    func requestPresentation(type: PresentationType, isAutoTriggered: Bool = false, action: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Check auto-trigger cooldown
        if isAutoTriggered {
            if let lastTime = lastAutoTriggerTime,
               Date().timeIntervalSince(lastTime) < autoTriggerCooldownSeconds {
                return false  // Cooldown active, drop
            }
        }

        if !isPresenting {
            isPresenting = true
            if isAutoTriggered {
                lastAutoTriggerTime = Date()
            }
            DispatchQueue.main.async { action() }
            return true
        }

        // Queue if another modal is visible
        if presentationQueue.count < maxQueueSize {
            presentationQueue.append((type: type, action: action))
            // Sort by priority (lower rawValue = higher priority)
            presentationQueue.sort { $0.type < $1.type }
            return false
        }

        return false  // Queue full, drop
    }

    /// Called when a modal is dismissed. Presents next queued item if any.
    func onDismissed() {
        lock.lock()

        if presentationQueue.isEmpty {
            isPresenting = false
            lock.unlock()
            return
        }

        let next = presentationQueue.removeFirst()
        lock.unlock()

        DispatchQueue.main.async {
            next.action()
        }
    }

    /// Check if presentation is allowed for a type (without actually presenting).
    func canPresent(type: PresentationType, isAutoTriggered: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isAutoTriggered {
            if let lastTime = lastAutoTriggerTime,
               Date().timeIntervalSince(lastTime) < autoTriggerCooldownSeconds {
                return false
            }
        }

        return !isPresenting || presentationQueue.count < maxQueueSize
    }

    /// Reset state (e.g., on app reset or consent revoked).
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        isPresenting = false
        presentationQueue.removeAll()
        lastAutoTriggerTime = nil
    }
}
