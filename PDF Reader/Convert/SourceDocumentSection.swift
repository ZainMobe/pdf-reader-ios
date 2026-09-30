import SwiftUI
import SwiftData

/// Form section for choosing one Library document as a tool's input.
/// Shows a search field once the library has more than a handful of
/// documents. Locked PDFs are handled by the tool at run time.
struct SourceDocumentSection: View {
    @Binding var selected: Document?
    var title: String = "Document"

    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]
    @State private var query = ""

    private var filtered: [Document] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return documents }
        return documents.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        Section(title) {
            if documents.isEmpty {
                Text("No documents in your library yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if documents.count > 6 {
                    TextField("Search documents", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                ForEach(filtered) { doc in
                    Button {
                        Haptics.selection()
                        selected = doc
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.m) {
                            Image(systemName: selected?.id == doc.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.tint)
                            DocumentThumbnailView(
                                documentID: doc.id,
                                documentURL: doc.fileURL,
                                thumbnailData: doc.thumbnailData,
                                placeholderIconSize: 16
                            )
                            .frame(width: 34, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(doc.pageCount) \(doc.pageCount == 1 ? "page" : "pages") · \(ByteCountFormatter.string(fromByteCount: doc.fileSize, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                if filtered.isEmpty {
                    Text("No matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
