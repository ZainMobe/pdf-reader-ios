import Foundation
import PDFKit
import UIKit

/// True redaction for PDFKit on iOS.
///
/// PDFKit can draw a black box over text, but the glyphs stay in the content
/// stream and can be copied straight back out. This type does what Preview
/// on the Mac does: every page that carries redaction marks is re-rendered
/// with the marked regions burned in, the original content stream is
/// discarded, and the text that was *outside* the marks is written back as
/// an invisible layer so the page stays searchable and selectable.
///
/// Two phases:
/// 1. Marking. `mark(...)` adds pending marks (annotations the user can still
///    undo). They render as translucent black with a red outline so it's
///    obvious nothing has been removed yet.
/// 2. Applying. `apply(to:)` rasterises marked pages, replaces them, and
///    removes the marks. Irreversible by design.
enum PDFRedactor {
    /// Identifies our pending marks among a page's annotations.
    static let markerUserName = "PDFEditor.Redaction"

    /// Render density for the replacement page image.
    static let renderDPI: CGFloat = 220
    /// Longest edge cap so a poster-sized page can't allocate a huge bitmap.
    static let maxRenderEdge: CGFloat = 4800

    // MARK: - Marking

    /// Adds one pending redaction mark covering `bounds` on `page`.
    @discardableResult
    static func mark(_ bounds: CGRect, on page: PDFPage) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds.insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
        annotation.userName = markerUserName
        annotation.contents = "Pending redaction"
        annotation.color = .systemRed
        annotation.interiorColor = UIColor.black.withAlphaComponent(0.55)
        let border = PDFBorder()
        border.lineWidth = 1.5
        annotation.border = border
        page.addAnnotation(annotation)
        return annotation
    }

    /// Marks every line of a text selection.
    static func mark(selection: PDFSelection) -> [PDFAnnotation] {
        var added: [PDFAnnotation] = []
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
            added.append(mark(bounds, on: page))
        }
        return added
    }

    /// Marks every occurrence of `text` in the document. Returns the marks
    /// and the number of pages touched.
    static func markOccurrences(of text: String, in document: PDFDocument, caseSensitive: Bool = false) -> (marks: [PDFAnnotation], pages: Int) {
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let matches = document.findString(text, withOptions: options)
        var added: [PDFAnnotation] = []
        var pages = Set<Int>()
        for match in matches {
            let marks = mark(selection: match)
            added.append(contentsOf: marks)
            for page in match.pages {
                pages.insert(document.index(for: page))
            }
        }
        return (added, pages.count)
    }

    static func isMark(_ annotation: PDFAnnotation) -> Bool {
        if annotation.userName == markerUserName { return true }
        // Marks from the earlier "visual redaction" (opaque black squares)
        // are promoted so applying removes their content too.
        if annotation.type == "Square",
           let interior = annotation.interiorColor,
           interior.isBlackish, annotation.color.isBlackish {
            return true
        }
        return false
    }

    /// Pending marks per page index.
    static func pendingMarks(in document: PDFDocument) -> [Int: [PDFAnnotation]] {
        var result: [Int: [PDFAnnotation]] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let marks = page.annotations.filter(isMark)
            if !marks.isEmpty { result[index] = marks }
        }
        return result
    }

    static func pendingCount(in document: PDFDocument) -> Int {
        pendingMarks(in: document).values.reduce(0) { $0 + $1.count }
    }

    static func removeAllMarks(in document: PDFDocument) {
        for (index, marks) in pendingMarks(in: document) {
            guard let page = document.page(at: index) else { continue }
            for mark in marks { page.removeAnnotation(mark) }
        }
    }

    // MARK: - Applying

    struct Result {
        var pagesRedacted: Int
        var marksApplied: Int
    }

    enum RedactionError: LocalizedError {
        case locked
        case nothingToApply
        case renderFailed(Int)

        var errorDescription: String? {
            switch self {
            case .locked: "Unlock the document before redacting."
            case .nothingToApply: "There are no redaction marks to apply."
            case .renderFailed(let page): "Page \(page + 1) couldn't be redacted."
            }
        }
    }

    /// Burns in every pending mark. Mutates `document` in place; the caller
    /// is responsible for writing it to disk. Safe to call off the main
    /// thread as long as no PDFView is displaying `document` concurrently
    /// (callers detach the view or work on a fresh PDFDocument instance).
    static func apply(to document: PDFDocument) throws -> Result {
        if document.isLocked { throw RedactionError.locked }
        let pending = pendingMarks(in: document)
        guard !pending.isEmpty else { throw RedactionError.nothingToApply }

        var marksApplied = 0
        for index in pending.keys.sorted() {
            guard let page = document.page(at: index), let marks = pending[index] else { continue }
            let replacement = try redactedCopy(of: page, marks: marks, pageIndex: index)
            document.removePage(at: index)
            document.insert(replacement, at: index)
            marksApplied += marks.count
        }
        return Result(pagesRedacted: pending.count, marksApplied: marksApplied)
    }

    /// Builds the flattened replacement page.
    private static func redactedCopy(of page: PDFPage, marks: [PDFAnnotation], pageIndex: Int) throws -> PDFPage {
        let redactRects = marks.map(\.bounds)

        // 1. Collect glyphs outside the marks (page space) before anything
        //    changes, so the invisible layer reflects the original text.
        let keptGlyphs = survivingGlyphs(on: page, excluding: redactRects)

        // 2. Detach ordinary annotations so they aren't burned into the
        //    bitmap; widgets (form fields) stay and get flattened, because a
        //    re-added widget would lose its AcroForm link anyway.
        let detached = page.annotations.filter { !isMark($0) && $0.type != "Widget" && $0.type != "Link" }
        for annotation in detached { page.removeAnnotation(annotation) }

        // 3. Turn the marks opaque so PDFKit paints solid black, with all the
        //    page rotation handling done for us by `thumbnail(of:for:)`.
        for mark in marks {
            mark.color = .black
            mark.interiorColor = .black
            mark.border = nil
        }

        // 4. Rasterise. `bounds(for: .mediaBox)` with the page rotation
        //    applied gives the visual size; thumbnail(of:) honours rotation.
        let rotation = ((page.rotation % 360) + 360) % 360
        let raw = page.bounds(for: .mediaBox)
        let visualSize = (rotation == 90 || rotation == 270)
            ? CGSize(width: raw.height, height: raw.width)
            : raw.size
        var scale = renderDPI / 72
        let longest = max(visualSize.width, visualSize.height) * scale
        if longest > maxRenderEdge { scale *= maxRenderEdge / longest }
        let pixelSize = CGSize(width: visualSize.width * scale, height: visualSize.height * scale)
        let image = page.thumbnail(of: pixelSize, for: .mediaBox)

        // Put the page back the way it was in case the write later fails.
        for annotation in detached { page.addAnnotation(annotation) }

        guard image.size.width > 1, image.size.height > 1 else {
            throw RedactionError.renderFailed(pageIndex)
        }

        // 5. Compose the new page: image at the original point size plus the
        //    invisible text layer. Going through UIGraphicsPDFRenderer keeps
        //    the page exactly `visualSize` points instead of PDFPage(image:)'s
        //    one-point-per-pixel sizing.
        let pageRect = CGRect(origin: .zero, size: visualSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let transform = page.transform(for: .mediaBox)
        let data = renderer.pdfData { ctx in
            ctx.beginPage(withBounds: pageRect, pageInfo: [:])
            if let jpeg = image.jpegData(compressionQuality: 0.85), let compact = UIImage(data: jpeg) {
                compact.draw(in: pageRect)
            } else {
                image.draw(in: pageRect)
            }
            for glyph in keptGlyphs {
                // Page space (PDF, bottom-left) -> rotated display space -> UIKit top-left.
                let display = glyph.bounds.applying(transform)
                let flipped = CGRect(
                    x: display.minX,
                    y: visualSize.height - display.maxY,
                    width: display.width,
                    height: display.height
                )
                guard flipped.width > 0, flipped.height > 0 else { continue }
                let fontSize = max(flipped.height * 0.85, 3)
                NSAttributedString(string: glyph.text, attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize),
                    .foregroundColor: UIColor.clear,
                ]).draw(in: flipped)
            }
        }

        guard let newDocument = PDFDocument(data: data), let newPage = newDocument.page(at: 0) else {
            throw RedactionError.renderFailed(pageIndex)
        }

        // 6. Restore the user's other annotations on the new page. Bounds are
        //    in page space; the new page has rotation 0 and display-space
        //    geometry, so map them through the same transform.
        for annotation in detached {
            annotation.bounds = annotation.bounds.applying(transform)
            newPage.addAnnotation(annotation)
        }
        return newPage
    }

    struct Glyph {
        var text: String
        var bounds: CGRect
    }

    /// Groups consecutive characters that don't intersect any redaction
    /// rect into short runs (same line, adjacent), so the invisible layer
    /// has word-level runs rather than thousands of single characters.
    private static func survivingGlyphs(on page: PDFPage, excluding rects: [CGRect]) -> [Glyph] {
        guard let text = page.string, !text.isEmpty else { return [] }
        let count = page.numberOfCharacters
        guard count > 0 else { return [] }
        let chars = Array(text)
        var result: [Glyph] = []
        var runText = ""
        var runBounds = CGRect.null

        func flush() {
            if !runText.trimmingCharacters(in: .whitespaces).isEmpty, !runBounds.isNull {
                result.append(Glyph(text: runText, bounds: runBounds))
            }
            runText = ""
            runBounds = .null
        }

        for i in 0..<min(count, chars.count) {
            let ch = chars[i]
            if ch == "\n" || ch == "\r" { flush(); continue }
            let bounds = page.characterBounds(at: i)
            guard bounds.width > 0, bounds.height > 0 else { flush(); continue }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if rects.contains(where: { $0.contains(center) || $0.intersects(bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25)) }) {
                flush()
                continue
            }
            // New run when the baseline jumps or there's a horizontal gap
            // larger than a character.
            if !runBounds.isNull {
                let sameLine = abs(bounds.midY - runBounds.midY) < runBounds.height * 0.5
                let adjacent = abs(bounds.minX - runBounds.maxX) < bounds.width * 1.5
                if !sameLine || !adjacent { flush() }
            }
            runText.append(ch)
            runBounds = runBounds.isNull ? bounds : runBounds.union(bounds)
        }
        flush()
        return result
    }
}

private extension UIColor {
    var isBlackish: Bool {
        var white: CGFloat = 1, alpha: CGFloat = 1
        if getWhite(&white, alpha: &alpha) { return white < 0.15 && alpha > 0.5 }
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1
        if getRed(&r, green: &g, blue: &b, alpha: &alpha) { return r < 0.15 && g < 0.15 && b < 0.15 && alpha > 0.5 }
        return false
    }
}
