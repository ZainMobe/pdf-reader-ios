import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Turns one or more image files into a PDF without ever holding a
/// full-resolution bitmap for more than one page at a time.
///
/// Decoding goes through ImageIO's thumbnailing path so a 48 MP HEIC from
/// the camera roll is downsampled on the way in, EXIF orientation is baked
/// in, and memory stays flat regardless of how many pages are queued.
enum ImagesToPDF {
    /// Longest edge, in pixels, that any page image is allowed to keep.
    /// 2600 px is comfortably above what a 300 dpi A4 scan needs while
    /// keeping a 20-photo PDF under ~15 MB at 0.8 JPEG quality.
    static let maxPixelEdge: CGFloat = 2600

    enum PageSize: String, CaseIterable, Identifiable {
        /// Each page takes the image's own aspect ratio, sized so the
        /// longest edge is 792 pt (US Letter height). No borders.
        case fitImage
        case a4
        case usLetter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fitImage: "Fit to image"
            case .a4: "A4"
            case .usLetter: "US Letter"
            }
        }

        /// Portrait size in points. `fitImage` returns nil.
        var portraitSize: CGSize? {
            switch self {
            case .fitImage: nil
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .usLetter: CGSize(width: 612, height: 792)
            }
        }
    }

    struct Options {
        var pageSize: PageSize = .fitImage
        /// Margin inside fixed page sizes, in points. Ignored for `fitImage`.
        var margin: CGFloat = 24
        /// JPEG quality used when embedding. Lower = smaller file.
        var jpegQuality: CGFloat = 0.82
        /// When true, landscape images on a fixed page size rotate the page
        /// to landscape instead of shrinking to fit a portrait page.
        var autoRotatePages = true
    }

    enum ConversionError: LocalizedError {
        case noImages
        case unreadable(String)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noImages: "No images to convert."
            case .unreadable(let name): "\(name) couldn't be read as an image."
            case .writeFailed: "Couldn't write the PDF."
            }
        }
    }

    /// Converts `imageURLs` (in order) into a single PDF at `outputURL`.
    /// Unreadable files are skipped; the error is thrown only if *no* page
    /// could be produced. Returns the page count written.
    @discardableResult
    nonisolated static func write(
        imageURLs: [URL],
        to outputURL: URL,
        options: Options = Options()
    ) throws -> Int {
        guard !imageURLs.isEmpty else { throw ConversionError.noImages }

        // First pass: make sure at least one image decodes so we don't leave
        // a zero-page PDF on disk.
        var decodable: [URL] = []
        for url in imageURLs where canDecode(url) {
            decodable.append(url)
        }
        guard !decodable.isEmpty else {
            throw ConversionError.unreadable(imageURLs[0].lastPathComponent)
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "PDF Editor",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: options.pageSize.portraitSize ?? CGSize(width: 612, height: 792)),
            format: format
        )

        var pagesWritten = 0
        do {
            try renderer.writePDF(to: outputURL) { ctx in
                for url in decodable {
                    autoreleasepool {
                        guard let image = downsampledImage(at: url) else { return }
                        let (pageRect, drawRect) = layout(for: image.size, options: options)
                        ctx.beginPage(withBounds: pageRect, pageInfo: [:])
                        // Re-encode as JPEG so PDFKit embeds a DCT stream rather
                        // than raw RGBA; this is the difference between a 2 MB
                        // and a 40 MB PDF for a photo.
                        if let jpeg = image.jpegData(compressionQuality: options.jpegQuality),
                           let compact = UIImage(data: jpeg) {
                            compact.draw(in: drawRect)
                        } else {
                            image.draw(in: drawRect)
                        }
                        pagesWritten += 1
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversionError.writeFailed
        }

        if pagesWritten == 0 {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversionError.unreadable(decodable[0].lastPathComponent)
        }
        return pagesWritten
    }

    /// Same as `write(imageURLs:)` but for in-memory images (camera,
    /// clipboard). Images are still capped to `maxPixelEdge`.
    @discardableResult
    nonisolated static func write(
        images: [UIImage],
        to outputURL: URL,
        options: Options = Options()
    ) throws -> Int {
        guard !images.isEmpty else { throw ConversionError.noImages }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: options.pageSize.portraitSize ?? CGSize(width: 612, height: 792))
        )
        var pagesWritten = 0
        do {
            try renderer.writePDF(to: outputURL) { ctx in
                for original in images {
                    autoreleasepool {
                        let image = capped(original)
                        let (pageRect, drawRect) = layout(for: image.size, options: options)
                        ctx.beginPage(withBounds: pageRect, pageInfo: [:])
                        if let jpeg = image.jpegData(compressionQuality: options.jpegQuality),
                           let compact = UIImage(data: jpeg) {
                            compact.draw(in: drawRect)
                        } else {
                            image.draw(in: drawRect)
                        }
                        pagesWritten += 1
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversionError.writeFailed
        }
        return pagesWritten
    }

    // MARK: - Page-based API (Images to PDF tool)

    /// One source page: a file on disk plus a rotation in quarter turns
    /// (clockwise) and optional OCR boxes for an invisible text layer.
    struct Page {
        var url: URL
        var quarterTurns: Int = 0
        var ocrBoxes: [OCRPipeline.RecognizedTextBox]? = nil
    }

    /// Streams `pages` into a PDF, decoding one image at a time so memory
    /// stays flat for large batches. `progress` is called on the calling
    /// thread with the number of pages written so far.
    @discardableResult
    nonisolated static func write(
        pages: [Page],
        to outputURL: URL,
        options: Options = Options(),
        progress: ((Int) -> Void)? = nil
    ) throws -> Int {
        guard !pages.isEmpty else { throw ConversionError.noImages }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: options.pageSize.portraitSize ?? CGSize(width: 612, height: 792))
        )
        var pagesWritten = 0
        do {
            try renderer.writePDF(to: outputURL) { ctx in
                for page in pages {
                    autoreleasepool {
                        guard var image = downsampledImage(at: page.url) else { return }
                        if page.quarterTurns % 4 != 0 {
                            image = rotated(image, quarterTurns: page.quarterTurns)
                        }
                        let (pageRect, drawRect) = layout(for: image.size, options: options)
                        ctx.beginPage(withBounds: pageRect, pageInfo: [:])
                        if let jpeg = image.jpegData(compressionQuality: options.jpegQuality),
                           let compact = UIImage(data: jpeg) {
                            compact.draw(in: drawRect)
                        } else {
                            image.draw(in: drawRect)
                        }
                        if let boxes = page.ocrBoxes, !boxes.isEmpty {
                            drawInvisibleText(boxes, in: drawRect)
                        }
                        pagesWritten += 1
                        progress?(pagesWritten)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversionError.writeFailed
        }
        if pagesWritten == 0 {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversionError.unreadable(pages[0].url.lastPathComponent)
        }
        return pagesWritten
    }

    /// Decodes, rotates and caps a page image exactly as `write(pages:)`
    /// will, so OCR runs on the same pixels that end up in the PDF.
    nonisolated static func renderedImage(for page: Page) -> UIImage? {
        guard var image = downsampledImage(at: page.url) else { return nil }
        if page.quarterTurns % 4 != 0 {
            image = rotated(image, quarterTurns: page.quarterTurns)
        }
        return image
    }

    /// Rotates by 90 degree steps. Positive = clockwise.
    nonisolated static func rotated(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swap = turns % 2 == 1
        let size = swap ? CGSize(width: image.size.height, height: image.size.width) : image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: CGFloat(turns) * .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    /// Draws OCR regions as clear text inside `rect` (the area the image
    /// occupies on the page), so PDFKit search and selection work on photos
    /// exactly as they do on scans. Vision boxes are normalised with a
    /// bottom-left origin; the PDF context here is top-left.
    nonisolated static func drawInvisibleText(_ boxes: [OCRPipeline.RecognizedTextBox], in rect: CGRect) {
        for box in boxes {
            let b = box.boundingBox
            let r = CGRect(
                x: rect.minX + b.minX * rect.width,
                y: rect.minY + (1 - b.maxY) * rect.height,
                width: b.width * rect.width,
                height: b.height * rect.height
            )
            let fontSize = max(r.height * 0.8, 4)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.clear,
            ]
            NSAttributedString(string: box.string, attributes: attributes).draw(in: r)
        }
    }

    // MARK: - Layout

    /// Returns the page rect and the rect the image should be drawn into.
    nonisolated static func layout(for imageSize: CGSize, options: Options) -> (CGRect, CGRect) {
        guard imageSize.width > 0, imageSize.height > 0 else {
            let fallback = CGRect(x: 0, y: 0, width: 612, height: 792)
            return (fallback, fallback)
        }

        guard var page = options.pageSize.portraitSize else {
            // Fit to image: scale so the longest edge is 792 pt.
            let longest = max(imageSize.width, imageSize.height)
            let scale = 792 / longest
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let rect = CGRect(origin: .zero, size: size)
            return (rect, rect)
        }

        let imageIsLandscape = imageSize.width > imageSize.height
        if options.autoRotatePages, imageIsLandscape {
            page = CGSize(width: page.height, height: page.width)
        }

        let pageRect = CGRect(origin: .zero, size: page)
        let content = pageRect.insetBy(dx: options.margin, dy: options.margin)
        let scale = min(content.width / imageSize.width, content.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: content.midX - drawSize.width / 2,
            y: content.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        return (pageRect, drawRect)
    }

    // MARK: - Decoding

    nonisolated static func canDecode(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// Decodes with ImageIO's thumbnail path so oversized images never
    /// materialise at full resolution. Orientation is applied.
    nonisolated static func downsampledImage(at url: URL) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelEdge),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    nonisolated static func capped(_ image: UIImage) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > maxPixelEdge else { return image }
        let scale = maxPixelEdge / longest
        let target = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
