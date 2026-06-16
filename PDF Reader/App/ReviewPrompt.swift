import SwiftUI
import StoreKit

/// Asks the user for an App Store review the first time they hit a meaningful
/// success moment — currently their first successful scan or signature
/// placement. Hand-off to `SKStoreReviewController` is done via the modern
/// `@Environment(\.requestReview)` action, which respects Apple's
/// at-most-three-prompts-per-365-days rule on top of our own one-shot flag.
enum ReviewPrompt {
    private static let didPromptKey = "review.didPrompt"

    /// Fires `requestReview` once per install. Idempotent; subsequent calls
    /// are no-ops. Adds a short delay so the success haptic / animation can
    /// land before the system sheet covers it.
    @MainActor
    static func requestIfNeeded(using requestReview: RequestReviewAction) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didPromptKey) else { return }
        defaults.set(true, forKey: didPromptKey)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            requestReview()
        }
    }
}
