import Foundation
import RevenueCat

/// Tracks the user's Pro entitlement via RevenueCat.
///
/// RevenueCat is the single source of truth: `Purchases.shared` handles
/// StoreKit transactions, syncs entitlements across devices, and pushes
/// updates through `PurchasesDelegate`. We mirror the active state here so
/// SwiftUI views can observe it.
@MainActor
@Observable
final class EntitlementStore {
    static let shared = EntitlementStore()

    /// Mirrors the last known entitlement so Pro users don't see free-tier
    /// chrome (upgrade banner, "(Pro)" suffixes) for the second or two it
    /// takes RevenueCat to answer on a cold launch. RevenueCat remains the
    /// source of truth and corrects this as soon as `refresh()` completes.
    private static let cachedProKey = "entitlements.isPro.cached"

    private(set) var isPro: Bool = UserDefaults.standard.bool(forKey: EntitlementStore.cachedProKey)
    private(set) var activeProductID: String?

    /// Bumped whenever a free-tier use is consumed so views showing the
    /// remaining allowance (Settings footer, menu suffixes) re-render.
    private(set) var usageVersion = 0

    private let delegate = EntitlementStoreDelegate()

    private init() {
        // `Purchases.shared` traps when configure() was skipped (missing key).
        guard Purchases.isConfigured else { return }
        Purchases.shared.delegate = delegate
        Task { await refresh() }
    }

    /// Single gate for Pro functionality. Pro users always pass; free users
    /// pass while their daily allowance for `feature` lasts, and one use is
    /// consumed immediately. Use this for actions that take effect on tap.
    /// When it returns false the caller should present the paywall, which
    /// reads `FreeTier.paywallMessage` to explain the limit.
    func unlock(_ feature: ProFeature) -> Bool {
        if isPro { return true }
        if FreeTier.consume(feature) {
            usageVersion &+= 1
            return true
        }
        FreeTier.lastBlocked = feature
        return false
    }

    /// Non-consuming check. Use it to open a configuration sheet or picker,
    /// then call `recordUse` once the operation actually succeeds so a
    /// cancelled sheet or a failed run doesn't burn a free-tier allowance.
    func canUse(_ feature: ProFeature) -> Bool {
        if isPro { return true }
        if FreeTier.remaining(feature) > 0 { return true }
        FreeTier.lastBlocked = feature
        return false
    }

    /// Consumes one free-tier use after a gated action completed. No-op for
    /// Pro users.
    func recordUse(_ feature: ProFeature) {
        guard !isPro else { return }
        FreeTier.consume(feature)
        usageVersion &+= 1
    }

    /// Pulls the latest CustomerInfo from RevenueCat and updates state.
    func refresh() async {
        guard Purchases.isConfigured else { return }
        do {
            let info = try await Purchases.shared.customerInfo()
            apply(customerInfo: info)
        } catch {
            // Network blip / not configured yet — keep last known state.
        }
    }

    fileprivate func apply(customerInfo: CustomerInfo) {
        let proEntitlement = customerInfo.entitlements[RevenueCatConstants.proEntitlementID]
        isPro = proEntitlement?.isActive == true
        activeProductID = proEntitlement?.productIdentifier
        UserDefaults.standard.set(isPro, forKey: Self.cachedProKey)
    }
}

/// Forwards live entitlement updates from RevenueCat to `EntitlementStore`.
/// Kept separate so EntitlementStore can stay `@MainActor` while the
/// delegate methods stay non-isolated (RevenueCat calls them off-main).
final class EntitlementStoreDelegate: NSObject, PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            EntitlementStore.shared.apply(customerInfo: customerInfo)
        }
    }
}
