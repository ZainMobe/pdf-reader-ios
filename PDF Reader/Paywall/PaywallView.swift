import SwiftUI
import RevenueCat

/// Subscription paywall. Loads packages from RevenueCat's current offering,
/// renders live localized prices, runs purchases through RevenueCat, and
/// dismisses when the Pro entitlement becomes active.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTier: SubscriptionTier = .yearly
    @State private var packages: [Package] = []
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
            .task { await loadOfferings() }
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
        let package = packages.first { $0.storeProduct.productIdentifier == tier.id }
        let priceText = package?.storeProduct.localizedPriceString ?? tier.priceText
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
            .disabled(isPurchasing || packageFor(selectedTier) == nil)
            if packages.isEmpty {
                if loadAttempted {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        Text("Couldn't load subscriptions. Check your connection and try again.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadOfferings() }
                        }
                        .font(.caption.weight(.medium))
                    }
                } else {
                    Text("Loading subscriptions…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var fineprint: some View {
        HStack(spacing: DesignSystem.Spacing.l) {
            Button("Restore Purchases") {
                Task { await restore() }
            }
            Button("Terms") {}
            Button("Privacy") {}
        }
        .font(.footnote)
        .padding(.top, DesignSystem.Spacing.m)
    }

    private func packageFor(_ tier: SubscriptionTier) -> Package? {
        packages.first { $0.storeProduct.productIdentifier == tier.id }
    }

    private func loadOfferings() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            let current = offerings.current
            let order = [SubscriptionTier.monthly.id, SubscriptionTier.yearly.id, SubscriptionTier.lifetime.id]
            packages = (current?.availablePackages ?? []).sorted { lhs, rhs in
                let lhsIndex = order.firstIndex(of: lhs.storeProduct.productIdentifier) ?? Int.max
                let rhsIndex = order.firstIndex(of: rhs.storeProduct.productIdentifier) ?? Int.max
                return lhsIndex < rhsIndex
            }
        } catch {
            purchaseError = error.localizedDescription
        }
        loadAttempted = true
    }

    private func purchase() async {
        guard let package = packageFor(selectedTier) else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return }
            await EntitlementStore.shared.refresh()
            if EntitlementStore.shared.isPro {
                dismiss()
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    private func restore() async {
        do {
            _ = try await Purchases.shared.restorePurchases()
            await EntitlementStore.shared.refresh()
            if EntitlementStore.shared.isPro {
                dismiss()
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}

#Preview {
    PaywallView()
}
