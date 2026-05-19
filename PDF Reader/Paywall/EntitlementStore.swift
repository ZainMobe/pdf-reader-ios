import Foundation
import StoreKit

/// Tracks the user's Pro subscription entitlement. Observed by gates around
/// AI, Edit, Sign, and non-iCloud Sync surfaces.
///
/// `refresh()` walks `Transaction.currentEntitlements`; once products are
/// registered in App Store Connect (see `SubscriptionTier.allIDs`), this
/// store will pick up live purchases without further changes.
@MainActor
@Observable
final class EntitlementStore {
    static let shared = EntitlementStore()

    private(set) var isPro: Bool = false
    private(set) var activeProductID: String?
    private var transactionListener: Task<Void, Never>?

    private init() {
        transactionListener = listenForTransactions()
        Task { await refresh() }
    }

    func refresh() async {
        var activeID: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if SubscriptionTier.allIDs.contains(transaction.productID) {
                activeID = transaction.productID
                break
            }
        }
        self.activeProductID = activeID
        self.isPro = activeID != nil
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await MainActor.run {
                    Task { await EntitlementStore.shared.refresh() }
                }
            }
        }
    }
}
