import SwiftUI
import SwiftData

/// Tool sheet for compressing a PDF. Pick a document, choose a quality
/// preset, and apply. The compressed copy is added to the Library; the
/// original is untouched.
struct CompressView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var selectedDoc: Document?
    @State private var quality: PDFOperations.CompressionQuality = .medium
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Quality") {
                    ForEach(PDFOperations.CompressionQuality.allCases) { option in
                        Button {
                            quality = option
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.m) {
                                Image(systemName: quality == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    Text(option.displayName)
                                        .foregroundStyle(.primary)
                                    Text(option.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                                    VStack(alignment: .leading) {
                                        Text(doc.title)
                                            .foregroundStyle(.primary)
                                        Text("\(doc.pageCount) pages")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: doc.fileSize, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Text("Compression rasterizes each page through JPEG. Selectable text, annotations, and form fields are flattened in the compressed copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Compress PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Compress") { apply() }
                        .buttonStyle(.glassProminent)
                        .disabled(selectedDoc == nil || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Compressing…")
                            .font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .alert(
                "Couldn't compress",
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

    private func apply() {
        guard let doc = selectedDoc else { return }
        isWorking = true
        // Defer one frame so the progress overlay renders before the
        // synchronous compression starts.
        DispatchQueue.main.async {
            do {
                try PDFOperations.compress(doc, quality: quality, in: modelContext)
                isWorking = false
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}
