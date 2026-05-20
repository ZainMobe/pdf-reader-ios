import SwiftUI
import SwiftData

/// In-sheet success screen shown after a Tools operation completes.
///
/// Replaces the configuration form with a confirmation that includes
/// an animated checkmark, a one-line summary, cards for each resulting
/// `Document`, and primary actions to open them or dismiss.
struct ToolSuccessView: View {
    let result: ToolSuccessResult
    let onDone: () -> Void

    @Environment(\.openWindow) private var openWindow

    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.xl) {
                successBadge
                    .padding(.top, DesignSystem.Spacing.xl)

                VStack(spacing: DesignSystem.Spacing.s) {
                    Text(result.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(result.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .opacity(contentOpacity)
                .padding(.horizontal, DesignSystem.Spacing.l)

                VStack(spacing: DesignSystem.Spacing.m) {
                    ForEach(result.documents) { doc in
                        documentCard(doc)
                    }
                }
                .opacity(contentOpacity)
                .padding(.horizontal, DesignSystem.Spacing.l)

                Button {
                    Haptics.impact(.light)
                    onDone()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.m)
                }
                .buttonStyle(.glassProminent)
                .opacity(contentOpacity)
                .padding(.horizontal, DesignSystem.Spacing.l)
                .padding(.bottom, DesignSystem.Spacing.xl)
            }
        }
        .onAppear {
            Haptics.success()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.15)) {
                contentOpacity = 1.0
            }
        }
    }

    // MARK: - Pieces

    private var successBadge: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 96, height: 96)
            Circle()
                .stroke(Color.green.opacity(0.35), lineWidth: 2)
                .frame(width: 96, height: 96)
            Image(systemName: "checkmark")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.green)
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)
        }
    }

    private func documentCard(_ doc: Document) -> some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: "doc.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
            }
            .frame(width: 44, height: 56)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(doc.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(doc.pageCount) \(doc.pageCount == 1 ? "page" : "pages") · \(ByteCountFormatter.string(fromByteCount: doc.fileSize, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Haptics.impact(.light)
                let id = doc.id
                onDone()
                DispatchQueue.main.async {
                    openWindow(value: id)
                }
            } label: {
                Text("Open")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, DesignSystem.Spacing.m)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glass)
        }
        .padding(DesignSystem.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

/// Payload used by `ToolSuccessView` to render its title, summary,
/// and per-document cards.
struct ToolSuccessResult {
    let title: String
    let summary: String
    let documents: [Document]
}
