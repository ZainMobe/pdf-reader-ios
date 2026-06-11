import Foundation
import FoundationModels
import OSLog
import PDFKit
import SwiftData
import UIKit

/// Console.app filter: `subsystem:com.pdfreader.ai category:Translator`
nonisolated private let translatorLog = Logger(subsystem: "com.pdfreader.ai", category: "Translator")

/// Translates a `Document` and produces a new PDF that mirrors the original's
/// visual layout — images, tables, page structure are preserved by drawing
/// the source page as the background; original text is masked with white and
/// the translated text is drawn into the exact same line bounding boxes.
///
/// Translation is done page-by-page using `PDFPage.selectionsByLine()` to
/// recover each line's text + bbox. Each page's lines are translated in a
/// single batch through a fresh `LanguageModelSession` (with a delimiter the
/// model is asked to preserve) so the count of input lines matches the
/// output. If counts diverge, the implementation falls back to per-line
/// translation for that page.
@MainActor
@Observable
final class DocumentTranslator {
    enum State: Equatable {
        case idle
        case extracting
        case translating(progress: Double, currentPage: Int, totalPages: Int)
        case rendering
        case ready(translatedURL: URL, pageCount: Int)
        case failed(String)
    }

    /// Per-batch character cap. Translation output often expands ~30% from the
    /// source, so this is conservative against the 4,096-token context window.
    private static let perCallCharBudget = 2_400

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var pendingURL: URL?

    func translate(_ document: Document, to language: TranslationLanguage) {
        cancelCurrent()
        state = .extracting

        let sourceURL = document.fileURL
        let runID = String(UUID().uuidString.prefix(8))
        translatorLog.notice("[\(runID, privacy: .public)] translate start: doc=\(document.title, privacy: .public) size=\(document.fileSize) language=\(language.displayName, privacy: .public)")

        guard let pdf = PDFDocument(url: sourceURL) else {
            translatorLog.error("[\(runID, privacy: .public)] PDFDocument(url:) returned nil for \(sourceURL.lastPathComponent, privacy: .public)")
            state = .failed("Couldn't read the source PDF.")
            return
        }
        guard !pdf.isLocked else {
            translatorLog.error("[\(runID, privacy: .public)] source PDF is locked")
            state = .failed("Couldn't read the source PDF (locked).")
            return
        }
        guard pdf.pageCount > 0 else {
            translatorLog.error("[\(runID, privacy: .public)] source PDF has 0 pages")
            state = .failed("This document has no pages.")
            return
        }
        let pageCount = pdf.pageCount
        translatorLog.notice("[\(runID, privacy: .public)] source PDF: pageCount=\(pageCount)")

        let languageName = language.displayName
        let isRTL = language.isRTL
        let tempURL = DocumentStorage.pdfStorageDirectory
            .appending(path: "translation-\(UUID().uuidString).pdf")

        task = Task { [weak self] in
            guard let self else { return }

            // 1. Extract line-level text + bbox from every page.
            translatorLog.notice("[\(runID, privacy: .public)] extraction phase begin")
            let extractStart = Date()
            let allPageLines: [[LineInfo]] = await Task.detached(priority: .userInitiated) {
                Self.extractAllPageLines(from: sourceURL, pageCount: pageCount, runID: runID)
            }.value
            let totalLines = allPageLines.reduce(0) { $0 + $1.count }
            let totalChars = allPageLines.reduce(0) { acc, page in
                acc + page.reduce(0) { $0 + $1.text.count }
            }
            translatorLog.notice("[\(runID, privacy: .public)] extraction phase done in \(Self.elapsed(extractStart))ms — pages=\(allPageLines.count) lines=\(totalLines) chars=\(totalChars)")

            if totalLines == 0 {
                translatorLog.error("[\(runID, privacy: .public)] no extractable text found in any page")
                self.state = .failed("This document has no extractable text. Try a PDF with selectable text.")
                return
            }

            if Task.isCancelled { return }
            self.state = .translating(progress: 0, currentPage: 0, totalPages: pageCount)

            // 2. Translate each page's lines in a batch.
            var translatedPages: [[TranslatedSegment]] = []
            for (pageIndex, lines) in allPageLines.enumerated() {
                if Task.isCancelled {
                    translatorLog.notice("[\(runID, privacy: .public)] cancelled at page \(pageIndex + 1)")
                    return
                }

                let pageStart = Date()
                let texts = lines.map { $0.text }
                let pageChars = texts.reduce(0) { $0 + $1.count }
                translatorLog.notice("[\(runID, privacy: .public)] page \(pageIndex + 1)/\(pageCount): lines=\(texts.count) chars=\(pageChars)")

                let translated: [String]
                do {
                    translated = try await Self.translateLines(texts, languageName: languageName, runID: runID, pageIndex: pageIndex + 1)
                } catch is CancellationError {
                    translatorLog.notice("[\(runID, privacy: .public)] cancellation thrown during page \(pageIndex + 1)")
                    return
                } catch {
                    if Task.isCancelled { return }
                    translatorLog.error("[\(runID, privacy: .public)] page \(pageIndex + 1) translation FAILED: \(String(describing: error), privacy: .public)")
                    self.state = .failed(Self.message(for: error))
                    return
                }
                translatorLog.notice("[\(runID, privacy: .public)] page \(pageIndex + 1) translated in \(Self.elapsed(pageStart))ms — got \(translated.count) segments")

                // Pair each original bbox with its translation, falling back
                // to the original text when translation came back empty.
                var segments: [TranslatedSegment] = []
                for (idx, line) in lines.enumerated() {
                    let text = idx < translated.count ? translated[idx] : line.text
                    let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? line.text
                        : text
                    segments.append(TranslatedSegment(bbox: line.bbox, text: finalText))
                }
                translatedPages.append(segments)

                let progress = Double(pageIndex + 1) / Double(pageCount)
                self.state = .translating(
                    progress: progress,
                    currentPage: pageIndex + 1,
                    totalPages: pageCount
                )
            }

            if Task.isCancelled { return }
            self.state = .rendering
            translatorLog.notice("[\(runID, privacy: .public)] render phase begin → \(tempURL.lastPathComponent, privacy: .public)")

            // 3. Render the translated PDF using the source layout as background.
            let renderStart = Date()
            let render = await Task.detached(priority: .userInitiated) {
                Self.renderPDF(
                    sourceURL: sourceURL,
                    translatedPages: translatedPages,
                    isRTL: isRTL,
                    destinationURL: tempURL,
                    runID: runID
                )
            }.value

            if Task.isCancelled {
                translatorLog.notice("[\(runID, privacy: .public)] cancelled during render")
                if let url = render?.url { try? FileManager.default.removeItem(at: url) }
                return
            }
            guard let render else {
                translatorLog.error("[\(runID, privacy: .public)] renderPDF returned nil")
                self.state = .failed("Couldn't render the translated PDF.")
                return
            }
            translatorLog.notice("[\(runID, privacy: .public)] render phase done in \(Self.elapsed(renderStart))ms — pageCount=\(render.pageCount)")

            self.pendingURL = render.url
            self.state = .ready(translatedURL: render.url, pageCount: render.pageCount)
            translatorLog.notice("[\(runID, privacy: .public)] translate complete")
        }
    }

