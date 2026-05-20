import SwiftUI
import SwiftData

/// Sheet that lets the user navigate folders in their Dropbox and import
/// PDFs into the local Library. Folders are explorable; .pdf files have
/// an "Import" button that downloads the file to a temp URL and then
/// hands off to `DocumentStorage.importPDF(from:into:)`.
struct DropboxBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var path: String = ""
    @State private var entries: [DropboxService.Entry] = []
    @State private var pathStack: [String] = [""]
    @State private var isLoading = false
    @State private var error: String?
    @State private var importingID: String?
    @State private var importedCount = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(path.isEmpty ? "Dropbox" : URL(fileURLWithPath: path).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if pathStack.count > 1 {
                            Button {
                                navigateUp()
                            } label: {
                                Label("Up", systemImage: "chevron.left")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    await load()
                }
                .alert(
                    "Couldn't load Dropbox",
                    isPresented: Binding(
                        get: { error != nil },
                        set: { if !$0 { error = nil } }
                    )
                ) {
                    Button("OK") { error = nil }
                } message: {
                    Text(error ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No PDFs here",
                systemImage: "doc",
                description: Text("This folder has no PDF files or subfolders.")
            )
        } else {
            List(entries) { entry in
                row(entry)
            }
            .refreshable {
                await load()
            }
            .overlay(alignment: .top) {
                if importedCount > 0 {
                    importedToast
                }
            }
        }
    }

    private func row(_ entry: DropboxService.Entry) -> some View {
        Button {
            if entry.isFolder {
                navigate(into: entry.path)
            } else {
                Task { await importPDF(entry) }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.m) {
                Image(systemName: entry.isFolder ? "folder.fill" : "doc.text.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(entry.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let size = entry.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if importingID == entry.id {
                    ProgressView()
                } else if entry.isFolder {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importingID != nil)
    }

    private var importedToast: some View {
        Text("Imported \(importedCount) \(importedCount == 1 ? "file" : "files")")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, DesignSystem.Spacing.l)
            .padding(.vertical, DesignSystem.Spacing.m)
            .glassEffect(.regular.tint(Color.green.opacity(0.3)), in: .capsule)
            .padding(.top, DesignSystem.Spacing.s)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func navigate(into newPath: String) {
        Haptics.selection()
        pathStack.append(newPath)
        path = newPath
        Task { await load() }
    }

    private func navigateUp() {
        guard pathStack.count > 1 else { return }
        Haptics.selection()
        pathStack.removeLast()
        path = pathStack.last ?? ""
        Task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await DropboxService.listFolder(at: path)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importPDF(_ entry: DropboxService.Entry) async {
        importingID = entry.id
        defer { importingID = nil }
        do {
            let url = try await DropboxService.download(path: entry.path)
            try DocumentStorage.importPDF(from: url, into: modelContext)
            try? FileManager.default.removeItem(at: url)
            Haptics.success()
            withAnimation { importedCount += 1 }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { importedCount = 0 }
            }
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
