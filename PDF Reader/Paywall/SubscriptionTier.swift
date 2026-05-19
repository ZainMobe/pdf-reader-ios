import Foundation

/// Local model for the subscription tiers the paywall renders. Once products
/// are registered in App Store Connect, prices will be sourced from
/// `StoreKit.Product` and these display strings become fallbacks.
struct SubscriptionTier: Identifiable, Hashable {
    let id: String
    let displayName: String
    let priceText: String
    let billingDescription: String
    let isPopular: Bool
}

extension SubscriptionTier {
    static let monthly = SubscriptionTier(
        id: "pdfai.pro.monthly",
        displayName: "Monthly",
        priceText: "$4.99",
        billingDescription: "Billed monthly",
        isPopular: false
    )

    static let yearly = SubscriptionTier(
        id: "pdfai.pro.yearly",
        displayName: "Annual",
        priceText: "$39.99",
        billingDescription: "Save 33% · Billed yearly",
        isPopular: true
    )

    static let lifetime = SubscriptionTier(
        id: "pdfai.pro.lifetime",
        displayName: "Lifetime",
        priceText: "$99.99",
        billingDescription: "One-time purchase",
        isPopular: false
    )

    static let all: [SubscriptionTier] = [.monthly, .yearly, .lifetime]
    static let allIDs: Set<String> = Set(all.map(\.id))
}
