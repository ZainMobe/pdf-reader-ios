import SwiftUI
import StoreKit

/// Subscription paywall surface. Loads `StoreKit.Product`s for the configured
/// tier IDs on appear; the CTA initiates a purchase and refreshes
/// `EntitlementStore` on completion.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTier: SubscriptionTier = .yearly
    @State private var products: [Product] = []
    @State private var isPurchasing = false
    @State private var purchaseError: String?
    @State private var loadAttempted = false

    private let features: [(systemImage: String, title: String, subtitle: String)] = [
        ("sparkles", "On-device AI", "Summarize, chat, translate — all private."),
        ("pencil.and.outline", "Full editor", "Edit text, images, pages, redact, and fill forms."),
        ("signature", "Unlimited signing", "Sign anywhere with your saved signatures."),
        ("icloud", "Cloud sync", "iCloud, Dropbox, Drive, OneDrive — coming soon."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.xl) {
                    hero
                    featureList
                    tierPicker
                    cta
                    fineprint
                }
                .padding(DesignSystem.Spacing.l)
            }
            .navigationTitle("PDF AI Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await loadProducts() }
            .alert(
                "Purchase failed",
                isPresented: Binding(
                    get: { purchaseError != nil },
                    set: { if !$0 { purchaseError = nil } }
                )
            ) {
                Button("OK") { purchaseError = nil }
            } message: {
                Text(purchaseError ?? "")
            }
        }
    }

    private var hero: some View {
        VStack(spacing: DesignSystem.Spacing.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Unlock Pro")
                .font(.largeTitle.weight(.bold))
            Text("Every Pro feature. Private by default. One subscription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DesignSystem.Spacing.l)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.m) {
            ForEach(features, id: \.title) { feature in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.m) {
                    Image(systemName: feature.systemImage)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text(feature.title).font(.headline)
                        Text(feature.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tierPicker: some View {
        VStack(spacing: DesignSystem.Spacing.m) {
            ForEach(SubscriptionTier.all) { tier in
                tierCard(tier)
            }
        }
    }

    private func tierCard(_ tier: SubscriptionTier) -> some View {
        let product = products.first { $0.id == tier.id }
        let priceText = product?.displayPrice ?? tier.priceText
        return Button {
            selectedTier = tier
        } label: {
            HStack(spacing: DesignSystem.Spacing.m) {
                Image(systemName: selectedTier == tier ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(spacing: DesignSystem.Spacing.s) {
                        Text(tier.displayName).font(.headline)
                        if tier.isPopular {
                            Text("MOST POPULAR")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, DesignSystem.Spacing.s)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.tint))
                                .foregroundStyle(.white)
                        }
                    }
                    Text(tier.billingDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(priceText).font(.headline)
            }
            .padding(DesignSystem.Spacing.l)
            .glassEffect(
                selectedTier == tier ? Glass.regular.tint(.accentColor) : .regular,
                in: .rect(cornerRadius: DesignSystem.Radius.medium)
            )
        }
        .buttonStyle(.plain)
    }

    private var cta: some View {
        VStack(spacing: DesignSystem.Spacing.s) {
            Button {
                Task { await purchase() }
            } label: {
                Group {
                    if isPurchasing {
                        ProgressView()
                    } else {
                        Text("Subscribe")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            .disabled(isPurchasing || products.first { $0.id == selectedTier.id } == nil)
            if products.isEmpty {
                if loadAttempted {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Couldn't reach the App Store. Check your connection and try again.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadProducts() }
                        }
                        .font(.caption.weight(.medium))
                    }
                } else {
                    Text("Loading products…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var fineprint: some View {
        HStack(spacing: DesignSystem.Spacing.l) {
            Button("Restore Purchases") {
                Task {
                    try? await AppStore.sync()
                    await EntitlementStore.shared.refresh()
                }
            }
            Button("Terms") {}
            Button("Privacy") {}
        }
        .font(.footnote)
        .padding(.top, DesignSystem.Spacing.m)
    }

    private func loadProducts() async {
        do {
            let fetched = try await Product.products(for: SubscriptionTier.allIDs)
            products = fetched.sorted { lhs, rhs in
                let order = [SubscriptionTier.monthly.id, SubscriptionTier.yearly.id, SubscriptionTier.lifetime.id]
                let lhsIndex = order.firstIndex(of: lhs.id) ?? Int.max
                let rhsIndex = order.firstIndex(of: rhs.id) ?? Int.max
                return lhsIndex < rhsIndex
            }
        } catch {
            purchaseError = error.localizedDescription
        }
        loadAttempted = true
    }

    private func purchase() async {
        guard let product = products.first(where: { $0.id == selectedTier.id }) else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await EntitlementStore.shared.refresh()
                    dismiss()
                } else {
                    purchaseError = "Couldn't verify the purchase."
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}

#Preview {
    PaywallView()
}
