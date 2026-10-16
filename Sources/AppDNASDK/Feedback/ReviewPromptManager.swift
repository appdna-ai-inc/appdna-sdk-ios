import Foundation
import UIKit
import StoreKit

/// Manages review prompt presentation: two-step and direct native review.
final class ReviewPromptManager {
    static let shared = ReviewPromptManager()

    private let defaults = UserDefaults.standard
    private let prefix = "ai.appdna.sdk.review."

    private static let maxPromptsPerYear = 3
    private static let minDaysBetweenPrompts = 90

    private init() {}

    // MARK: - Rate limiting

    /// Check if a review prompt can be shown (max 3/year, 90 days between prompts).
    private func canShowReviewPrompt() -> Bool {
        let count = defaults.integer(forKey: "\(prefix)request_count")
        if count >= Self.maxPromptsPerYear { return false }

        if let lastDate = defaults.object(forKey: "\(prefix)last_request_date") as? Date {
            let daysSinceLast = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
            if daysSinceLast < Self.minDaysBetweenPrompts { return false }
        }

        return true
    }

    /*
     #897 — `triggerTwoStepReview` WAS HERE, AND IT IS NOT COMING BACK.

     It presented a UIAlertController titled "Enjoying <app>?" with "Yes! 😊" / "Not really", and
     called `SKStoreReviewController.requestReview` only on "Yes". That is review gating. Apple's
     ratings rules forbid asking the customer a question before or while presenting the prompt,
     and forbid filtering who sees it by how they answered; Google's In-App Review guidelines say
     the same thing for the Play side.

     Nothing called it — which is exactly why it survived: dead code that is a policy violation
     waiting for a caller. `triggerReview` is the only way in, it prompts everyone it is asked to
     prompt, and the OS quota decides the rest.

     `scripts/__tests__/sdk-review-prompt-is-not-gated.test.ts` keeps it deleted.
     */

    // MARK: - Store listing

    /**
     Open the app's App Store review page, where the user can leave a review themselves.

     #896 — this is the OTHER half of asking for a review, and the halves are not interchangeable.
     `triggerReview` asks StoreKit for the in-place sheet and MUST NOT be called in response to a
     tap — Apple names that rule explicitly. Opening the review page from a button the user chose
     IS allowed, because no system prompt is invoked: the user asked to go to the store.

     `?action=write-review` is Apple's own parameter for landing on the review composer rather
     than the listing, which is why the iOS half can be more precise than the Android one (Play
     has no equivalent deep link).

     The numeric App Store ID is not something the SDK can derive — it is not in the bundle — so
     the caller supplies it from the button's `action_value`. Nothing is recorded about what the
     user does next; neither store reports it, by design.
     */
    func openStoreListing(appStoreId: String?) {
        // The id is the ONLY config-driven part of this URL, and an App Store id is numeric — so it
        // is checked as numeric rather than interpolated into a URL on trust, and the result still
        // goes through the one scheme allowlist. Android's equivalent was opening a hand-built
        // `Intent(ACTION_VIEW, Uri.parse(…))`, which its own call-site gate caught; the two
        // platforms now both route a store URL the same way.
        let id = (appStoreId ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.allSatisfy({ $0.isNumber }) else {
            Log.warning("[Review] a rate_app button needs the NUMERIC App Store ID in action_value")
            return
        }
        guard let url = URLSafety.sanitized("https://apps.apple.com/app/id\(id)?action=write-review") else {
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url) { opened in
                if opened {
                    AppDNA.track(event: "store_listing_opened", properties: ["app_store_id": id])
                } else {
                    Log.warning("[Review] the App Store could not be opened for id \(id)")
                }
            }
        }
    }

    // MARK: - Direct native review prompt

    /// Trigger native SKStoreReviewController immediately.
    func triggerReview() {
        guard canShowReviewPrompt() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.requestNativeReview()
            AppDNA.track(event: "review_prompt_shown", properties: ["prompt_type": "direct"])
        }
    }

    // MARK: - Private

    private func requestNativeReview() {
        // Track that we requested a review
        let count = defaults.integer(forKey: "\(prefix)request_count")
        defaults.set(count + 1, forKey: "\(prefix)request_count")
        defaults.set(Date(), forKey: "\(prefix)last_request_date")

        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }

}

// MARK: - Bundle helper

extension Bundle {
    var displayName: String? {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
