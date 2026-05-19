import SwiftUI
import RevenueCat

/// Subscription paywall. Loads packages from RevenueCat's current offering,
/// renders live localized prices, surfaces free-trial offers per package,
/// runs purchases through RevenueCat, and dismisses when the Pro
/// entitlement becomes active.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTier: SubscriptionTier = .yearly
    @State private var packages: [Package] = []
    @State private var eligibility: [String: IntroEligibilityStatus] = [:]
    @State private var isPurchasing = false
    @State private var purchaseError: String?
    @State private var loadAttempted = false
    @State private var showingCelebration = false

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
            .sensoryFeedback(.selection, trigger: selectedTier)
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
            .fullScreenCover(isPresented: $showingCelebration) {
                CelebrationView(
                    title: "You're Pro!",
                    subtitle: celebrationSubtitle
                ) {
                    Haptics.success()
                    showingCelebration = false
                    dismiss()
                }
            }
        }
    }

    private var celebrationSubtitle: String {
        if trialDescription(for: selectedTier) != nil {
            return "Your free trial just started.\nEvery Pro feature is unlocked."
        }
        return "Every Pro feature is now unlocked.\nThank you for supporting PDF AI."
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
        let isSelected = selectedTier == tier
        let package = packageFor(tier)
        let priceText = package?.storeProduct.localizedPriceString ?? tier.priceText
        let trial = trialDescription(for: tier)
        return Button {
            selectedTier = tier
        } label: {
            HStack(spacing: DesignSystem.Spacing.m) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(spacing: DesignSystem.Spacing.s) {
                        Text(tier.displayName).font(.headline)
                        if tier.isPopular {
                            Text("MOST POPULAR")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, DesignSystem.Spacing.s)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green))
                                .foregroundStyle(.white)
                        }
                    }
                    Text(tier.billingDescription).font(.caption).foregroundStyle(.secondary)
                    if let trial {
                        Label(trial, systemImage: "gift")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Spacer(minLength: DesignSystem.Spacing.m)
                Text(priceText).font(.headline)
            }
            .padding(DesignSystem.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.medium)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
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
                        Text(ctaTitle)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            .disabled(isPurchasing || packageFor(selectedTier) == nil)
            Text(ctaCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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

    // MARK: - Trial helpers

    private var ctaTitle: String {
        trialDescription(for: selectedTier) != nil ? "Start Free Trial" : "Subscribe"
    }

    private var ctaCaption: String {
        guard let package = packageFor(selectedTier) else { return "" }
        let price = package.storeProduct.localizedPriceString
        if let trial = trialDescription(for: selectedTier) {
            return "\(trial), then \(price) \(periodSuffix(selectedTier))"
        }
        return "\(price) \(periodSuffix(selectedTier))"
    }

    private func periodSuffix(_ tier: SubscriptionTier) -> String {
        switch tier.id {
        case SubscriptionTier.monthly.id: "per month"
        case SubscriptionTier.yearly.id: "per year"
        case SubscriptionTier.lifetime.id: "one-time"
        default: ""
        }
    }

    /// Returns a human-readable trial duration string (e.g. "3-day free trial")
    /// when the tier has an intro free-trial offer and the user is eligible
    /// for it. Returns nil for tiers without a trial or for users who've
    /// already used the trial.
    private func trialDescription(for tier: SubscriptionTier) -> String? {
        guard
            let package = packageFor(tier),
            let intro = package.storeProduct.introductoryDiscount,
            intro.paymentMode == .freeTrial
        else { return nil }

        // Hide trial badges for users we know are ineligible. `unknown` and
        // `noIntroOfferExists` map to "don't show" too. `eligible` shows it.
        let status = eligibility[package.storeProduct.productIdentifier]
        guard status == .eligible || status == nil else { return nil }

        return "\(intro.subscriptionPeriod.value)-\(periodUnitName(intro.subscriptionPeriod)) free trial"
    }

    private func periodUnitName(_ period: SubscriptionPeriod) -> String {
        let plural = period.value != 1
        switch period.unit {
        case .day: return plural ? "days" : "day"
        case .week: return plural ? "weeks" : "week"
        case .month: return plural ? "months" : "month"
        case .year: return plural ? "years" : "year"
        }
    }

    // MARK: - RevenueCat

    private func packageFor(_ tier: SubscriptionTier) -> Package? {
        packages.first { $0.storeProduct.productIdentifier == tier.id }
    }

    private func loadOfferings() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            let current = offerings.current
            let order = [SubscriptionTier.monthly.id, SubscriptionTier.yearly.id, SubscriptionTier.lifetime.id]
            let sorted = (current?.availablePackages ?? []).sorted { lhs, rhs in
                let lhsIndex = order.firstIndex(of: lhs.storeProduct.productIdentifier) ?? Int.max
                let rhsIndex = order.firstIndex(of: rhs.storeProduct.productIdentifier) ?? Int.max
                return lhsIndex < rhsIndex
            }
            packages = sorted

            // Subscriptions only — lifetime can't have an intro offer.
            let subscriptionIDs = sorted
                .map(\.storeProduct.productIdentifier)
                .filter { $0 != SubscriptionTier.lifetime.id }
            if !subscriptionIDs.isEmpty {
                let result = await Purchases.shared
                    .checkTrialOrIntroDiscountEligibility(productIdentifiers: subscriptionIDs)
                eligibility = result.mapValues(\.status)
            }
        } catch {
            purchaseError = error.localizedDescription
        }
        loadAttempted = true
    }

    private func purchase() async {
        guard let package = packageFor(selectedTier) else { return }
        Haptics.impact(.medium)
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return }
            await EntitlementStore.shared.refresh()
            if EntitlementStore.shared.isPro {
                Haptics.success()
                showingCelebration = true
            }
        } catch {
            Haptics.error()
            purchaseError = error.localizedDescription
        }
    }

    private func restore() async {
        do {
            _ = try await Purchases.shared.restorePurchases()
            await EntitlementStore.shared.refresh()
            if EntitlementStore.shared.isPro {
                Haptics.success()
                showingCelebration = true
            }
        } catch {
            Haptics.error()
            purchaseError = error.localizedDescription
        }
    }
}

#Preview {
    PaywallView()
}
