import Foundation
import PDFKit
import SwiftData

extension DocumentStorage {
    /// Moves an already-generated PDF at `tempURL` into managed storage and
    /// inserts a `Document` for it. Used for PDFs the app produced itself
    /// (image conversions, shared-inbox batches, tool outputs) where the
    /// source file is disposable and a copy would be wasted work.
    ///
    /// Falls back to copy + delete when a cross-volume move isn't possible
    /// (e.g. tmp on the device, storage in the iCloud container).
    @discardableResult
    static func adoptGeneratedPDF(
        at tempURL: URL,
        title: String,
        into context: ModelContext
    ) throws -> Document {
        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let destinationURL = pdfStorageDirectory.appending(path: filename)

        do {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        } catch {
            do {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                throw ImportError.copyFailed(underlying: error)
            }
        }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
        let pdfDocument = PDFDocument.opened(at: destinationURL)

        let document = Document(
            id: id,
            title: sanitizedTitle(title),
            filename: filename,
            fileSize: fileSize,
            pageCount: pdfDocument?.pageCount ?? 0
        )
        if let body = pdfDocument?.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.ocrText = body
        }
        document.thumbnailData = ThumbnailGenerator.persistableThumbnailData(at: destinationURL)
        context.insert(document)
        return document
    }

    /// Normalises a filename-derived title: trims, collapses whitespace,
    /// strips characters that render badly, caps length, never empty.
    nonisolated static func sanitizedTitle(_ raw: String, fallback: String = "Document") -> String {
        var s = raw
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if s.count > 120 { s = String(s.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? fallback : s
    }

    /// Finds a document in the Library whose on-disk bytes are identical to
    /// the file at `url`. Cheap: only documents with the same byte size are
    /// compared, and the comparison short-circuits on the first difference.
    /// Returns nil when the file is new or the comparison can't be made.
    @MainActor
    static func existingDuplicate(of url: URL, in context: ModelContext) async -> Document? {
        guard let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64), size > 0 else { return nil }

        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.fileSize == size })
        guard let candidates = try? context.fetch(descriptor), !candidates.isEmpty else { return nil }

        for candidate in candidates {
            let candidateURL = candidate.fileURL
            await ensureDownloaded(at: candidateURL)
            let same = await Task.detached(priority: .userInitiated) {
                FileManager.default.contentsEqual(atPath: url.path, andPath: candidateURL.path)
            }.value
            if same { return candidate }
        }
        return nil
    }
}
