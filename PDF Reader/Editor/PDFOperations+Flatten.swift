import Foundation
import PDFKit
import SwiftData

extension PDFOperations {
    enum FlattenError: LocalizedError {
        case nothingToFlatten
        var errorDescription: String? {
            switch self {
            case .nothingToFlatten: "This PDF has no annotations or form fields to flatten."
            }
        }
    }

    /// Burns annotations (highlights, ink, signatures, stamps, notes) and
    /// filled form fields into the page content so they can't be moved or
    /// removed by another app. Text stays selectable; only the markup
    /// becomes part of the page. Produces a copy unless `replaceOriginal`.
    @discardableResult
    static func flatten(_ source: Document, replaceOriginal: Bool, in context: ModelContext) throws -> Document {
        guard let pdf = PDFDocument.opened(at: source.fileURL) else { throw OpError.noSourceDocument }
        try ensureUnlocked(pdf)

        var annotationCount = 0
        for i in 0..<pdf.pageCount {
            annotationCount += pdf.page(at: i)?.annotations.count ?? 0
        }
        guard annotationCount > 0 else { throw FlattenError.nothingToFlatten }

        let newID = UUID()
        let filename = "\(newID.uuidString).pdf"
        let url = DocumentStorage.pdfStorageDirectory.appending(path: filename)

        var options: [PDFDocumentWriteOption: Any] = [.burnInAnnotationsOption: true]
        if let password = DocumentPasswordStore.password(for: source.fileURL) {
            options[.userPasswordOption] = password
            options[.ownerPasswordOption] = password
        }
        guard pdf.write(to: url, withOptions: options) else { throw OpError.writeFailed }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let document = Document(
            id: newID,
            title: replaceOriginal ? source.title : "\(source.title) (Flattened)",
            filename: filename,
            fileSize: size,
            pageCount: pdf.pageCount
        )
        document.ocrText = source.ocrText
        document.thumbnailData = ThumbnailGenerator.persistableThumbnailData(at: url)
        document.isSigned = source.isSigned
        if replaceOriginal {
            document.folder = source.folder
            document.tags = source.tags
            document.isFavorite = source.isFavorite
            document.addedAt = source.addedAt
        }
        context.insert(document)
        if let password = DocumentPasswordStore.password(for: source.fileURL) {
            DocumentPasswordStore.store(password, for: url)
        }
        if replaceOriginal {
            DocumentStorage.delete(source, in: context)
        }
        return document
    }
}
