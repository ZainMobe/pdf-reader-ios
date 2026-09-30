import SwiftData
import SwiftUI

/// Tool sheet: flatten annotations and form fields into the page content.
struct FlattenPDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDoc: Document?
    @State private var replaceOriginal = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var success: ToolSuccessResult?

    var body: some View {
        NavigationStack {
            Group {
                if let success {
                    ToolSuccessView(result: success) { dismiss() }
                } else {
                    Form {
                        SourceDocumentSection(selected: $selectedDoc)
                        Section {
                            Toggle("Replace original in Library", isOn: $replaceOriginal)
                        } footer: {
                            Text("Highlights, ink, signatures, stamps, notes and filled form fields become a permanent part of each page. Nobody can move, edit or delete them afterwards. Text stays selectable.")
                        }
                    }
                }
            }
            .navigationTitle(success == nil ? "Flatten PDF" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if success != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
                } else {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(isWorking) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Flatten") { apply() }
                            .buttonStyle(.glassProminent)
                            .disabled(selectedDoc == nil || isWorking)
                    }
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Flattening…").font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .alert("Couldn't flatten", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func apply() {
        guard let doc = selectedDoc else { return }
        isWorking = true
        let replace = replaceOriginal
        Task {
            defer { isWorking = false }
            await DocumentStorage.ensureDownloaded(at: doc.fileURL)
            do {
                let result = try PDFOperations.flatten(doc, replaceOriginal: replace, in: modelContext)
                try? modelContext.save()
                success = ToolSuccessResult(
                    title: "PDF Flattened",
                    summary: "Annotations and form fields are now part of the page content.",
                    documents: [result]
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
