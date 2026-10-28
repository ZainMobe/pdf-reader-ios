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
    private(set) var movedCount = 0
    private(set) var deletedCount = 0
    private(set) var rotatedCount = 0

    init?(url: URL) {
        guard let pdf = PDFDocument.opened(at: url) else { return nil }
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
        movedCount += 1
        refreshToken = UUID()
    }

    func delete(at index: Int) {
        guard index < document.pageCount else { return }
        document.removePage(at: index)
        deletedCount += 1
        refreshToken = UUID()
    }

    func rotate(at index: Int) {
        guard let page = document.page(at: index) else { return }
        page.rotation = (page.rotation + 90) % 360
        rotatedCount += 1
        refreshToken = UUID()
    }

    func save() throws {
        guard document.pageCount > 0 else { throw EditError.noPages }

        // Coordinate the write so any open Reader windows on this URL
        // pick up the change (via their NSFilePresenter) without racing
        // with a debounced annotation save.
        //
        // Write to a temp file first and swap it in: `PDFDocument.write(to:)`
        // streams straight onto the target, so a failure mid-write (disk
        // full, suspension) would leave the only copy truncated.
        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if let password = DocumentPasswordStore.password(for: originalURL) {
            writeOptions[.userPasswordOption] = password
            writeOptions[.ownerPasswordOption] = password
        }
        let coordinator = NSFileCoordinator()
        var success = false
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: originalURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            let temp = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            let wrote = writeOptions.isEmpty
                ? document.write(to: temp)
                : document.write(to: temp, withOptions: writeOptions)
            guard wrote else { return }
            do {
                _ = try FileManager.default.replaceItemAt(coordinatedURL, withItemAt: temp)
                success = true
            } catch {
                success = false
            }
        }

        guard success, coordinationError == nil else { throw EditError.writeFailed }
    }
}
