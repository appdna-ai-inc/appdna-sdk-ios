import Foundation

/// Represents a web subscription entitlement from Stripe web checkout.
public struct WebEntitlement {
    public let isActive: Bool
    public let planName: String?
    public let priceId: String?
    public let interval: String?            // "month", "year"
    public let status: EntitlementStatus
    public let currentPeriodEnd: Date?
    public let trialEnd: Date?

    /// Convert to dictionary for Flutter/RN bridging and caching.
    public func toMap() -> [String: Any] {
        var map: [String: Any] = [
            "isActive": isActive,
            "status": status.rawValue,
        ]
        if let planName { map["planName"] = planName; map["plan_name"] = planName }
        if let priceId { map["priceId"] = priceId; map["price_id"] = priceId }
        if let interval { map["interval"] = interval }
        if let currentPeriodEnd {
            map["currentPeriodEnd"] = currentPeriodEnd.timeIntervalSince1970
            map["current_period_end"] = currentPeriodEnd.timeIntervalSince1970
        }
        if let trialEnd {
            map["trialEnd"] = trialEnd.timeIntervalSince1970
            map["trial_end"] = trialEnd.timeIntervalSince1970
        }
        return map
    }

    /// Initialize from Firestore document data.
    init(from data: [String: Any]) {
        let statusStr = data["status"] as? String ?? ""
        self.status = EntitlementStatus(rawValue: statusStr) ?? .canceled
        self.isActive = ["active", "trialing"].contains(statusStr)
        self.planName = data["plan_name"] as? String
        self.priceId = data["price_id"] as? String
        self.interval = data["interval"] as? String

        if let ts = data["current_period_end"] as? TimeInterval {
            self.currentPeriodEnd = Date(timeIntervalSince1970: ts)
        } else {
            self.currentPeriodEnd = nil
        }

        if let ts = data["trial_end"] as? TimeInterval {
            self.trialEnd = Date(timeIntervalSince1970: ts)
        } else {
            self.trialEnd = nil
        }
    }
}

/// Web subscription status.
public enum EntitlementStatus: String, Codable {
    case active
    case trialing
    case pastDue = "past_due"
    case canceled
}
