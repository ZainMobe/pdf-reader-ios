import Foundation
import PDFKit
import SwiftData
import UIKit

/// Converts an array of scanned page images into a single PDF, runs Vision OCR
/// for searchable text, draws the OCR'd glyphs as an *invisible* layer
/// underneath the page image, and inserts a `Document` record.
///
/// The invisible layer is what makes the output a true "searchable image PDF" —
/// PDFKit's `findString` and `pdf.string` both pick up the text even though
/// nothing is rendered visually.
enum ScanToPDF {
    enum ScanError: Error, LocalizedError {
        case writeFailed
        case noPages

        var errorDescription: String? {
            switch self {
            case .writeFailed: "Couldn't save the scanned PDF."
            case .noPages: "No pages were captured."
            }
        }
    }

    @discardableResult
    static func createDocument(
        from images: [UIImage],
        in context: ModelContext,
        title: String = "Scan"
    ) async throws -> Document {
        guard !images.isEmpty else { throw ScanError.noPages }

        let ocrByPage = await OCRPipeline.recognizeAllDetailed(images)

        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let destinationURL = DocumentStorage.pdfStorageDirectory.appending(path: filename)

        // Render off the main thread. Pages are sized in points via the
        // shared `ImagesToPDF` layout (longest edge 792 pt) rather than the
        // camera's pixel dimensions, and the bitmap is capped and embedded
        // as JPEG. The previous path produced 42"x56" pages holding
        // uncompressed 12 MP bitmaps — 150 MB+ for a ten-page scan.
        let options = ImagesToPDF.Options(pageSize: .fitImage, jpegQuality: 0.8)
        let data = await Task.detached(priority: .userInitiated) { () -> Data in
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            return renderer.pdfData { ctx in
                for (pageIndex, original) in images.enumerated() {
                    autoreleasepool {
                        let image = ImagesToPDF.capped(original)
                        let (pageRect, drawRect) = ImagesToPDF.layout(for: image.size, options: options)
                        ctx.beginPage(withBounds: pageRect, pageInfo: [:])
                        if let jpeg = image.jpegData(compressionQuality: options.jpegQuality),
                           let compact = UIImage(data: jpeg) {
                            compact.draw(in: drawRect)
                        } else {
                            image.draw(in: drawRect)
                        }
                        // Vision boxes are normalised, so they map onto the
                        // scaled draw rect unchanged.
                        let boxes = pageIndex < ocrByPage.count ? ocrByPage[pageIndex] : []
                        ImagesToPDF.drawInvisibleText(boxes, in: drawRect)
                    }
                }
            }
        }.value

        try data.write(to: destinationURL, options: [.atomic])

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
        let dateLabel = Date.now.formatted(date: .abbreviated, time: .shortened)

        let aggregateText = ocrByPage
            .map { $0.map(\.string).joined(separator: "\n") }
            .joined(separator: "\n\n")

        let document = Document(
            id: id,
            title: "\(title) · \(dateLabel)",
            filename: filename,
            fileSize: fileSize,
            pageCount: images.count
        )
        document.ocrText = aggregateText.isEmpty ? nil : aggregateText
        document.thumbnailData = await Task.detached(priority: .utility) {
            ThumbnailGenerator.persistableThumbnailData(at: destinationURL)
        }.value
        context.insert(document)
        return document
    }
}
