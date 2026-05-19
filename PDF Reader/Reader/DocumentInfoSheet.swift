import SwiftUI
import PDFKit

/// Sheet that surfaces all the metadata a user might want to look up about
/// the open document — local file stats, our own state flags, and the PDF
/// container's embedded attributes (author, creator, dates, etc.).
struct DocumentInfoSheet: View {
    let document: Document
    @State private var pdfAttributes: [String: Any] = [:]
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Document") {
                    InfoRow(label: "Title", value: document.title)
                    InfoRow(label: "Pages", value: "\(document.pageCount)")
                    InfoRow(label: "Size", value: formatBytes(document.fileSize))
                    InfoRow(
                        label: "Added",
                        value: document.addedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    if let last = document.lastOpenedAt {
                        InfoRow(
                            label: "Last Opened",
                            value: last.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let folder = document.folder {
                        InfoRow(label: "Folder", value: folder.name)
                    }
                    if !document.tags.isEmpty {
                        InfoRow(label: "Tags", value: document.tags.map(\.name).joined(separator: ", "))
                    }
                }
                Section("Status") {
                    InfoRow(label: "Favorite", value: document.isFavorite ? "Yes" : "No")
                    InfoRow(label: "Signed", value: document.isSigned ? "Yes" : "No")
                    InfoRow(label: "Searchable (OCR)", value: document.ocrText != nil ? "Yes" : "No")
                    InfoRow(label: "Unread", value: document.isUnread ? "Yes" : "No")
                }
                if loaded {
                    if metadataRows.isEmpty {
                        Section("PDF Metadata") {
                            Text("This PDF doesn't have embedded metadata.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("PDF Metadata") {
                            ForEach(metadataRows, id: \.0) { row in
                                InfoRow(label: row.0, value: row.1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { loadAttributes() }
        }
    }

    private var metadataRows: [(String, String)] {
        let mappings: [(String, String)] = [
            (PDFDocumentAttribute.titleAttribute.rawValue, "Title"),
            (PDFDocumentAttribute.authorAttribute.rawValue, "Author"),
            (PDFDocumentAttribute.subjectAttribute.rawValue, "Subject"),
            (PDFDocumentAttribute.creatorAttribute.rawValue, "Creator"),
            (PDFDocumentAttribute.producerAttribute.rawValue, "Producer"),
            (PDFDocumentAttribute.creationDateAttribute.rawValue, "Created"),
            (PDFDocumentAttribute.modificationDateAttribute.rawValue, "Modified"),
            (PDFDocumentAttribute.keywordsAttribute.rawValue, "Keywords"),
        ]
        var rows: [(String, String)] = []
        for (key, displayName) in mappings {
            guard let value = pdfAttributes[key] else { continue }
            if let date = value as? Date {
                rows.append((displayName, date.formatted(date: .abbreviated, time: .shortened)))
            } else if let array = value as? [String], !array.isEmpty {
                rows.append((displayName, array.joined(separator: ", ")))
            } else if let string = value as? String, !string.isEmpty {
                rows.append((displayName, string))
            }
        }
        return rows
    }

    private func loadAttributes() {
        defer { loaded = true }
        guard
            let pdf = PDFDocument(url: document.fileURL),
            let attrs = pdf.documentAttributes
        else { return }

        var result: [String: Any] = [:]
        for (key, value) in attrs {
            if let pdfKey = key as? PDFDocumentAttribute {
                result[pdfKey.rawValue] = value
            } else if let stringKey = key as? String {
                result[stringKey] = value
            }
        }
        pdfAttributes = result
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
