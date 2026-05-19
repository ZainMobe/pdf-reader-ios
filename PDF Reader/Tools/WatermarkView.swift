import SwiftUI
import SwiftData

/// Tool sheet for adding a diagonal text watermark across every page of a
/// selected document. The result is saved as a new document so the original
/// stays intact.
struct WatermarkView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var selectedDoc: Document?
    @State private var watermarkText = "CONFIDENTIAL"
    @State private var opacity: Double = 0.2
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Watermark") {
                    TextField("Text", text: $watermarkText)
                        .textInputAutocapitalization(.characters)
                    HStack {
                        Text("Opacity")
                        Slider(value: $opacity, in: 0.1...0.8)
                        Text("\(Int(opacity * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
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
                    Text("Annotations and form fields on the original document are flattened in the watermarked copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Watermark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") { apply() }
                        .buttonStyle(.glassProminent)
                        .disabled(!canApply)
                }
            }
            .alert(
                "Couldn't add watermark",
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

    private var canApply: Bool {
        selectedDoc != nil
            && !watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func apply() {
        guard let doc = selectedDoc else { return }
        do {
            try PDFOperations.watermark(
                doc,
                text: watermarkText.trimmingCharacters(in: .whitespacesAndNewlines),
                opacity: opacity,
                in: modelContext
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
