import SwiftUI
import SwiftData

/// Tool sheet for combining multiple PDFs into one. Tap documents to select
/// them; merge order matches tap order (shown as numbered badges).
struct MergePDFsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var selected: [Document] = []
    @State private var title = "Merged PDF"
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
            .navigationTitle(success == nil ? "Merge PDFs" : "Done")
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
        List {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section {
                    Text("Tap documents in the order you want them merged. Tap again to deselect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Documents") {
                    if documents.isEmpty {
                        Text("No documents in your library yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(documents) { doc in
                            Button {
                                toggle(doc)
                            } label: {
                                row(for: doc)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(mergeLabel) { merge() }
                        .buttonStyle(.glassProminent)
                        .disabled(selected.count < 2)
                }
            }
            .alert(
                "Couldn't merge",
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

    private var mergeLabel: String {
        selected.count < 2 ? "Select 2+" : "Merge \(selected.count)"
    }

    private func row(for doc: Document) -> some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            if let order = selectedIndex(of: doc) {
                Text("\(order + 1)")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.tint))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading) {
                Text(doc.title)
                    .foregroundStyle(.primary)
                Text("\(doc.pageCount) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func selectedIndex(of doc: Document) -> Int? {
        selected.firstIndex(where: { $0.id == doc.id })
    }

    private func toggle(_ doc: Document) {
        if let index = selected.firstIndex(where: { $0.id == doc.id }) {
            selected.remove(at: index)
        } else {
            selected.append(doc)
        }
    }

    private func merge() {
        do {
            let sourceCount = selected.count
            let merged = try PDFOperations.merge(
                selected,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                in: modelContext
            )
            success = ToolSuccessResult(
                title: "PDFs Merged",
                summary: "Combined \(sourceCount) documents into 1 — \(merged.pageCount) pages total",
                documents: [merged]
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
