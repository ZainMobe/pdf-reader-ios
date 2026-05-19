import Foundation

/// Local model for the subscription tiers the paywall renders. Live prices
/// and entitlement state come from RevenueCat; these display strings are
/// fallbacks for when offerings haven't loaded yet.
struct SubscriptionTier: Identifiable, Hashable {
    let id: String
    let displayName: String
    let priceText: String
    let billingDescription: String
    let isPopular: Bool
}

extension SubscriptionTier {
    static let monthly = SubscriptionTier(
        id: "com.wappltd.pdf.pro.monthly",
        displayName: "Monthly",
        priceText: "$4.99",
        billingDescription: "Billed monthly",
        isPopular: false
    )

    static let yearly = SubscriptionTier(
        id: "com.wappltd.pdf.pro.yearly",
        displayName: "Annual",
        priceText: "$39.99",
        billingDescription: "Save 33% · Billed yearly",
        isPopular: true
    )

    static let lifetime = SubscriptionTier(
        id: "com.wappltd.pdf.pro.lifetime",
        displayName: "Lifetime",
        priceText: "$99.99",
        billingDescription: "One-time purchase",
        isPopular: false
    )

    static let all: [SubscriptionTier] = [.monthly, .yearly, .lifetime]
    static let allIDs: Set<String> = Set(all.map(\.id))
}

/// RevenueCat entitlement that unlocks Pro features.
enum RevenueCatConstants {
    static let proEntitlementID = "Pro"
}
