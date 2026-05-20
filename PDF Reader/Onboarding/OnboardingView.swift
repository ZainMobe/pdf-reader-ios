import SwiftUI

/// Five-page onboarding shown once on first launch. Drives an animated mesh
/// gradient background that persists across pages, runs a fresh staged
/// animation each time a new page becomes active, and dismisses with a haptic
/// pop when the user finishes.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page: OnboardingPage = .hero
    /// Bumps every time a page becomes active so the child view can re-run
    /// its entrance animations from scratch.
    @State private var pageNonce: Int = 0

    var body: some View {
        ZStack {
            OnboardingBackground(page: page)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
            .padding(.horizontal, DesignSystem.Spacing.l)
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: page)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Spacer()
            if page != .final {
                Button {
                    Haptics.impact(.light)
                    finish()
                } label: {
                    Text("Skip")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, DesignSystem.Spacing.m)
                        .padding(.vertical, DesignSystem.Spacing.s)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .foregroundStyle(.white.opacity(0.9))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(height: 44)
        .padding(.top, DesignSystem.Spacing.m)
        .animation(.easeInOut(duration: 0.25), value: page)
    }

    // MARK: - Page content

    private var pageContent: some View {
        ZStack {
            switch page {
            case .hero:
                OnboardingHeroPage(nonce: pageNonce)
            case .ai:
                OnboardingAIPage(nonce: pageNonce)
            case .sign:
                OnboardingSignPage(nonce: pageNonce)
            case .privacy:
                OnboardingPrivacyPage(nonce: pageNonce)
            case .final:
                OnboardingFinalPage(nonce: pageNonce)
            }
        }
        .id(page)
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: DesignSystem.Spacing.l) {
            indicator
            primaryButton
        }
        .padding(.bottom, DesignSystem.Spacing.l)
    }

    private var indicator: some View {
        HStack(spacing: DesignSystem.Spacing.s) {
            ForEach(OnboardingPage.allCases) { p in
                Capsule()
                    .fill(p == page ? Color.white : Color.white.opacity(0.3))
                    .frame(width: p == page ? 26 : 8, height: 8)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: page)
            }
        }
    }

    private var primaryButton: some View {
        Button {
            advance()
        } label: {
            HStack(spacing: DesignSystem.Spacing.s) {
                Text(page == .final ? "Get Started" : "Continue")
                    .font(.headline)
                if page != .final {
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.m + 2)
            .background(
                Capsule()
                    .fill(Color.white)
                    .shadow(color: Color.white.opacity(0.35), radius: 18, y: 0)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation

    private func advance() {
        Haptics.impact(.light)
        if let next = page.next {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                page = next
                pageNonce &+= 1
            }
        } else {
            finish()
        }
    }

    private func finish() {
        Haptics.success()
        onFinish()
    }
}

// MARK: - Page enum

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case hero, ai, sign, privacy, final
    var id: Int { rawValue }

    var next: OnboardingPage? {
        OnboardingPage(rawValue: rawValue + 1)
    }
}

// MARK: - Animated background

/// Animated mesh gradient that subtly drifts and shifts hue as the user
/// progresses through the onboarding. Re-rendered every animation tick via
/// TimelineView so the motion runs independently of any other animation.
struct OnboardingBackground: View {
    let page: OnboardingPage

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: meshPoints(t: t),
                colors: meshColors()
            )
        }
        .animation(.easeInOut(duration: 1.2), value: page)
    }

    private func meshPoints(t: TimeInterval) -> [SIMD2<Float>] {
        let s = Float(sin(t * 0.6)) * 0.04
        let c = Float(cos(t * 0.5)) * 0.04
        return [
            SIMD2(0, 0), SIMD2(0.5 + s, 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + c), SIMD2(0.5 - s, 0.5 - c), SIMD2(1, 0.5 + c),
            SIMD2(0, 1), SIMD2(0.5 + s, 1), SIMD2(1, 1),
        ]
    }

    private func meshColors() -> [Color] {
        switch page {
        case .hero:
            return [
                .indigo, .blue, .cyan,
                .purple, .indigo, .teal,
                .black, .indigo, .blue,
            ]
        case .ai:
            return [
                .purple, .pink, .orange,
                .indigo, .purple, .pink,
                .black, .purple, .orange,
            ]
        case .sign:
            return [
                .teal, .cyan, .mint,
                .blue, .teal, .green,
                .black, .blue, .mint,
            ]
        case .privacy:
            return [
                .indigo, .blue, .purple,
                .black, .indigo, .purple,
                .black, .black, .indigo,
            ]
        case .final:
            return [
                .orange, .pink, .purple,
                .red, .orange, .pink,
                .black, .red, .purple,
            ]
        }
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
