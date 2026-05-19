import SwiftUI
import PDFKit

/// Sheet for editing the page order, rotation, and inclusion of a document's
/// pages. Changes accumulate in memory; "Done" writes back to disk.
struct PageEditorView: View {
    @Bindable var document: Document
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var editor: PageEditor?
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
        .onAppear {
            editor = PageEditor(url: document.fileURL)
        }
    }

    @ViewBuilder
    private func pageList(_ editor: PageEditor) -> some View {
        let _ = editor.refreshToken
        List {
            ForEach(0..<editor.pageCount, id: \.self) { index in
                HStack(spacing: DesignSystem.Spacing.m) {
                    PageThumbnail(page: editor.page(at: index))
                        .frame(width: 44, height: 56)
                    Text("Page \(index + 1)")
                        .font(.headline)
                    Spacer()
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        editor.delete(at: index)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
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
            document.pageCount = editor.pageCount
            onSave()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
