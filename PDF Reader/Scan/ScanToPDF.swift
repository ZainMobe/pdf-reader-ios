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

        // Use the first image's bounds for the renderer's default; each
        // page resets its own bounds via beginPage(withBounds:pageInfo:).
        let firstBounds = CGRect(origin: .zero, size: images[0].size)
        let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)

        let data = renderer.pdfData { ctx in
            for (pageIndex, image) in images.enumerated() {
                let pageRect = CGRect(origin: .zero, size: image.size)
                ctx.beginPage(withBounds: pageRect, pageInfo: [:])
                image.draw(in: pageRect)

                let boxes = pageIndex < ocrByPage.count ? ocrByPage[pageIndex] : []
                drawInvisibleText(boxes, in: pageRect)
            }
        }

        try data.write(to: destinationURL)

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
        document.thumbnailData = ThumbnailGenerator.persistableThumbnailData(at: destinationURL)
        context.insert(document)
        return document
    }

    /// Draws each OCR'd region as a clear-color string sized to its bounding
    /// box. The glyphs land in the PDF content stream (so PDFKit can find
    /// and select them) but render with zero alpha — visually undetectable.
    private static func drawInvisibleText(
        _ boxes: [OCRPipeline.RecognizedTextBox],
        in pageRect: CGRect
    ) {
        for box in boxes {
            // Vision: normalized [0,1], origin bottom-left in image space.
            // PDF context (UIKit-style): origin top-left, in points.
            let bbox = box.boundingBox
            let rect = CGRect(
                x: bbox.minX * pageRect.width,
                y: (1 - bbox.maxY) * pageRect.height,
                width: bbox.width * pageRect.width,
                height: bbox.height * pageRect.height
            )
            let fontSize = max(rect.height * 0.8, 6)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.clear,
            ]
            NSAttributedString(string: box.string, attributes: attributes).draw(in: rect)
        }
    }
}
