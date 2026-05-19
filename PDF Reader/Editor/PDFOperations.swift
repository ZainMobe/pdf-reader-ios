import Foundation
import PDFKit
import SwiftData
import UIKit

/// File-level PDF utilities used by the Tools tab. Each function writes a
/// new file into `DocumentStorage.pdfStorageDirectory` and inserts a fresh
/// `Document` record so results show up in the Library immediately.
enum PDFOperations {
    enum OpError: Error, LocalizedError {
        case writeFailed
        case noSourceDocument
        case sourceEncrypted
        case invalidPageCount
        case invalidSplitPoint

        var errorDescription: String? {
            switch self {
            case .writeFailed: "Couldn't save the resulting PDF."
            case .noSourceDocument: "Couldn't read the source document."
            case .sourceEncrypted: "The source PDF is encrypted. Open it and enter its password before running this tool."
            case .invalidPageCount: "Page count must be at least 1."
            case .invalidSplitPoint: "Pick a split point inside the document."
            }
        }
    }

    /// Throws `sourceEncrypted` when a tool tries to operate on a locked PDF.
    /// All file-level operations call this right after `PDFDocument(url:)`.
    private static func ensureUnlocked(_ pdf: PDFDocument) throws {
        if pdf.isLocked { throw OpError.sourceEncrypted }
    }

    enum CompressionQuality: String, CaseIterable, Identifiable {
        case low, medium, high

        var id: Self { self }
        var displayName: String {
            switch self {
            case .low: "Smallest"
            case .medium: "Balanced"
            case .high: "High Quality"
            }
        }
        var subtitle: String {
            switch self {
            case .low: "72 DPI · best for sharing"
            case .medium: "150 DPI · best for screens"
            case .high: "200 DPI · best for print"
            }
        }
        var dpi: CGFloat {
            switch self {
            case .low: 72
            case .medium: 150
            case .high: 200
            }
        }
        var jpegQuality: CGFloat {
            switch self {
            case .low: 0.5
            case .medium: 0.7
            case .high: 0.85
            }
        }
    }

    enum PageSize: String, CaseIterable, Identifiable {
        case letter, a4, legal

        var id: Self { self }
        var displayName: String {
            switch self {
            case .letter: "US Letter"
            case .a4: "A4"
            case .legal: "US Legal"
            }
        }
        /// Dimensions in PDF points (72 DPI).
        var size: CGSize {
            switch self {
            case .letter: CGSize(width: 612, height: 792)
            case .a4: CGSize(width: 595, height: 842)
            case .legal: CGSize(width: 612, height: 1008)
            }
        }
    }

    @discardableResult
    static func createBlank(
        pageCount: Int,
        pageSize: PageSize,
        title: String,
        in context: ModelContext
    ) throws -> Document {
        guard pageCount > 0 else { throw OpError.invalidPageCount }

        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let url = DocumentStorage.pdfStorageDirectory.appending(path: filename)
        let bounds = CGRect(origin: .zero, size: pageSize.size)

        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for _ in 0..<pageCount {
                ctx.beginPage(withBounds: bounds, pageInfo: [:])
                UIColor.white.setFill()
                UIBezierPath(rect: bounds).fill()
            }
        }
        try data.write(to: url)

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

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

    @discardableResult
    static func merge(
        _ documents: [Document],
        title: String,
        in context: ModelContext
    ) throws -> Document {
        guard !documents.isEmpty else { throw OpError.noSourceDocument }

        let merged = PDFDocument()
        var insertIndex = 0
        for doc in documents {
            guard let pdf = PDFDocument(url: doc.fileURL) else { continue }
            if pdf.isLocked { throw OpError.sourceEncrypted }
            for pageIndex in 0..<pdf.pageCount {
                guard
                    let page = pdf.page(at: pageIndex),
                    let copy = page.copy() as? PDFPage
                else { continue }
                merged.insert(copy, at: insertIndex)
                insertIndex += 1
            }
        }

        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let url = DocumentStorage.pdfStorageDirectory.appending(path: filename)
        guard merged.write(to: url) else { throw OpError.writeFailed }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let document = Document(
            id: id,
            title: title,
            filename: filename,
            fileSize: fileSize,
            pageCount: merged.pageCount
        )
        context.insert(document)
        return document
    }

