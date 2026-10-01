import SwiftUI
import PDFKit

/// Sheet for editing the page order, rotation, and inclusion of a document's
/// pages. Changes accumulate in memory; "Done" writes back to disk.
struct PageEditorView: View {
    @Bindable var document: Document
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var editor: PageEditor?
    @State private var isLoading = true
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let editor {
                    if editor.isEncrypted {
                        ContentUnavailableView(
                            "Encrypted PDF",
                            systemImage: "lock.fill",
                            description: Text("Open this PDF in the Reader, enter the password, and try again.")
                        )
                    } else {
                        pageList(editor)
                    }
                } else if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Couldn't open document",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .navigationTitle("Edit Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { saveAndDismiss() }
                        .buttonStyle(.glassProminent)
                }
            }
            .alert(
                "Couldn't save",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .task {
            guard editor == nil else { return }
            let url = document.fileURL
            await DocumentStorage.ensureDownloaded(at: url)
            editor = PageEditor(url: url)
            isLoading = false
        }
    }

    @ViewBuilder
    private func pageList(_ editor: PageEditor) -> some View {
        let _ = editor.refreshToken
        let canDelete = editor.pageCount > 1
        List {
            ForEach(0..<editor.pageCount, id: \.self) { index in
                HStack(spacing: DesignSystem.Spacing.m) {
                    PageThumbnail(page: editor.page(at: index))
                        .frame(width: 44, height: 56)
                    Text("Page \(index + 1)")
                        .font(.headline)
                    Spacer()
                    Button {
                        Haptics.impact(.light)
                        editor.rotate(at: index)
                    } label: {
                        Image(systemName: "rotate.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rotate page \(index + 1)")

                    Button(role: .destructive) {
                        Haptics.impact(.medium)
                        editor.delete(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(canDelete ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canDelete)
                    .accessibilityLabel("Delete page \(index + 1)")
                }
                .contextMenu {
                    Button {
                        editor.rotate(at: index)
                    } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }
                    Button(role: .destructive) {
                        editor.delete(at: index)
                    } label: {
                        Label("Delete Page", systemImage: "trash")
                    }
                    .disabled(!canDelete)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        editor.delete(at: index)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!canDelete)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        editor.rotate(at: index)
                    } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }
                    .tint(.blue)
                }
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                editor.move(from: from, to: destination)
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private func saveAndDismiss() {
        guard let editor else { dismiss(); return }
        do {
            try editor.save()
            let newPageCount = editor.pageCount
            document.pageCount = newPageCount
            // Keep Library metadata and the cached first-page thumbnail in
            // step with the rewritten file.
            let url = document.fileURL
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
                document.fileSize = size
            }
            document.lastPageIndex = min(document.lastPageIndex, max(0, newPageCount - 1))
            ThumbnailCache.shared.invalidate(document.id)
            Task { [document] in
                let data = await Task.detached(priority: .utility) {
                    ThumbnailGenerator.persistableThumbnailData(at: url)
                }.value
                if let data { document.thumbnailData = data }
            }
            onSave()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