    nonisolated private static func elapsed(_ from: Date) -> Int {
        Int(Date().timeIntervalSince(from) * 1000)
    }

    @discardableResult
    func saveToLibrary(
        sourceDocument: Document,
        language: TranslationLanguage,
        in context: ModelContext
    ) -> Document? {
        guard case .ready(let url, let pageCount) = state else { return nil }
        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let destination = DocumentStorage.pdfStorageDirectory.appending(path: filename)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            try? FileManager.default.copyItem(at: url, to: destination)
            try? FileManager.default.removeItem(at: url)
        }
        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        let document = Document(
            id: id,
            title: "\(sourceDocument.title) (\(language.displayName))",
            filename: filename,
            fileSize: fileSize,
            pageCount: pageCount
        )
        if let pdf = PDFDocument(url: destination), let body = pdf.string {
            document.ocrText = body
        }
        context.insert(document)
        pendingURL = nil
        state = .idle
        return document
    }

    func discard() {
        if let url = pendingURL {
            try? FileManager.default.removeItem(at: url)
            pendingURL = nil
        }
        state = .idle
    }

    func cancel() {
        cancelCurrent()
        discard()
    }

    private func cancelCurrent() {
        task?.cancel()
        task = nil
        if let url = pendingURL {
            try? FileManager.default.removeItem(at: url)
            pendingURL = nil
        }
    }

    // MARK: - Extraction

    private struct LineInfo {
        let text: String
        let bbox: CGRect
    }

    private struct TranslatedSegment {
        let bbox: CGRect
        let text: String
    }

    nonisolated private static func extractAllPageLines(
        from sourceURL: URL,
        pageCount: Int,
        runID: String
    ) -> [[LineInfo]] {
        guard let pdf = PDFDocument(url: sourceURL) else {
            translatorLog.error("[\(runID, privacy: .public)] extractAllPageLines: PDFDocument init failed")
            return []
        }
        var result: [[LineInfo]] = []
        for i in 0..<pageCount {
            guard let page = pdf.page(at: i) else {
                translatorLog.error("[\(runID, privacy: .public)] page \(i + 1): pdf.page(at:) returned nil")
                result.append([])
                continue
            }
            // `selectionsByLine()` lives on `PDFSelection`, so first ask the
            // page for a selection covering its full media box, then break
            // that into per-line selections.
            let pageBounds = page.bounds(for: .mediaBox)
            guard let pageSelection = page.selection(for: pageBounds) else {
                translatorLog.notice("[\(runID, privacy: .public)] page \(i + 1): page.selection(for:) returned nil — likely no selectable text")
                result.append([])
                continue
            }
            let perLine = pageSelection.selectionsByLine()
            var lines: [LineInfo] = []
            var skipped = 0
            for selection in perLine {
                guard let raw = selection.string else { skipped += 1; continue }
                let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !trimmed.isEmpty else { skipped += 1; continue }
                let bbox = selection.bounds(for: page)
                guard bbox.width > 0, bbox.height > 0 else { skipped += 1; continue }
                lines.append(LineInfo(text: trimmed, bbox: bbox))
            }
            translatorLog.debug("[\(runID, privacy: .public)] page \(i + 1): selections=\(perLine.count) kept=\(lines.count) skipped=\(skipped)")
            result.append(lines)
        }
        return result
    }

    // MARK: - Translation

    /// Marker we ask the model to keep intact between source segments. The
    /// pipe-on-its-own-line shape is rare enough in prose to survive most
    /// translations.
    private static let lineSeparator = "\n|||\n"

    /// Translates all `lines` for a page, batching them within
    /// `perCallCharBudget` and falling back to per-line on count mismatch.
    private static func translateLines(
        _ lines: [String],
        languageName: String,
        runID: String,
        pageIndex: Int
    ) async throws -> [String] {
        guard !lines.isEmpty else { return [] }

        var batches: [[String]] = []
        var currentBatch: [String] = []
        var currentSize = 0
        for line in lines {
            let cost = line.count + lineSeparator.count
            if currentSize + cost > perCallCharBudget, !currentBatch.isEmpty {
                batches.append(currentBatch)
                currentBatch = []
                currentSize = 0
            }
            currentBatch.append(line)
            currentSize += cost
        }
        if !currentBatch.isEmpty { batches.append(currentBatch) }
        translatorLog.debug("[\(runID, privacy: .public)] page \(pageIndex): split into \(batches.count) batch(es)")

        var result: [String] = []
        for (batchIndex, batch) in batches.enumerated() {
            if Task.isCancelled { return result }
            let translated = try await translateBatch(
                lines: batch,
                languageName: languageName,
                runID: runID,
                pageIndex: pageIndex,
                batchIndex: batchIndex + 1,
                batchTotal: batches.count
            )
            result.append(contentsOf: translated)
        }
        return result
    }

    private static func translateBatch(
        lines: [String],
        languageName: String,
        runID: String,
        pageIndex: Int,
        batchIndex: Int,
        batchTotal: Int
    ) async throws -> [String] {
        let tag = "[\(runID)] page \(pageIndex) batch \(batchIndex)/\(batchTotal)"
        let batchChars = lines.reduce(0) { $0 + $1.count }

        if lines.count == 1 {
            translatorLog.debug("\(tag, privacy: .public): single-line path (chars=\(batchChars))")
            let started = Date()
            do {
                let translated = try await translateSingleLine(
                    lines[0],
                    languageName: languageName,
                    runID: runID,
                    label: "\(tag) (single)"
                )
                translatorLog.debug("\(tag, privacy: .public): single-line success in \(Self.elapsed(started))ms")
                return [translated]
            } catch {
                translatorLog.error("\(tag, privacy: .public): single-line FAILED: \(String(describing: error), privacy: .public)")
                throw error
            }
        }

        let joined = lines.joined(separator: lineSeparator)
        translatorLog.debug("\(tag, privacy: .public): batched (lines=\(lines.count) chars=\(batchChars) prompt=\(joined.count))")

        let instructions = Instructions("""
            Translate each segment of text into \(languageName). The segments are \
            separated by the marker "|||" on its own line. Output the translations \
            in the same order, separated by the same "|||" marker on its own line. \
            Reply with only the translations — no commentary, no labels, no extra \
            text. Keep proper nouns, IDs, codes, dates, and numbers unchanged.
            """)
        let session = LanguageModelSession(instructions: instructions)

        let started = Date()
        let response: LanguageModelSession.Response<String>
        do {
            response = try await session.respond(to: Prompt(joined))
        } catch {
            translatorLog.error("\(tag, privacy: .public): batched call FAILED in \(Self.elapsed(started))ms: \(String(describing: error), privacy: .public)")
            throw error
        }
        translatorLog.debug("\(tag, privacy: .public): batched call done in \(Self.elapsed(started))ms (responseChars=\(response.content.count))")

        let parts = response.content
            .components(separatedBy: lineSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if parts.count == lines.count {
            return parts
        }

        // Mismatch — fall back to per-line translation.
        translatorLog.notice("\(tag, privacy: .public): delimiter mismatch (sent=\(lines.count) got=\(parts.count)) → per-line fallback")
        var fallback: [String] = []
        for (idx, line) in lines.enumerated() {
            if Task.isCancelled { return fallback }
            do {
                let translated = try await translateSingleLine(
                    line,
                    languageName: languageName,
                    runID: runID,
                    label: "\(tag) fallback \(idx + 1)/\(lines.count)"
                )
                fallback.append(translated)
            } catch {
                translatorLog.error("\(tag, privacy: .public) fallback line \(idx + 1) FAILED: \(String(describing: error), privacy: .public) — keeping original")
                fallback.append(line)
            }
        }
        return fallback
    }

    private static func translateSingleLine(
        _ line: String,
        languageName: String,
        runID: String,
        label: String
    ) async throws -> String {
        let instructions = Instructions("""
            Translate the user's text into \(languageName). Reply with only the \
            translation — no commentary, no labels. Keep proper nouns, codes, IDs, \
            dates, and numbers unchanged.
            """)
        let session = LanguageModelSession(instructions: instructions)
        let started = Date()
        do {
            let response = try await session.respond(to: Prompt(line))
            translatorLog.debug("\(label, privacy: .public): ok in \(Self.elapsed(started))ms (in=\(line.count) out=\(response.content.count))")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            translatorLog.error("\(label, privacy: .public): FAILED in \(Self.elapsed(started))ms: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        if let gen = error as? LanguageModelSession.GenerationError {
            switch gen {
            case .exceededContextWindowSize:
                return "A line on this page was too large to translate."
            case .guardrailViolation:
                return "Translation was blocked by on-device safety filters."
            case .unsupportedLanguageOrLocale:
                return "The on-device model doesn't support translating this content."
            case .assetsUnavailable:
                return "Apple Intelligence assets aren't ready yet. Try again in a few minutes."
            case .rateLimited:
                return "Too many AI requests right now. Please try again shortly."
            default:
                return gen.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Rendering

    /// Re-renders each source page into a new PDF: original page is drawn as
    /// the background (preserves images, tables, vector content), and each
    /// translated line is masked + redrawn at its source bounding box.
    nonisolated private static func renderPDF(
        sourceURL: URL,
        translatedPages: [[TranslatedSegment]],
        isRTL: Bool,
        destinationURL: URL,
        runID: String
    ) -> (url: URL, pageCount: Int)? {
        guard let pdf = PDFDocument(url: sourceURL), pdf.pageCount > 0 else {
            translatorLog.error("[\(runID, privacy: .public)] renderPDF: failed to open source PDF")
            return nil
        }
        guard let firstPage = pdf.page(at: 0) else {
            translatorLog.error("[\(runID, privacy: .public)] renderPDF: first page nil")
            return nil
        }
        let firstBounds = firstPage.bounds(for: .mediaBox)

        let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)
        let data = renderer.pdfData { ctx in
            for pageIndex in 0..<pdf.pageCount {
                guard let page = pdf.page(at: pageIndex) else {
                    translatorLog.error("[\(runID, privacy: .public)] renderPDF: page \(pageIndex + 1) nil")
                    continue
                }
                let pageBounds = page.bounds(for: .mediaBox)
                ctx.beginPage(withBounds: pageBounds, pageInfo: [:])
                let cg = ctx.cgContext

                // 1. Draw original page as background. PDF coords are bottom-up;
                // UIGraphicsPDFRenderer's context is top-down, so flip first.
                cg.saveGState()
                cg.translateBy(x: 0, y: pageBounds.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()

                // 2. Overlay translated text in UIKit top-down coords.
                let segments = pageIndex < translatedPages.count
                    ? translatedPages[pageIndex]
                    : []
                for segment in segments {
                    drawTranslatedSegment(
                        segment: segment,
                        pageBounds: pageBounds,
                        isRTL: isRTL
                    )
                }
                translatorLog.debug("[\(runID, privacy: .public)] renderPDF: page \(pageIndex + 1) painted (\(segments.count) segments)")
            }
        }

        do {
            try data.write(to: destinationURL)
        } catch {
            translatorLog.error("[\(runID, privacy: .public)] renderPDF: data.write FAILED: \(String(describing: error), privacy: .public)")
            return nil
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
        translatorLog.notice("[\(runID, privacy: .public)] renderPDF: wrote \(bytes) bytes to \(destinationURL.lastPathComponent, privacy: .public)")
        return (destinationURL, pdf.pageCount)
    }

    nonisolated private static func drawTranslatedSegment(
        segment: TranslatedSegment,
        pageBounds: CGRect,
        isRTL: Bool
    ) {
        // PDF bbox is bottom-up; convert to top-down for UIKit drawing.
        let bbox = CGRect(
            x: segment.bbox.minX,
            y: pageBounds.height - segment.bbox.maxY,
            width: segment.bbox.width,
            height: segment.bbox.height
        )
        let mask = bbox.insetBy(dx: -1.5, dy: -1.5)

        // 1. Mask original text. White is the safest neutral cover for most
        // PDFs — tinted backgrounds (table fills) behind text get masked too,
        // but that's an unavoidable tradeoff for replacing rasterized glyphs.
        UIColor.white.setFill()
        UIBezierPath(rect: mask).fill()

        // 2. Auto-fit translated text into the original bbox.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = isRTL ? .right : .left
        paragraph.lineBreakMode = .byClipping
        paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight

        let baseFontSize = max(6, bbox.height * 0.78)
        let font = sizedFont(
            for: segment.text,
            startingFontSize: baseFontSize,
            fittingWidth: bbox.width,
            minSize: 5
        )

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: segment.text, attributes: attrs)

        // Center text vertically within the original line bbox.
        let lineHeight = font.lineHeight
        let drawY = bbox.minY + max(0, (bbox.height - lineHeight) / 2)
        let drawRect = CGRect(x: bbox.minX, y: drawY, width: bbox.width, height: lineHeight + 4)
        attributed.draw(in: drawRect)
    }

    /// Shrinks the font down to `minSize` if needed to keep the text on one
    /// line within `fittingWidth`. Translation often expands compared to the
    /// source — without this, lines would overflow into neighbours.
    nonisolated private static func sizedFont(
        for text: String,
        startingFontSize: CGFloat,
        fittingWidth: CGFloat,
        minSize: CGFloat
    ) -> UIFont {
        var size = startingFontSize
        while size > minSize {
            let font = UIFont.systemFont(ofSize: size)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            if width <= fittingWidth { return font }
            size -= 0.5
        }
        return UIFont.systemFont(ofSize: minSize)
    }
}

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case spanish, french, german, italian, portuguese
    case chinese, japanese, korean
    case hindi, arabic, russian

    var id: Self { self }

    var displayName: String {
        switch self {
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .chinese: "Chinese (Simplified)"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .hindi: "Hindi"
        case .arabic: "Arabic"
        case .russian: "Russian"
        }
    }

    var flag: String {
        switch self {
        case .spanish: "🇪🇸"
        case .french: "🇫🇷"
        case .german: "🇩🇪"
        case .italian: "🇮🇹"
        case .portuguese: "🇵🇹"
        case .chinese: "🇨🇳"
        case .japanese: "🇯🇵"
        case .korean: "🇰🇷"
        case .hindi: "🇮🇳"
        case .arabic: "🇸🇦"
        case .russian: "🇷🇺"
        }
    }

    var isRTL: Bool {
        switch self {
        case .arabic: true
        default: false
        }
    }
}
