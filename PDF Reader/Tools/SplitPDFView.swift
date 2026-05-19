import SwiftUI
import SwiftData

/// Tool sheet for splitting a PDF into two documents at a chosen page.
struct SplitPDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var selectedDoc: Document?
    @State private var splitAfter = 1
    @State private var error: String?

    private var splittable: [Document] {
        documents.filter { $0.pageCount > 1 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Choose document") {
                    if splittable.isEmpty {
                        Text("No multi-page documents in your library yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(splittable) { doc in
                            Button {
                                selectedDoc = doc
                                splitAfter = max(1, doc.pageCount / 2)
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

                if let doc = selectedDoc, doc.pageCount > 1 {
                    Section("Split point") {
                        Stepper(value: $splitAfter, in: 1...(doc.pageCount - 1)) {
                            Text("After page \(splitAfter)")
                        }
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("**Part 1** — pages 1 to \(splitAfter)")
                            Text("**Part 2** — pages \(splitAfter + 1) to \(doc.pageCount)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Split PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Split") { split() }
                        .buttonStyle(.glassProminent)
                        .disabled(selectedDoc == nil)
                }
            }
            .alert(
                "Couldn't split",
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

    private func split() {
        guard let doc = selectedDoc else { return }
        do {
            _ = try PDFOperations.split(doc, atPage: splitAfter, in: modelContext)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