    /// Rasterizes each page at the chosen DPI and re-encodes through JPEG
    /// to drastically reduce file size. Trade-off: selectable text,
    /// annotations, and form fields are flattened.
    @discardableResult
    static func compress(
        _ source: Document,
        quality: CompressionQuality,
        in context: ModelContext
    ) throws -> Document {
        guard
            let pdf = PDFDocument(url: source.fileURL),
            let firstPage = pdf.page(at: 0)
        else {
            throw OpError.noSourceDocument
        }
        try ensureUnlocked(pdf)

        let bounds = firstPage.bounds(for: .mediaBox)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let totalPages = pdf.pageCount
        let scale = quality.dpi / 72.0

        let data = renderer.pdfData { ctx in
            for index in 0..<totalPages {
                guard let page = pdf.page(at: index) else { continue }
                let pageBounds = page.bounds(for: .mediaBox)
                ctx.beginPage(withBounds: pageBounds, pageInfo: [:])

                let imageSize = CGSize(
                    width: pageBounds.width * scale,
                    height: pageBounds.height * scale
                )
                let imageRenderer = UIGraphicsImageRenderer(size: imageSize)
                let pageImage = imageRenderer.image { imgCtx in
                    let cg = imgCtx.cgContext
                    cg.setFillColor(UIColor.white.cgColor)
                    cg.fill(CGRect(origin: .zero, size: imageSize))
                    cg.translateBy(x: 0, y: imageSize.height)
                    cg.scaleBy(x: scale, y: -scale)
                    page.draw(with: .mediaBox, to: cg)
                }

                // Re-encode through JPEG so the embedded image is the
                // compressed form rather than raw pixels.
                if let jpegData = pageImage.jpegData(compressionQuality: quality.jpegQuality),
                   let jpegImage = UIImage(data: jpegData) {
                    jpegImage.draw(in: pageBounds)
                } else {
                    pageImage.draw(in: pageBounds)
                }
            }
        }

        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let url = DocumentStorage.pdfStorageDirectory.appending(path: filename)
        try data.write(to: url)

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let document = Document(
            id: id,
            title: "\(source.title) (Compressed)",
            filename: filename,
            fileSize: fileSize,
            pageCount: totalPages
        )
        context.insert(document)
        return document
    }

    /// Adds a diagonal text watermark to every page. Pages are re-rendered
    /// into a fresh PDF — original annotations and form fields are flattened.
    @discardableResult
    static func watermark(
        _ source: Document,
        text: String,
        opacity: CGFloat,
        in context: ModelContext
    ) throws -> Document {
        try renderOverlay(source: source, titleSuffix: "(Watermarked)", in: context) { pageRect, _, _ in
            drawWatermark(text: text, opacity: opacity, in: pageRect)
        }
    }

    /// Adds a "N / Total" page number to the bottom-right of each page.
    @discardableResult
    static func addPageNumbers(
        _ source: Document,
        in context: ModelContext
    ) throws -> Document {
        try renderOverlay(source: source, titleSuffix: "(Numbered)", in: context) { pageRect, index, total in
            drawPageNumber(current: index + 1, total: total, in: pageRect)
        }
    }

