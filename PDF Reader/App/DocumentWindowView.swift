import SwiftUI
import SwiftData

/// Root view for a per-document window. Resolves a `Document` by ID from the
/// shared SwiftData store and presents it inside a fresh `NavigationStack`.
///
/// Used by the secondary `WindowGroup` in `PDFAIApp`, which is opened via
/// `openWindow(value: document.id)` from the Library and Reader.
struct DocumentWindowView: View {
    let documentID: UUID?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if let document = resolveDocument() {
            NavigationStack {
                ReaderView(document: document)
            }
        } else {
            ContentUnavailableView(
                "Document Not Available",
                systemImage: "doc.text",
                description: Text("The document may have been deleted or hasn't synced yet.")
            )
        }
    }

    private func resolveDocument() -> Document? {
        guard let documentID else { return nil }
        var descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.id == documentID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
