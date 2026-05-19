import Foundation
import PDFKit

/// Mutates a `PDFDocument` in memory for page-level edits — reorder, delete,
/// rotate — then writes the result back to disk on `save()`.
///
/// Holds a single in-memory `PDFDocument`; views observe `refreshToken` to
/// pick up changes after each mutation.
@MainActor
@Observable
final class PageEditor {
    enum EditError: Error, LocalizedError {
        case noPages
        case writeFailed
        case sourceEncrypted

        var errorDescription: String? {
            switch self {
            case .noPages: "A document must have at least one page."
            case .writeFailed: "Couldn't save edits to disk."
            case .sourceEncrypted: "This PDF is encrypted. Unlock it in the Reader first."
            }
        }
    }

    let originalURL: URL
    private let document: PDFDocument
    private(set) var refreshToken = UUID()
    let isEncrypted: Bool

    init?(url: URL) {
        guard let pdf = PDFDocument(url: url) else { return nil }
        self.originalURL = url
        self.document = pdf
        self.isEncrypted = pdf.isLocked
    }

    var pageCount: Int { document.pageCount }

    func page(at index: Int) -> PDFPage? { document.page(at: index) }

    func move(from source: Int, to destination: Int) {
        guard source != destination, let page = document.page(at: source) else { return }
        document.removePage(at: source)
        let adjustedDestination = destination > source ? destination - 1 : destination
        document.insert(page, at: adjustedDestination)
        refreshToken = UUID()
    }

    func delete(at index: Int) {
        guard index < document.pageCount else { return }
        document.removePage(at: index)
        refreshToken = UUID()
    }

    func rotate(at index: Int) {
        guard let page = document.page(at: index) else { return }
        page.rotation = (page.rotation + 90) % 360
        refreshToken = UUID()
    }

    func save() throws {
        guard document.pageCount > 0 else { throw EditError.noPages }
        guard document.write(to: originalURL) else { throw EditError.writeFailed }
    }
}