    /// Shared helper that re-renders each page into a new PDF and invokes
    /// `drawOverlay` on top, after restoring UIKit-style coordinates.
    private static func renderOverlay(
        source: Document,
        titleSuffix: String,
        in context: ModelContext,
        drawOverlay: (_ pageRect: CGRect, _ pageIndex: Int, _ totalPages: Int) -> Void
    ) throws -> Document {
        guard
            let pdf = PDFDocument(url: source.fileURL),
            let firstPage = pdf.page(at: 0)
        else {
            throw OpError.noSourceDocument
        }
        try ensureUnlocked(pdf)

        let bounds = firstPage.bounds(for: .mediaBox)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let totalPages = pdf.pageCount

        let data = renderer.pdfData { ctx in
            for index in 0..<totalPages {
                guard let page = pdf.page(at: index) else { continue }
                let pageBounds = page.bounds(for: .mediaBox)
                ctx.beginPage(withBounds: pageBounds, pageInfo: [:])

                let cgContext = ctx.cgContext
                // Draw the source page. PDF coordinates are bottom-up;
                // UIGraphicsPDFRenderer's context is top-down. Flip
                // temporarily so the page renders the right way up.
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: pageBounds.height)
                cgContext.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: cgContext)
                cgContext.restoreGState()

                drawOverlay(pageBounds, index, totalPages)
            }
        }

        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let url = DocumentStorage.pdfStorageDirectory.appending(path: filename)
        try data.write(to: url)

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let document = Document(
            id: id,
            title: "\(source.title) \(titleSuffix)",
            filename: filename,
            fileSize: fileSize,
            pageCount: totalPages
        )
        context.insert(document)
        return document
    }

    private static func drawWatermark(text: String, opacity: CGFloat, in pageRect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let fontSize = max(min(pageRect.width, pageRect.height) * 0.12, 24)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: UIColor.systemGray.withAlphaComponent(opacity),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()

        context.saveGState()
        context.translateBy(x: pageRect.midX, y: pageRect.midY)
        context.rotate(by: -.pi / 4)
        attributed.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        context.restoreGState()
    }

    private static func drawPageNumber(current: Int, total: Int, in pageRect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.label.withAlphaComponent(0.7),
        ]
        let attributed = NSAttributedString(string: "\(current) / \(total)", attributes: attributes)
        let size = attributed.size()
        let margin: CGFloat = 24
        attributed.draw(at: CGPoint(
            x: pageRect.maxX - size.width - margin,
            y: pageRect.maxY - size.height - margin
        ))
    }

    @discardableResult
    static func split(
        _ source: Document,
        atPage splitAfter: Int,
        in context: ModelContext
    ) throws -> (firstPart: Document, secondPart: Document) {
        guard let pdf = PDFDocument(url: source.fileURL) else { throw OpError.noSourceDocument }
        try ensureUnlocked(pdf)
        guard splitAfter > 0, splitAfter < pdf.pageCount else { throw OpError.invalidSplitPoint }

        let firstPart = PDFDocument()
        for index in 0..<splitAfter {
            guard
                let page = pdf.page(at: index),
                let copy = page.copy() as? PDFPage
            else { continue }
            firstPart.insert(copy, at: index)
        }

        let secondPart = PDFDocument()
        for index in splitAfter..<pdf.pageCount {
            guard
                let page = pdf.page(at: index),
                let copy = page.copy() as? PDFPage
            else { continue }
            secondPart.insert(copy, at: index - splitAfter)
        }

        let firstID = UUID()
        let firstFilename = "\(firstID.uuidString).pdf"
        let firstURL = DocumentStorage.pdfStorageDirectory.appending(path: firstFilename)
        guard firstPart.write(to: firstURL) else { throw OpError.writeFailed }

        let secondID = UUID()
        let secondFilename = "\(secondID.uuidString).pdf"
        let secondURL = DocumentStorage.pdfStorageDirectory.appending(path: secondFilename)
        guard secondPart.write(to: secondURL) else { throw OpError.writeFailed }

        let firstSize = (try? FileManager.default
            .attributesOfItem(atPath: firstURL.path)[.size] as? Int64) ?? 0
        let secondSize = (try? FileManager.default
            .attributesOfItem(atPath: secondURL.path)[.size] as? Int64) ?? 0

        let firstDoc = Document(
            id: firstID,
            title: "\(source.title) (Part 1)",
            filename: firstFilename,
            fileSize: firstSize,
            pageCount: firstPart.pageCount
        )
        let secondDoc = Document(
            id: secondID,
            title: "\(source.title) (Part 2)",
            filename: secondFilename,
            fileSize: secondSize,
            pageCount: secondPart.pageCount
        )
        context.insert(firstDoc)
        context.insert(secondDoc)
        return (firstDoc, secondDoc)
    }
}
