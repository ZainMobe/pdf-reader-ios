import SwiftUI
import SwiftData

/// Lightweight folder admin — create, rename, and delete folders.
/// Folder ↔ document associations are managed inline via the document's
/// context menu in `LibraryHomeView`.
struct FolderManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.createdAt, order: .reverse) private var folders: [Folder]

    @State private var newName = ""
    @State private var renameText = ""
    @State private var renamingFolder: Folder?
    @State private var deletingFolder: Folder?

    var body: some View {
        NavigationStack {
            List {
                Section("New Folder") {
                    HStack(spacing: DesignSystem.Spacing.s) {
                        TextField("Folder name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            createFolder()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(canCreate ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canCreate)
                    }
                }

                if folders.isEmpty {
                    Section {
                        Text("No folders yet. Add one above to start organizing documents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Folders") {
                        ForEach(folders) { folder in
                            Button {
                                renamingFolder = folder
                                renameText = folder.name
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.tint)
                                    Text(folder.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\((folder.documents ?? []).count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deletingFolder = folder
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Folders")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete \u{201C}\(deletingFolder?.name ?? "")\u{201D}?",
                isPresented: Binding(
                    get: { deletingFolder != nil },
                    set: { if !$0 { deletingFolder = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Folder", role: .destructive) {
                    if let folder = deletingFolder {
                        // Documents keep their files; they just leave the folder.
                        for document in folder.documents ?? [] { document.folder = nil }
                        modelContext.delete(folder)
                    }
                    deletingFolder = nil
                }
                Button("Cancel", role: .cancel) { deletingFolder = nil }
            } message: {
                let count = deletingFolder?.documents?.count ?? 0
                Text(count == 0
                     ? "The folder will be removed."
                     : "The \(count) \(count == 1 ? "document" : "documents") inside stay in your Library; only the folder is removed.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Rename Folder",
                isPresented: Binding(
                    get: { renamingFolder != nil },
                    set: { if !$0 { renamingFolder = nil; renameText = "" } }
                )
            ) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    renamingFolder = nil
                    renameText = ""
                }
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let folder = renamingFolder, !trimmed.isEmpty {
                        folder.name = trimmed
                    }
                    renamingFolder = nil
                    renameText = ""
                }
            }
        }
    }

    private var canCreate: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createFolder() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = Folder(name: trimmed)
        modelContext.insert(folder)
        newName = ""
    }
}
