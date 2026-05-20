import SwiftUI
import SwiftData

/// Tool sheet for creating a blank PDF with a chosen page count + size.
struct NewBlankPDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = "Untitled"
    @State private var pageCount = 1
    @State private var pageSize: PDFOperations.PageSize = .letter
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
            .navigationTitle(success == nil ? "New Blank PDF" : "Done")
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

    private func create() {
        do {
            let blank = try PDFOperations.createBlank(
                pageCount: pageCount,
                pageSize: pageSize,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                in: modelContext
            )
            success = ToolSuccessResult(
                title: "Blank PDF Created",
                summary: "\(blank.pageCount) \(blank.pageCount == 1 ? "page" : "pages") · \(pageSize.displayName)",
                documents: [blank]
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
