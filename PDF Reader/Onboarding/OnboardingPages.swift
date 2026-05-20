import SwiftUI

// MARK: - 1. Hero

/// Kinetic typography welcome. Sparkles symbol with iterative variable color
/// effect, then headline + subtitle slide in word-by-word.
struct OnboardingHeroPage: View {
    let nonce: Int
    @State private var appeared = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.35), .clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 140
                        )
                    )
                    .frame(width: 280, height: 280)
                    .blur(radius: 20)

                Image(systemName: "sparkles")
                    .font(.system(size: 88, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                    .shadow(color: .white.opacity(0.6), radius: 18)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: DesignSystem.Spacing.s) {
                AnimatedWords(
                    text: "Welcome to PDF Reader",
                    font: .system(size: 34, weight: .bold, design: .rounded),
                    color: .white,
                    nonce: nonce
                )
                .multilineTextAlignment(.center)

                Text("Read, sign, and chat with your PDFs — privately, on-device.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
            }

            Spacer()
            Spacer()
        }
        .onAppear { restart() }
        .onChange(of: nonce) { _, _ in restart() }
    }

    private func restart() {
        appeared = false
        withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.05)) {
            appeared = true
        }
    }
}

// MARK: - 2. AI in Action

/// Mock PDF page on the left, AI chat bubble on the right with a typewriter
/// response that completes in ~1.6 seconds.
struct OnboardingAIPage: View {
    let nonce: Int
    @State private var typedText: String = ""
    @State private var bubbleVisible = false
    @State private var pageVisible = false

    private let fullText = "This contract grants exclusive distribution rights to Party A for 36 months."

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            ZStack {
                mockPDFPage
                    .frame(width: 170, height: 220)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -60, y: 10)
                    .opacity(pageVisible ? 1 : 0)
                    .scaleEffect(pageVisible ? 1 : 0.85)

                aiChatBubble
                    .offset(x: 60, y: -30)
                    .opacity(bubbleVisible ? 1 : 0)
                    .scaleEffect(bubbleVisible ? 1 : 0.85, anchor: .bottomLeading)
            }
            .frame(height: 280)

            VStack(spacing: DesignSystem.Spacing.s) {
                Text("AI that reads with you")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Summarize, chat, translate, and extract — all running on your device.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignSystem.Spacing.l)

            Spacer()
        }
        .onAppear { runSequence() }
        .onChange(of: nonce) { _, _ in runSequence() }
    }

    private var mockPDFPage: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.white)
            .overlay(
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.black.opacity(0.7))
                        .frame(height: 12)
                        .frame(maxWidth: 110)
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.gray.opacity(0.45))
                            .frame(height: 6)
                            .frame(maxWidth: i == 7 ? 80 : .infinity)
                    }
                }
                .padding(16),
                alignment: .topLeading
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var aiChatBubble: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.s) {
            Image(systemName: "sparkles")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(Circle().fill(Color.purple))
                .symbolEffect(.variableColor.iterative, options: .repeating)
            VStack(alignment: .leading, spacing: 4) {
                Text("PDF Reader AI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(typedText + (typedText.count < fullText.count ? "▍" : ""))
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignSystem.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    private func runSequence() {
        typedText = ""
        pageVisible = false
        bubbleVisible = false

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            pageVisible = true
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.25)) {
            bubbleVisible = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            for ch in fullText {
                guard !Task.isCancelled else { return }
                typedText.append(ch)
                let delay: UInt64 = ch == " " ? 30_000_000 : 28_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }
}

// MARK: - 3. Sign Anywhere

/// A signature draws itself across a mock contract using path trimming
/// driven by an animatable progress value.
struct OnboardingSignPage: View {
    let nonce: Int
    @State private var progress: CGFloat = 0
    @State private var pageVisible = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            ZStack {
                mockContractPage
                    .frame(width: 280, height: 280)
                    .opacity(pageVisible ? 1 : 0)
                    .scaleEffect(pageVisible ? 1 : 0.9)

                signature
                    .frame(width: 220, height: 80)
                    .offset(y: 70)
            }
            .frame(height: 320)

            VStack(spacing: DesignSystem.Spacing.s) {
                Text("Sign anywhere")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Draw once. Reuse forever. Drop your signature onto any page.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignSystem.Spacing.l)

            Spacer()
        }
        .onAppear { runSequence() }
        .onChange(of: nonce) { _, _ in runSequence() }
    }

    private var mockContractPage: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(.white)
            .overlay(
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.black.opacity(0.8))
                        .frame(height: 14)
                        .frame(maxWidth: 150)
                    ForEach(0..<6, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.gray.opacity(0.4))
                            .frame(height: 7)
                            .frame(maxWidth: i == 5 ? 100 : .infinity)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        Rectangle()
                            .fill(.gray.opacity(0.4))
                            .frame(height: 1)
                        Text("Signature")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }
                .padding(22),
                alignment: .topLeading
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var signature: some View {
        SignaturePath()
            .trim(from: 0, to: progress)
            .stroke(
                LinearGradient(
                    colors: [Color(red: 0.1, green: 0.15, blue: 0.55), Color(red: 0.0, green: 0.3, blue: 0.7)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: .blue.opacity(0.45), radius: 6)
    }

    private func runSequence() {
        progress = 0
        pageVisible = false

        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            pageVisible = true
        }
        withAnimation(.easeInOut(duration: 1.8).delay(0.4)) {
            progress = 1
        }
    }
}

