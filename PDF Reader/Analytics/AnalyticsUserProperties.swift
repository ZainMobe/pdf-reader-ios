import Foundation
import SwiftData

enum AnalyticsUserProperties {
    static func refreshEntitlement() {
        let store = EntitlementStore.shared
        AppAnalytics.setUserProperty(.isPro, store.isPro ? "true" : "false")
        AppAnalytics.setUserProperty(.plan, planName(for: store.activeProductID, isPro: store.isPro))
    }

    static func planName(for productID: String?, isPro: Bool) -> String {
        guard isPro else { return "free" }
        switch productID {
        case SubscriptionTier.monthly.id: return "monthly"
        case SubscriptionTier.yearly.id: return "annual"
        case SubscriptionTier.lifetime.id: return "lifetime"
        case .some: return "other"
        case .none: return "pro"
        }
    }

    static func refreshEnvironment() {
        let availability: String
        switch AIEngine.availability() {
        case .ready(.onDevice): availability = "on_device"
        case .ready(.cloud): availability = "cloud"
        case .needsCloudConsent: availability = "needs_consent"
        case .onDeviceUnavailable: availability = "unavailable_on_device"
        case .unavailable: availability = "unavailable"
        }
        AppAnalytics.setUserProperty(.aiAvailability, availability)
        AppAnalytics.setUserProperty(.aiMode, AIEngine.mode.rawValue)
        let defaults = UserDefaults.standard
        AppAnalytics.setUserProperty(.readerTheme, defaults.string(forKey: ReaderTheme.storageKey) ?? ReaderTheme.light.rawValue)
        AppAnalytics.setUserProperty(.libraryViewMode, defaults.string(forKey: "settings.libraryViewMode") ?? LibraryViewMode.grid.rawValue)
        AppAnalytics.setUserProperty(.onboardingDone, defaults.bool(forKey: "hasSeenOnboarding") ? "true" : "false")
        AppAnalytics.setUserProperty(.iCloudEnabled, DocumentStorage.isUsingICloud ? "true" : "false")
        AppAnalytics.setUserProperty(.dropboxLinked, DropboxAuthManager.shared.isSignedIn ? "true" : "false")
        refreshEntitlement()
    }

    static func refreshLibrary(in context: ModelContext) {
        let documents = (try? context.fetchCount(FetchDescriptor<Document>())) ?? 0
        AppAnalytics.setUserProperty(.librarySize, AppAnalytics.countBucket(documents))
        let signatures = (try? context.fetchCount(FetchDescriptor<SignatureAsset>())) ?? 0
        AppAnalytics.setUserProperty(.hasSignature, signatures > 0 ? "true" : "false")
    }
}
