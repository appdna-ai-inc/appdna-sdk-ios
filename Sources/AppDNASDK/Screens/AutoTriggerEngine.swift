import Foundation

/// Evaluates trigger rules from ScreenIndex entries on each event, session start, and screen transition.
internal class AutoTriggerEngine {

    private var impressionCounts: [String: Int] = [:]  // screenId -> count
    private var lastShownTimes: [String: Date] = [:]   // screenId -> last shown timestamp
    private var shownThisSession: Set<String> = []

    func resetSession() {
        shownThisSession.removeAll()
    }

    /// Evaluate all triggers for a given event. Returns the screen ID to show (highest priority), or nil.
    func evaluate(
        entries: [ScreenIndexEntry],
        event: String,
        properties: [String: Any]?,
        userTraits: [String: Any],
        sessionCount: Int,
        daysSinceInstall: Int,
        currentScreenName: String?
    ) -> String? {
        let now = Date()

        let matching = entries
            .filter { entry in
                guard entry.id != nil else { return false }
                return evaluateEntry(entry, event: event, properties: properties, userTraits: userTraits,
                             sessionCount: sessionCount, daysSinceInstall: daysSinceInstall,
                             currentScreenName: currentScreenName, now: now)
            }
            .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }

        if let best = matching.first, let bestId = best.id {
            // Mark as shown
            impressionCounts[bestId, default: 0] += 1
            lastShownTimes[bestId] = now
            shownThisSession.insert(bestId)
            return bestId
        }

        return nil
    }

    private func evaluateEntry(
        _ entry: ScreenIndexEntry,
        event: String,
        properties: [String: Any]?,
        userTraits: [String: Any],
        sessionCount: Int,
        daysSinceInstall: Int,
        currentScreenName: String?,
        now: Date
    ) -> Bool {
        // Check scheduling
        if let startDate = entry.start_date,
           let date = ISO8601.date(from: startDate),
           date > now { return false }
        if let endDate = entry.end_date,
           let date = ISO8601.date(from: endDate),
           date < now { return false }

        // Check audience rules
        if let audienceRules = entry.audience_rules {
            if !AudienceRuleEvaluator.evaluate(rules: audienceRules, userTraits: userTraits) {
                return false
            }
        }

        guard let triggerRules = entry.trigger_rules else { return false }

        // Check frequency
        let entryId = entry.id ?? ""
        if let frequency = triggerRules.frequency {
            if let maxImpressions = frequency.max_impressions,
               (impressionCounts[entryId] ?? 0) >= maxImpressions {
                return false
            }
            if frequency.once_per_session == true, shownThisSession.contains(entryId) {
                return false
            }
            if let cooldownHours = frequency.cooldown_hours,
               let lastShown = lastShownTimes[entryId] {
                let cooldownSeconds = Double(cooldownHours) * 3600
                if now.timeIntervalSince(lastShown) < cooldownSeconds {
                    return false
                }
            }
        }

        var anyTriggerMatched = false

        // Event triggers
        if let events = triggerRules.events {
            for trigger in events {
                if trigger.event_name == event {
                    if let conditions = trigger.conditions, let props = properties {
                        let allMatch = conditions.allSatisfy { cond in
                            guard let field = cond.field else { return false }
                            return ConditionEvaluator.valuesEqual(props[field], cond.value?.value)
                        }
                        if allMatch { anyTriggerMatched = true }
                    } else {
                        anyTriggerMatched = true
                    }
                }
            }
        }

        // Session count triggers. min/max/exact — mirrors Android's `minOk && maxOk && (min|max)` so a
        // MAX-ONLY rule ("first N sessions": session_count.max=3, no min) fires. iOS previously had no
        // max-only branch (only exact / min+max / min-only), so a max-only campaign never presented on
        // iOS while Android showed it.
        if let sessionTrigger = triggerRules.session_count {
            if let exact = sessionTrigger.exact {
                if sessionCount == exact { anyTriggerMatched = true }
            } else {
                let minOk = sessionTrigger.min.map { sessionCount >= $0 } ?? true
                let maxOk = sessionTrigger.max.map { sessionCount <= $0 } ?? true
                if (sessionTrigger.min != nil || sessionTrigger.max != nil) && minOk && maxOk {
                    anyTriggerMatched = true
                }
            }
        }

        // Days since install triggers. Same min/max shape — a MAX-ONLY rule ("first N days":
        // days_since_install.max=7) fires. iOS previously gated the whole block on `if let min`, so a
        // max-only rule never fired while Android's `minOk && maxOk` presented it.
        if let timeTrigger = triggerRules.days_since_install {
            let minOk = timeTrigger.min.map { daysSinceInstall >= $0 } ?? true
            let maxOk = timeTrigger.max.map { daysSinceInstall <= $0 } ?? true
            if (timeTrigger.min != nil || timeTrigger.max != nil) && minOk && maxOk {
                anyTriggerMatched = true
            }
        }

        // Screen-based triggers
        if let onScreen = triggerRules.on_screen, let current = currentScreenName {
            if matchGlob(pattern: onScreen, string: current) {
                anyTriggerMatched = true
            }
        }

        // User trait triggers
        if let traitConditions = triggerRules.user_traits, !traitConditions.isEmpty {
            let allTraitsMatch = traitConditions.allSatisfy { cond in
                // Evaluated as an audience rule: every operator the console offers, a stored null read as
                // not set, and an unknown operator failing closed (it used to fire for every user).
                guard let trait = cond.trait else { return true }
                return AudienceRuleEvaluator.evaluateRule(
                    AudienceRule(trait: trait, operator: cond.operator, value: cond.value), userTraits: userTraits
                )
            }
            if allTraitsMatch { anyTriggerMatched = true }
        }

        return anyTriggerMatched
    }

    private func matchGlob(pattern: String, string: String) -> Bool {
        let p = pattern.lowercased()
        let s = string.lowercased()
        if !p.contains("*") { return p == s }
        if p.hasPrefix("*") && p.hasSuffix("*") { return s.contains(String(p.dropFirst().dropLast())) }
        if p.hasPrefix("*") { return s.hasSuffix(String(p.dropFirst())) }
        if p.hasSuffix("*") { return s.hasPrefix(String(p.dropLast())) }
        return p == s
    }
}
