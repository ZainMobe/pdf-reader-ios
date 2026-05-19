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

    private(set) var isPro: Bool = false
    private(set) var activeProductID: String?

    private let delegate = EntitlementStoreDelegate()

    private init() {
        Purchases.shared.delegate = delegate
        Task { await refresh() }
    }

    /// Pulls the latest CustomerInfo from RevenueCat and updates state.
    func refresh() async {
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
