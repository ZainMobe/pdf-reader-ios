import SwiftUI
import SwiftData

/// Tool sheet for stamping "N / Total" page numbers on the bottom-right of
/// every page in a selected document.
struct PageNumbersView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var selectedDoc: Document?
    @State private var error: String?
    @State private var success: ToolSuccessResult?

    var body: some View {
        NavigationStack {
            Group {
                if let success {
                    ToolSuccessView(result: success) { dismiss() }
                } else {
                    formContent
                }
            }
            .navigationTitle(success == nil ? "Add Page Numbers" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if success != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }

    private var formContent: some View {
        Form {
                Section("Apply to") {
                    if documents.isEmpty {
                        Text("No documents in your library yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(documents) { doc in
                            Button {
                                selectedDoc = doc
                            } label: {
                                HStack {
                                    Image(systemName: selectedDoc?.id == doc.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.tint)
                                    Text(doc.title)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(doc.pageCount) pages")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Text("Numbers are drawn in the bottom-right corner of each page. Original annotations and form fields are flattened in the numbered copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") { apply() }
                        .buttonStyle(.glassProminent)
                        .disabled(selectedDoc == nil)
                }
            }
            .alert(
                "Couldn't add page numbers",
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

    private func apply() {
        guard let doc = selectedDoc else { return }
        do {
            let numbered = try PDFOperations.addPageNumbers(doc, in: modelContext)
            success = ToolSuccessResult(
                title: "Page Numbers Added",
                summary: "Numbered all \(numbered.pageCount) \(numbered.pageCount == 1 ? "page" : "pages")",
                documents: [numbered]
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
