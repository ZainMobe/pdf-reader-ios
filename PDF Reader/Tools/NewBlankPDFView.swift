import SwiftUI

/// Tool sheet for creating a blank PDF with a chosen page count + size.
struct NewBlankPDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = "Untitled"
    @State private var pageCount = 1
    @State private var pageSize: PDFOperations.PageSize = .letter
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled", text: $title)
                }
                Section("Format") {
                    Picker("Page Size", selection: $pageSize) {
                        ForEach(PDFOperations.PageSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    Stepper(value: $pageCount, in: 1...100) {
                        Text("Pages: \(pageCount)")
                    }
                }
            }
            .navigationTitle("New Blank PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { create() }
                        .buttonStyle(.glassProminent)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(
                "Couldn't create",
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

    private func create() {
        do {
            try PDFOperations.createBlank(
                pageCount: pageCount,
                pageSize: pageSize,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                in: modelContext
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
