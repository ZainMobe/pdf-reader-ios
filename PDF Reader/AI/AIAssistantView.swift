import SwiftUI
import FoundationModels

/// AI — On-device Foundation Models integration.
///
/// For Pro users this view explains how to invoke each AI surface (from
/// the Reader). For free users it's a full upsell — feature breakdown +
/// "Start Free Trial" CTA — since the AI tab is the headline differentiator
/// most users will tap.
struct AIAssistantView: View {
    private let model = SystemLanguageModel.default
    private let entitlements = EntitlementStore.shared

    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.availability {
                case .available:
                    if entitlements.isPro {
                        proReady
                    } else {
                        freeUpsell
                    }
                case .unavailable(.deviceNotEligible):
                    unavailable(
                        "Apple Intelligence isn't supported on this device.",
                        systemImage: "sparkles.slash"
                    )
                case .unavailable(.appleIntelligenceNotEnabled):
                    unavailable(
                        "Turn on Apple Intelligence in Settings to use AI features.",
                        systemImage: "sparkles.slash"
                    )
                case .unavailable(.modelNotReady):
                    unavailable(
                        "The on-device model is downloading. Try again in a few minutes.",
                        systemImage: "arrow.down.circle"
                    )
                case .unavailable:
                    unavailable(
                        "AI features are currently unavailable.",
                        systemImage: "sparkles.slash"
                    )
                }
            }
            .navigationTitle("AI")
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
        }
    }

    // MARK: - Pro user state

    private var proReady: some View {
        ContentUnavailableView {
            Label("AI Assistant", systemImage: "sparkles")
        } description: {
            Text("Open a PDF and tap **Summarize** to get a private, on-device summary. Chat, Translate, Extract Data, and Auto-Fill Form are all in the AI menu of the Reader.")
        }
    }

    // MARK: - Free upsell

    private var freeUpsell: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.xl) {
                hero
                features
                cta
            }
            .padding(DesignSystem.Spacing.l)
        }
    }

    private var hero: some View {
        VStack(spacing: DesignSystem.Spacing.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeat(.continuous))
            Text("AI for Your PDFs")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Summarize, chat, translate, and extract data — all on-device. Nothing leaves your iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DesignSystem.Spacing.l)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.l) {
            featureRow(
                icon: "text.alignleft",
                title: "Summarize",
                subtitle: "Get the gist of any PDF in seconds."
            )
            featureRow(
                icon: "message",
                title: "Chat with PDF",
                subtitle: "Ask questions about your document."
            )
            featureRow(
                icon: "character.bubble",
                title: "Translate",
                subtitle: "11 languages, on-device."
            )
            featureRow(
                icon: "tablecells",
                title: "Extract Data",
                subtitle: "Dates, amounts, names, and key points."
            )
            featureRow(
                icon: "checklist",
                title: "Auto-Fill Forms",
                subtitle: "Smart suggestions for every text field."
            )
        }
        .padding(DesignSystem.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.m) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var cta: some View {
        VStack(spacing: DesignSystem.Spacing.s) {
            Button {
                Haptics.impact(.medium)
                showingPaywall = true
            } label: {
                Text("Start Free Trial")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            Text("7-day free trial · Cancel anytime")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func unavailable(_ message: String, systemImage: String) -> some View {
        ContentUnavailableView(
            "AI Unavailable",
            systemImage: systemImage,
            description: Text(message)
        )
    }
}

#Preview {
    AIAssistantView()
}
