import SwiftUI

struct CloudAIConsentView: View {
    var onAllow: () -> Void
    var onDecline: (() -> Void)?

    @AppStorage(AppSettings.cloudAIConsent) private var cloudConsent = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.l) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, DesignSystem.Spacing.l)
            Text("Use Cloud AI?")
                .font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.m) {
                row("sparkles", "Apple Intelligence isn't available on this device, so AI features can run on Claude, Anthropic's AI model, instead.")
                row("doc.text", "Only the text needed for each request (the document or the passages you ask about) is sent over an encrypted connection.")
                row("hand.raised", "Anthropic doesn't use this data to train its models. Nothing is sent until you start an AI action.")
                row("gearshape", "You can turn this off at any time in Settings > AI.")
            }
            .font(.subheadline)
            Spacer(minLength: 0)
            Button {
                cloudConsent = true
                AppAnalytics.log(.cloudAIConsent, [.granted: true])
                AnalyticsUserProperties.refreshEnvironment()
                onAllow()
            } label: {
                Text("Allow Cloud AI")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let onDecline {
                Button("Not Now") {
                    AppAnalytics.log(.cloudAIConsent, [.granted: false])
                    onDecline()
                }
            }
        }
        .padding(DesignSystem.Spacing.l)
        .trackScreen(.cloudAIConsent)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.m) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CloudAIConsentSheet: ViewModifier {
    @Binding var isPresented: Bool
    var onAllow: () -> Void

    @State private var allowed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            if allowed {
                allowed = false
                onAllow()
            }
        }) {
            CloudAIConsentView(onAllow: {
                allowed = true
                isPresented = false
            }, onDecline: {
                isPresented = false
            })
            .presentationDetents([.large])
        }
    }
}

extension View {
    func cloudAIConsent(isPresented: Binding<Bool>, onAllow: @escaping () -> Void) -> some View {
        modifier(CloudAIConsentSheet(isPresented: isPresented, onAllow: onAllow))
    }
}
