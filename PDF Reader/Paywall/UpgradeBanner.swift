import SwiftUI

/// Persistent upsell card shown to free users at the top of the Library.
/// Respects a 24-hour dismissal window stored in UserDefaults so users
/// who tap "Not now" aren't nagged on every visit.
struct UpgradeBanner: View {
    let onTap: () -> Void

    @AppStorage("paywall.bannerDismissedAt") private var dismissedAt: Double = 0
    @State private var refreshTick = UUID()

    var shouldShow: Bool {
        let elapsed = Date.now.timeIntervalSince1970 - dismissedAt
        return elapsed > 86_400 // 24 hours
    }

    var body: some View {
        if shouldShow {
            Button {
                Haptics.impact(.light)
                onTap()
            } label: {
                HStack(spacing: DesignSystem.Spacing.m) {
                    ZStack {
                        Circle()
                            .fill(.tint.opacity(0.18))
                            .frame(width: 44, height: 44)
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Unlock PDF AI Pro")
                            .font(.subheadline.weight(.semibold))
                        Text("AI · Edit · Sign · Free trial")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DesignSystem.Spacing.s)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(DesignSystem.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.medium)
                        .strokeBorder(.tint.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    Haptics.selection()
                    dismissedAt = Date.now.timeIntervalSince1970
                    refreshTick = UUID()
                } label: {
                    Label("Not now", systemImage: "clock")
                }
            }
        }
    }
}
