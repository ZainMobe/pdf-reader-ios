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
        let pdfDocument = PDFDocument(url: destinationURL)
        let pageCount = pdfDocument?.pageCount ?? 0
        let title = sourceURL.deletingPathExtension().lastPathComponent

        let document = Document(
            id: id,
            title: title,
            filename: filename,
            fileSize: fileSize,
            pageCount: pageCount
        )

        // Index the document's embedded text so it's searchable from the
        // Library on the next pass. Scanned PDFs already populate `ocrText`
        // via the OCR pipeline; this covers imported PDFs that already
        // carry their own text layer.
        if let body = pdfDocument?.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.ocrText = body
        }

        context.insert(document)
        return document
    }
}

/// One-shot backfill that indexes embedded PDF text for any document whose
/// `ocrText` is still `nil`. Runs lazily from the Library so older imports
/// (and documents synced in from other devices) become searchable without a
/// migration.
@MainActor
enum SearchableTextBackfill {
    private static var didRun = false

    static func runIfNeeded(in context: ModelContext) async {
        guard !didRun else { return }
        didRun = true

        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.ocrText == nil }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        for document in pending {
            if Task.isCancelled { return }
            let url = document.fileURL
            let extracted = await Task.detached(priority: .utility) {
                extractText(at: url)
            }.value
            if let extracted {
                document.ocrText = extracted
            }
            await Task.yield()
        }
    }

    nonisolated private static func extractText(at url: URL) -> String? {
        guard
            let pdf = PDFDocument(url: url),
            !pdf.isLocked,
            let body = pdf.string,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return body
    }
}
