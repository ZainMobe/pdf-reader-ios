import SwiftUI

/// Glass mini-player pinned to the bottom of the Reader while read-aloud is
/// active. Tap-and-hold targets are large enough to be usable while walking.
struct ReadAloudControls: View {
    @Bindable var aloud: ReadAloud

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.l) {
            Button {
                aloud.skipBackward()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .disabled(aloud.currentPageIndex == 0)

            Button {
                aloud.togglePlayPause()
            } label: {
                Image(systemName: aloud.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title)
            }

            Button {
                aloud.skipForward()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .disabled(aloud.currentPageIndex >= max(0, aloud.totalPages - 1))

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Page \(aloud.currentPageIndex + 1) of \(aloud.totalPages)")
                    .font(.caption)
                Text(aloud.state == .paused ? "Paused" : "Reading aloud")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                aloud.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.l)
        .padding(.vertical, DesignSystem.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.large))
        .padding(.horizontal, DesignSystem.Spacing.l)
        .padding(.bottom, DesignSystem.Spacing.l)
    }
}
