import SwiftUI
import SwiftData

/// Settings screen that shows the user where each cloud storage provider stands.
struct SyncStatusView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    private let providers = AvailableProviders.all
    private let auth = DropboxAuthManager.shared
    private let backup = DropboxBackup.shared

    @State private var showingBrowser = false
    @State private var isBackingUp = false
    @State private var backupResult: String?

    var body: some View {
        List {
            Section("Providers") {
                ForEach(providers, id: \.id) { provider in
                    row(for: provider)
                }
            }

            Section {
                Text("To open files from any installed cloud provider, use **Library → Add → Import PDF**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBrowser) {
            DropboxBrowserView()
        }
        .alert(
            "Backup",
            isPresented: Binding(
                get: { backupResult != nil },
                set: { if !$0 { backupResult = nil } }
            )
        ) {
            Button("OK") { backupResult = nil }
        } message: {
            Text(backupResult ?? "")
        }
    }

    // MARK: - Dropbox

    @ViewBuilder
    private var dropboxSection: some View {
        if auth.isSignedIn {
            Section("Dropbox") {
                if let name = auth.accountName {
                    LabeledContent("Signed in as", value: name)
                }
                Button {
                    Haptics.impact(.light)
                    showingBrowser = true
                } label: {
                    Label("Browse Dropbox", systemImage: "folder")
                }
                Button {
                    Task { await runBackup() }
                } label: {
                    HStack {
                        Label("Back Up Library", systemImage: "icloud.and.arrow.up")
                        Spacer()
                        if let p = backup.progress {
                            ProgressView(value: p)
                                .frame(width: 60)
                        }
                    }
                }
                .disabled(isBackingUp || documents.isEmpty)
                if let lastBackup = backup.lastBackedUpAt {
                    Text("Last backup \(lastBackup.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    Haptics.impact(.light)
                    auth.signOut()
                } label: {
                    Label("Sign Out of Dropbox", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } else {
            Section("Dropbox") {
                Button {
                    Haptics.impact(.light)
                    signInToDropbox()
                } label: {
                    Label("Sign in to Dropbox", systemImage: "person.badge.key")
                }
                Text("Sign in to browse files in your Dropbox and back up your local library to a /PDF AI/ folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func signInToDropbox() {
        guard let presenter = topViewController() else { return }
        auth.signIn(from: presenter)
    }

    private func runBackup() async {
        isBackingUp = true
        defer { isBackingUp = false }
        let count = await backup.backup(documents)
        if count > 0 {
            Haptics.success()
            backupResult = "Backed up \(count) of \(documents.count) \(documents.count == 1 ? "document" : "documents") to Dropbox."
        } else {
            Haptics.error()
            backupResult = backup.lastError ?? "No files were uploaded."
        }
    }

    /// Walks the active scene's window hierarchy to find the topmost view
    /// controller. SwiftyDropbox's `authorizeFromControllerV2(_:controller:...)`
    /// needs a real UIViewController to present its sign-in surface.
    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.keyWindow?.rootViewController else { return nil }
        var top: UIViewController = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Rows

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
        case (true, true):
            return "Signed in"
        case (true, false):
            return provider.id == "dropbox"
                ? "Sign in below to browse and back up"
                : "Sign in to your Apple Account to sync"
        case (false, _):
            return "SDK integration in progress"
        }
    }
}

#Preview {
    NavigationStack {
        SyncStatusView()
    }
}
