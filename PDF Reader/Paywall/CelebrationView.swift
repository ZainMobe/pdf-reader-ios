import SwiftUI

/// Celebration shown after a successful subscription. Big animated seal,
/// pulsing sparkles, gradient backdrop, "Get Started" CTA. Wired up by
/// `PaywallView` and dismissed by the host so the user lands back at the
/// app — usually the Library — with Pro features unlocked.
struct CelebrationView: View {
    let title: String
    let subtitle: String
    let onContinue: () -> Void

    @State private var didAppear = false
    @State private var sealVisible = false

    var body: some View {
        ZStack {
            backdrop
            sparkles
            content
        }
        .ignoresSafeArea()
        .sensoryFeedback(.success, trigger: didAppear)
        .task {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
                didAppear = true
            }
            // Slight delay so the seal pops in after the gradient settles.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) {
                sealVisible = true
            }
        }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.35),
                Color.purple.opacity(0.35),
                Color.pink.opacity(0.20),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(Color(.systemBackground))
    }

    private var sparkles: some View {
        // Twelve sparkles in a ring around the seal, each on a slightly
        // different pulse phase so the whole thing feels alive.
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
            let radius = min(proxy.size.width, proxy.size.height) * 0.32
            ForEach(0..<12, id: \.self) { index in
                let angle = (Double(index) / 12.0) * .pi * 2
                let position = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
                Image(systemName: "sparkle")
                    .font(.system(size: 20 + CGFloat(index % 3) * 6))
                    .foregroundStyle(.tint)
                    .position(position)
                    .opacity(didAppear ? (0.6 + Double(index % 3) * 0.15) : 0)
                    .symbolEffect(
                        .pulse.byLayer,
                        options: .repeat(.continuous),
                        isActive: didAppear
                    )
            }
        }
    }

    private var content: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 120, weight: .bold))
                .foregroundStyle(.white, Color.accentColor)
                .symbolEffect(.bounce, value: sealVisible)
                .scaleEffect(sealVisible ? 1.0 : 0.4)
                .opacity(sealVisible ? 1.0 : 0)

            VStack(spacing: DesignSystem.Spacing.s) {
                Text(title)
                    .font(.system(size: 36, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignSystem.Spacing.l)
            .opacity(sealVisible ? 1.0 : 0)
            .offset(y: sealVisible ? 0 : 20)

            Spacer()

            Button {
                Haptics.impact(.medium)
                onContinue()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.xxl)
            .opacity(sealVisible ? 1.0 : 0)
        }
    }
}

#Preview {
    CelebrationView(
        title: "You're Pro!",
        subtitle: "Every Pro feature is now unlocked.\nEnjoy your free trial."
    ) {}
}
