import SwiftUI

/// Settings screen that shows the user where each cloud storage provider stands.
struct SyncStatusView: View {
    private let providers = AvailableProviders.all

    var body: some View {
        List {
            ForEach(providers, id: \.id) { provider in
                row(for: provider)
            }
            Section {
                Text("To open files from any installed cloud provider — including iCloud Drive, Dropbox, Google Drive, OneDrive, and Box — use **Library → Add → Import PDF**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for provider: any CloudStorageProvider) -> some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            Image(systemName: provider.iconSystemName)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(provider.displayName)
                Text(status(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !provider.isSupported {
                Text("Coming Soon")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, DesignSystem.Spacing.s)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(Capsule().fill(.tertiary))
            }
        }
    }

    private func status(for provider: any CloudStorageProvider) -> String {
        switch (provider.isSupported, provider.isInstalled) {
        case (true, true): "Signed in"
        case (true, false): "Sign in to your Apple Account to sync"
        case (false, _): "SDK integration in progress"
        }
    }
}

#Preview {
    NavigationStack {
        SyncStatusView()
    }
}
