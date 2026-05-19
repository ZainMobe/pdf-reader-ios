import SwiftUI

/// Fallback root view shown when `ModelContainer` initialization fails at
/// launch. Replaces what used to be a `fatalError` so the user sees a
/// recovery message instead of a crash.
struct BootErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Start PDF AI", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } description: {
            VStack(spacing: DesignSystem.Spacing.s) {
                Text(message)
                Text("Reopening the app will retry. If the problem continues, reinstalling will reset local data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .padding(DesignSystem.Spacing.xl)
    }
}

#Preview {
    BootErrorView(message: "Failed to open the document database.")
}