/// Hand-tuned cubic curves that loosely resemble a signature scrawl. Drawn
/// across a 220×80 frame; trim from 0 → 1 to animate the stroke in.
private struct SignaturePath: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: 0.02 * w, y: 0.7 * h))
        p.addCurve(
            to: CGPoint(x: 0.18 * w, y: 0.3 * h),
            control1: CGPoint(x: 0.05 * w, y: 0.2 * h),
            control2: CGPoint(x: 0.10 * w, y: 0.1 * h)
        )
        p.addCurve(
            to: CGPoint(x: 0.30 * w, y: 0.8 * h),
            control1: CGPoint(x: 0.22 * w, y: 0.85 * h),
            control2: CGPoint(x: 0.28 * w, y: 1.0 * h)
        )
        p.addCurve(
            to: CGPoint(x: 0.46 * w, y: 0.35 * h),
            control1: CGPoint(x: 0.34 * w, y: 0.5 * h),
            control2: CGPoint(x: 0.40 * w, y: 0.2 * h)
        )
        p.addCurve(
            to: CGPoint(x: 0.62 * w, y: 0.75 * h),
            control1: CGPoint(x: 0.52 * w, y: 0.6 * h),
            control2: CGPoint(x: 0.58 * w, y: 0.95 * h)
        )
        p.addCurve(
            to: CGPoint(x: 0.78 * w, y: 0.4 * h),
            control1: CGPoint(x: 0.68 * w, y: 0.5 * h),
            control2: CGPoint(x: 0.74 * w, y: 0.2 * h)
        )
        p.addCurve(
            to: CGPoint(x: 0.98 * w, y: 0.7 * h),
            control1: CGPoint(x: 0.85 * w, y: 0.7 * h),
            control2: CGPoint(x: 0.92 * w, y: 0.9 * h)
        )
        return p
    }
}

// MARK: - 4. Privacy

/// Lock symbol with a layered halo that pulses, plus an "On-device" badge.
struct OnboardingPrivacyPage: View {
    let nonce: Int
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: 160 + CGFloat(i * 60), height: 160 + CGFloat(i * 60))
                        .scaleEffect(pulse ? 1.05 : 0.95)
                        .opacity(pulse ? 0.0 : 0.5)
                        .animation(
                            .easeOut(duration: 2.2)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.6),
                            value: pulse
                        )
                }

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 96, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .symbolEffect(.pulse, options: .repeating)
                    .shadow(color: .white.opacity(0.4), radius: 18)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(height: 320)

            VStack(spacing: DesignSystem.Spacing.s) {
                Text("Private by design")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("AI runs entirely on your iPhone. No servers. No tracking. No analytics.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.l)

                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                    Text("On-device · Apple Intelligence")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.m)
                .padding(.vertical, DesignSystem.Spacing.s)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, DesignSystem.Spacing.s)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            }

            Spacer()
        }
        .onAppear { runSequence() }
        .onChange(of: nonce) { _, _ in runSequence() }
    }

    private func runSequence() {
        appeared = false
        pulse = false
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            appeared = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pulse = true
        }
    }
}

// MARK: - 5. Final

/// Sparkle particle field + sweeping CTA shimmer. The actual button is in
/// OnboardingView's bottomBar — this page just sells the moment.
struct OnboardingFinalPage: View {
    let nonce: Int
    @State private var appeared = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            ZStack {
                ForEach(0..<14, id: \.self) { i in
                    SparkleParticle(index: i)
                }

                Image(systemName: "sparkles")
                    .font(.system(size: 100, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.yellow, .orange, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.bounce, options: .nonRepeating, value: nonce)
                    .shadow(color: .orange.opacity(0.5), radius: 24)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(height: 320)

            VStack(spacing: DesignSystem.Spacing.s) {
                Text("You're all set")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Tap below to start. Your first PDF is one tap away.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystem.Spacing.l)
            }

            Spacer()
        }
        .onAppear { runSequence() }
        .onChange(of: nonce) { _, _ in runSequence() }
    }

    private func runSequence() {
        appeared = false
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            appeared = true
        }
    }
}

/// A single twinkling sparkle that orbits around the central icon.
private struct SparkleParticle: View {
    let index: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t + Double(index) * 0.7
            let radius: Double = 120 + sin(phase * 0.7) * 18
            let angle = phase * 0.4 + Double(index) * (2 * .pi / 14)
            let x = cos(angle) * radius
            let y = sin(angle) * radius
            let twinkle = 0.4 + (sin(phase * 2) + 1) * 0.3

            Image(systemName: "sparkle")
                .font(.system(size: 10 + CGFloat(sin(phase) + 1) * 3))
                .foregroundStyle(.white)
                .opacity(twinkle)
                .offset(x: x, y: y)
        }
    }
}

// MARK: - Animated words

/// Splits a string into words and fades each one up with a stagger. Re-runs
/// whenever the `nonce` value changes so the parent can reset the animation.
struct AnimatedWords: View {
    let text: String
    let font: Font
    let color: Color
    let nonce: Int

    @State private var shown: Int = 0

    private var words: [String] { text.split(separator: " ").map(String.init) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(words.indices, id: \.self) { i in
                Text(words[i])
                    .font(font)
                    .foregroundStyle(color)
                    .opacity(shown > i ? 1 : 0)
                    .offset(y: shown > i ? 0 : 14)
            }
        }
        .onAppear { run() }
        .onChange(of: nonce) { _, _ in run() }
    }

    private func run() {
        shown = 0
        for i in words.indices {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(Double(i) * 0.08 + 0.1)) {
                shown = i + 1
            }
        }
    }
}
