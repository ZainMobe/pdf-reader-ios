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
                                    Text("\(folder.documents.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    modelContext.delete(folder)
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
