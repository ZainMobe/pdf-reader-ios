import Foundation
import PDFKit
import SwiftData

/// On-disk location for imported PDF copies and the entry point for importing files.
enum DocumentStorage {
    static let pdfStorageDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let pdfDir = appSupport.appending(path: "PDFs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        return pdfDir
    }()

    enum ImportError: Error, LocalizedError {
        case copyFailed(underlying: any Error)
        case notReadable

        var errorDescription: String? {
            switch self {
            case .copyFailed(let error): "Couldn't copy PDF: \(error.localizedDescription)"
            case .notReadable: "PDF couldn't be read."
            }
        }
    }

    /// Deletes the SwiftData record, removes the underlying PDF file from
    /// `pdfStorageDirectory`, and cascades to any bookmarks referencing the
    /// document. Call this instead of `context.delete(_:)` directly so
    /// storage and metadata don't drift apart over time.
    static func delete(_ document: Document, in context: ModelContext) {
        let url = document.fileURL
        let documentID = document.id

        let bookmarkDescriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.documentID == documentID }
        )
        if let bookmarks = try? context.fetch(bookmarkDescriptor) {
            for bookmark in bookmarks {
                context.delete(bookmark)
            }
        }

        context.delete(document)
        try? FileManager.default.removeItem(at: url)
    }

    /// Copies the file at `sourceURL` into the app's PDF storage and inserts a
    /// `Document` record into `context`. Returns the inserted document.
    @discardableResult
    static func importPDF(from sourceURL: URL, into context: ModelContext) throws -> Document {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let destinationURL = pdfStorageDirectory.appending(path: filename)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw ImportError.copyFailed(underlying: error)
        }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
        let pageCount = PDFDocument(url: destinationURL)?.pageCount ?? 0
        let title = sourceURL.deletingPathExtension().lastPathComponent

        let document = Document(
            id: id,
            title: title,
            filename: filename,
            fileSize: fileSize,
            pageCount: pageCount
        )
        context.insert(document)
        return document
    }
}
