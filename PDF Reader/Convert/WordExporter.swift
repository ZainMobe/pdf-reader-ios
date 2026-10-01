import Foundation
import PDFKit
import UIKit

/// Layout-aware PDF → Word (.docx) conversion.
///
/// Instead of dumping `page.string`, every page is analysed:
///
/// * **Text** comes from PDFKit's line selections, which carry the font
///   name, point size and fill colour of every run. Lines are grouped into
///   paragraphs by their geometry; headings are detected from relative font
///   size and weight; alignment, left indents, list markers and column gaps
///   (emitted as tab stops) are preserved. Two-column pages are read column
///   by column.
/// * **Images** are located by scanning the page's content stream (including
///   nested Form XObjects) with the current transformation matrix, then cut
///   out of a page render so colour spaces, masks and clipping all come out
///   exactly as displayed.
/// * **Vector graphics** (charts, logos, diagrams) are found the same way from
///   path-painting operators, clustered, and embedded as pictures. Decorative
///   rules and shading behind text are left out; text that sits inside a
///   figure (chart labels) is rendered with the figure instead of duplicated.
/// * **Page geometry** (size, margins) is carried into the Word section so
///   the document paginates like the original.
///
/// Pages with no text layer are embedded as full-page images.
nonisolated enum WordExporter {

    struct Options {
        var embedScannedPages = true
        var imageDPI: CGFloat = 150
        var maxImageEdgePixels: CGFloat = 2400
    }

    // MARK: - Model

    struct Run {
        var text: String
        var fontName: String
        var size: CGFloat
        var bold: Bool
        var italic: Bool
        var color: UIColor?

        func sameStyle(as other: Run) -> Bool {
            fontName == other.fontName && abs(size - other.size) < 0.25
                && bold == other.bold && italic == other.italic
                && Self.hex(color) == Self.hex(other.color)
        }

        /// RRGGBB for Word, or nil when the colour should fall back to the
        /// default (black-ish text, or white/transparent text that would be
        /// invisible on Word's white page).
        static func hex(_ color: UIColor?) -> String? {
            guard let color else { return nil }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                var w: CGFloat = 0
                guard color.getWhite(&w, alpha: &a) else { return nil }
                r = w; g = w; b = w
            }
            if a < 0.05 { return nil }
            if r < 0.18 && g < 0.18 && b < 0.18 { return nil }
            if r > 0.92 && g > 0.92 && b > 0.92 { return nil }
            return String(format: "%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        }
    }

    struct Line {
        var bounds: CGRect
        var runs: [Run]
        /// Page-space x positions where a column gap starts (tab stops).
        var tabPositions: [CGFloat] = []
        var text: String { runs.map(\.text).joined() }
        var dominantSize: CGFloat {
            var weights: [CGFloat: Int] = [:]
            for run in runs { weights[(run.size * 2).rounded() / 2, default: 0] += run.text.count }
            return weights.max { $0.value < $1.value }?.key ?? bounds.height * 0.8
        }
        var isBold: Bool {
            let total = runs.reduce(0) { $0 + $1.text.count }
            let bold = runs.filter(\.bold).reduce(0) { $0 + $1.text.count }
            return total > 0 && bold * 10 >= total * 7
        }
    }

    enum Alignment { case left, center, right }

    struct Paragraph {
        var lines: [Line]
        var bounds: CGRect
        var headingLevel: Int?
        var alignment: Alignment = .left
        var leftIndentPt: CGFloat = 0
        var hangingIndentPt: CGFloat = 0
        var tabStopsPt: [CGFloat] = []
        var spaceBeforePt: CGFloat = 0
    }

    struct Figure {
        var rect: CGRect
        var data: Data
        var fileExtension: String
    }

    enum Block {
        case paragraph(Paragraph)
        case figure(Figure)

        var bounds: CGRect {
            switch self {
            case .paragraph(let p): p.bounds
            case .figure(let f): f.rect
            }
        }
    }

    struct PageContent {
        var box: CGRect
        var displaySize: CGSize
        var blocks: [Block]
        var textBounds: CGRect?
        var isScan: Bool
    }

    enum ExportFailure: Error { case nothingToExport }

    // MARK: - Entry point

    static func docx(from pdf: PDFDocument, title: String, options: Options = Options()) throws -> Data {
        var pages: [PageContent] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            autoreleasepool {
                pages.append(analyze(page: page, options: options))
            }
        }
        guard pages.contains(where: { !$0.blocks.isEmpty }) else { throw ExportFailure.nothingToExport }
        return WordWriter(title: title, pages: pages).build()
    }

    // MARK: - Page analysis

    static func analyze(page: PDFPage, options: Options) -> PageContent {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let displaySize = (rotation == 90 || rotation == 270)
            ? CGSize(width: box.height, height: box.width)
            : box.size

        var lines = extractLines(page: page, box: box)
        for i in lines.indices { insertColumnTabs(into: &lines[i], page: page) }

        let hasText = !lines.isEmpty
        let pageArea = max(box.width * box.height, 1)

        // Figures from the content stream.
        let graphics = GraphicsScanner.scan(page: page)

        // No text layer: a scanned page is embedded whole; a genuinely blank
        // page (nothing drawn at all) just becomes a page break.
        guard hasText else {
            let isBlank = graphics.images.isEmpty && graphics.paths.isEmpty
            guard !isBlank, options.embedScannedPages,
                  let figure = renderFigure(page: page, rect: box, box: box, displaySize: displaySize, options: options, preferPNG: false) else {
                return PageContent(box: box, displaySize: displaySize, blocks: [], textBounds: nil, isScan: true)
            }
            return PageContent(box: box, displaySize: displaySize, blocks: [.figure(figure)], textBounds: nil, isScan: true)
        }
        var figureRects = selectFigureRects(images: graphics.images, paths: graphics.paths, lines: lines, box: box, pageArea: pageArea, bodySize: bodyFontSize(of: lines))

        // Text that lives inside a figure (axis labels, legends) is part of
        // the picture; don't also emit it as paragraphs.
        if !figureRects.isEmpty {
            lines.removeAll { line in
                figureRects.contains { rect in
                    let inter = rect.intersection(line.bounds)
                    return !inter.isNull && inter.width * inter.height >= 0.6 * line.bounds.width * line.bounds.height
                }
            }
        }

        var blocks: [Block] = []
        for rect in figureRects {
            if let figure = renderFigure(page: page, rect: rect, box: box, displaySize: displaySize, options: options, preferPNG: !graphics.images.contains { $0.intersects(rect) }) {
                blocks.append(.figure(figure))
            }
        }
        figureRects.removeAll()

        let textBounds = lines.reduce(CGRect.null) { $0.union($1.bounds) }
        let bodySize = bodyFontSize(of: lines)

        // Group paragraphs per column so lines that share a baseline across
        // two columns aren't treated as alternating paragraphs.
        let layout = ColumnLayout(textBounds: textBounds.isNull ? box : textBounds)
        let columns: [(lines: [Line], bounds: CGRect)]
        if layout.isTwoColumn(lines.map(\.bounds)) {
            let left = lines.filter { layout.column(of: $0.bounds) == .left }
            let right = lines.filter { layout.column(of: $0.bounds) == .right }
            let span = lines.filter { layout.column(of: $0.bounds) == .span }
            columns = [
                (span, textBounds),
                (left, left.reduce(CGRect.null) { $0.union($1.bounds) }),
                (right, right.reduce(CGRect.null) { $0.union($1.bounds) }),
            ].filter { !$0.lines.isEmpty }
        } else {
            columns = [(lines, textBounds)]
        }
        for column in columns {
            let paragraphs = buildParagraphs(from: column.lines, box: box, textBounds: column.bounds, bodySize: bodySize)
            blocks.append(contentsOf: paragraphs.map(Block.paragraph))
        }

        let ordered = readingOrder(blocks, layout: layout)
        return PageContent(box: box, displaySize: displaySize, blocks: ordered, textBounds: textBounds.isNull ? nil : textBounds, isScan: false)
    }

    // MARK: Text lines

    /// The most common run size on the page, weighted by character count.
    static func bodyFontSize(of lines: [Line]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines {
            for run in line.runs { weights[(run.size * 2).rounded() / 2, default: 0] += run.text.count }
        }
        return weights.max { $0.value < $1.value }?.key ?? 11
    }

    /// Left / right / spanning classification of blocks on a page, shared
    /// by paragraph grouping and reading order so they agree.
    struct ColumnLayout {
        enum Column { case left, right, span }
        let center: CGFloat
        let margin: CGFloat

        init(textBounds: CGRect) {
            center = textBounds.midX
            margin = max(textBounds.width * 0.1, 12)
        }

        func column(of rect: CGRect) -> Column {
            if rect.midX < center, rect.maxX < center + margin { return .left }
            if rect.midX > center, rect.minX > center - margin { return .right }
            return .span
        }

        func isTwoColumn(_ rects: [CGRect]) -> Bool {
            guard rects.count >= 6 else { return false }
            var left = 0, right = 0, span = 0
            for rect in rects {
                switch column(of: rect) {
                case .left: left += 1
                case .right: right += 1
                case .span: span += 1
                }
            }
            return left >= 3 && right >= 3 && span * 3 <= rects.count
        }
    }

    static func extractLines(page: PDFPage, box: CGRect) -> [Line] {
        guard let whole = page.selection(for: box) else { return [] }
        var lines: [Line] = []
        for selection in whole.selectionsByLine() {
            guard let raw = selection.string else { continue }
            let cleaned = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { continue }

            var runs: [Run] = []
            if let attributed = selection.attributedString, attributed.length > 0 {
                let ns = attributed.string as NSString
                attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, range, _ in
                    let text = ns.substring(with: range)
                        .replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                    let font = attrs[.font] as? UIFont
                    let run = makeRun(text: text, font: font, color: attrs[.foregroundColor] as? UIColor, fallbackSize: bounds.height * 0.8)
                    if let last = runs.last, last.sameStyle(as: run) {
                        runs[runs.count - 1].text += run.text
                    } else {
                        runs.append(run)
                    }
                }
            }
            if runs.isEmpty {
                runs = [makeRun(text: cleaned, font: nil, color: nil, fallbackSize: bounds.height * 0.8)]
            }
            // Drop lines that are only whitespace after cleaning.
            guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            lines.append(Line(bounds: bounds, runs: runs))
        }
        return lines
    }

    private static func makeRun(text: String, font: UIFont?, color: UIColor?, fallbackSize: CGFloat) -> Run {
        let name = font?.fontName ?? ""
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let lower = name.lowercased()
        let bold = traits.contains(.traitBold)
            || lower.contains("bold") || lower.contains("black") || lower.contains("heavy")
            || lower.contains("semibold") || lower.contains("demibold") || lower.contains("extrabold")
        let italic = traits.contains(.traitItalic) || lower.contains("italic") || lower.contains("oblique")
        let size = font.map { $0.pointSize > 0 ? $0.pointSize : fallbackSize } ?? fallbackSize
        return Run(text: text, fontName: name, size: size, bold: bold, italic: italic, color: color)
    }

    /// Finds wide horizontal gaps inside a line (table cells, label/value
    /// pairs, columns that PDFKit merged into one line) and replaces them
    /// with a tab, remembering where each gap starts so the paragraph can
    /// declare matching tab stops.
    static func insertColumnTabs(into line: inout Line, page: PDFPage) {
        let ns = line.text as NSString
        let count = ns.length
        guard count >= 3 else { return }
        // `characterIndex(at:)` returns NSNotFound (Int.max) when nothing is
        // under the point; adding to it would overflow, so range-check first.
        let total = page.numberOfCharacters
        // Probe a few points inside the first glyph; hit-testing exactly on
        // the line's left edge often misses.
        var start = NSNotFound
        for dx: CGFloat in [2, 0.5, 4, max(line.bounds.height * 0.3, 1)] {
            let index = page.characterIndex(at: CGPoint(x: line.bounds.minX + dx, y: line.bounds.midY))
            if index != NSNotFound, index >= 0, index < total { start = index; break }
        }
        guard start != NSNotFound, count <= total - start else { return }

        var bounds: [CGRect] = []
        bounds.reserveCapacity(count)
        for i in 0..<count { bounds.append(page.characterBounds(at: start + i)) }
        guard let first = bounds.first, abs(first.minX - line.bounds.minX) < 4 else { return }

        // Only real glyphs take part in gap detection. PDFKit inserts spaces
        // between text objects whose bounds are empty or sit on the previous
        // glyph, which would hide the very gaps we're looking for.
        var glyphs: [Int] = []
        var widths: [CGFloat] = []
        for i in 0..<count {
            let unit = ns.character(at: i)
            let isSpace = unit == 0x20 || unit == 0xA0 || unit == 0x09
            guard bounds[i].width > 0.1, bounds[i].height > 0.1 else { continue }
            glyphs.append(i)
            if !isSpace { widths.append(bounds[i].width) }
        }
        guard widths.count >= 2 else { return }
        let averageWidth = widths.reduce(0, +) / CGFloat(widths.count)
        let threshold = max(averageWidth * 2.5, 9)

        var tabAfter = Set<Int>()
        var positions: [CGFloat] = []
        func markGap(after index: Int, nextGlyphX: CGFloat) {
            // Never split a surrogate pair.
            let unit = ns.character(at: index)
            if (0xD800...0xDBFF).contains(unit) { return }
            tabAfter.insert(index)
            positions.append(nextGlyphX)
        }
        for k in 0..<glyphs.count {
            let i = glyphs[k]
            let unit = ns.character(at: i)
            let isSpace = unit == 0x20 || unit == 0xA0
            // PDFKit's synthesised space between two text objects spans the
            // whole gap; a wide space *is* the column boundary.
            if isSpace, bounds[i].width > threshold {
                markGap(after: i, nextGlyphX: bounds[i].maxX)
                continue
            }
            // Otherwise look for empty space between consecutive glyphs.
            if k + 1 < glyphs.count {
                let j = glyphs[k + 1]
                let gap = bounds[j].minX - bounds[i].maxX
                if gap > threshold { markGap(after: i, nextGlyphX: bounds[j].minX) }
            }
        }
        guard !tabAfter.isEmpty else { return }

        // Rebuild runs with tabs inserted at the gap positions.
        var rebuilt: [Run] = []
        var offset = 0
        for run in line.runs {
            let runNS = run.text as NSString
            var units: [unichar] = []
            units.reserveCapacity(runNS.length + 2)
            for j in 0..<runNS.length {
                units.append(runNS.character(at: j))
                if tabAfter.contains(offset + j) { units.append(0x09) }
            }
            offset += runNS.length
            var text = String(utf16CodeUnits: units, count: units.count)
            // Whitespace next to a tab is just the gap PDFKit guessed at.
            while let range = text.range(of: " \t") { text.replaceSubrange(range, with: "\t") }
            while let range = text.range(of: "\t ") { text.replaceSubrange(range, with: "\t") }
            var copy = run
            copy.text = text
            rebuilt.append(copy)
        }
        line.runs = rebuilt
        line.tabPositions = positions
    }

    // MARK: Figures

    static func selectFigureRects(images: [CGRect], paths: [CGRect], lines: [Line], box: CGRect, pageArea: CGFloat, bodySize: CGFloat) -> [CGRect] {
        func textCoverage(of rect: CGRect) -> CGFloat {
            let area = rect.width * rect.height
            guard area > 0 else { return 0 }
            var covered: CGFloat = 0
            for line in lines {
                let inter = rect.intersection(line.bounds)
                if !inter.isNull { covered += inter.width * inter.height }
            }
            return min(covered / area, 1)
        }

        var kept: [CGRect] = []

        // Images.
        for raw in images {
            let rect = raw.standardized.intersection(box)
            guard !rect.isNull, rect.width >= 8, rect.height >= 8 else { continue }
            let area = rect.width * rect.height
            // A near-full-page image under a text layer is a scan with OCR:
            // the editable text is the content, not the picture.
            if area >= 0.85 * pageArea { continue }
            // Large background art behind running text would come out as a
            // duplicate of the text; skip it.
            if area >= 0.25 * pageArea, textCoverage(of: rect) > 0.25 { continue }
            kept.append(rect)
        }

        // Vector drawings: cluster path bounding boxes. Thin rules (axis
        // lines, borders, underlines) can't start a figure on their own but
        // do join a neighbouring cluster, so a chart keeps its axes.
        struct Candidate { var rect: CGRect; var isRule: Bool }
        var candidates: [Candidate] = []
        for raw in paths {
            let rect = raw.standardized.intersection(box)
            guard !rect.isNull else { continue }
            if rect.width * rect.height > 0.9 * pageArea { continue }      // page background fill
            if max(rect.width, rect.height) < 3 { continue }
            candidates.append(Candidate(rect: rect, isRule: min(rect.width, rect.height) < 1.5))
        }
        // Solid shapes first so rules attach to them rather than seeding
        // clusters of their own.
        candidates.sort { !$0.isRule && $1.isRule }
        struct Cluster { var rect: CGRect; var solidCount: Int }
        var clusters: [Cluster] = []
        let reach: CGFloat = 16
        for candidate in candidates {
            var merged = Cluster(rect: candidate.rect, solidCount: candidate.isRule ? 0 : 1)
            var changed = true
            while changed {
                changed = false
                for (i, existing) in clusters.enumerated().reversed() where existing.rect.insetBy(dx: -reach, dy: -reach).intersects(merged.rect) {
                    // A lone rule only joins a cluster that already has a shape.
                    if merged.solidCount == 0, existing.solidCount == 0 { continue }
                    merged.rect = merged.rect.union(existing.rect)
                    merged.solidCount += existing.solidCount
                    clusters.remove(at: i)
                    changed = true
                }
            }
            clusters.append(merged)
        }
        for entry in clusters where entry.solidCount > 0 {
            var cluster = entry.rect
            guard cluster.width >= 24, cluster.height >= 24 else { continue }
            if cluster.width * cluster.height > 0.9 * pageArea { continue }
            // Shading or highlight behind text, table cell fills: leave the
            // text editable instead of pasting a picture of it.
            if textCoverage(of: cluster) > 0.3 { continue }
            // Pull in small labels hugging the drawing (axis ticks, legend
            // entries) so they stay part of the picture.
            for line in lines {
                let near = line.bounds.insetBy(dx: -6, dy: -12).intersects(cluster)
                let small = line.dominantSize <= bodySize + 0.5 && line.text.count <= 40
                let inside = line.bounds.midX >= cluster.minX - 6 && line.bounds.midX <= cluster.maxX + 6
                    && line.bounds.width <= cluster.width + 12
                if near, small, inside { cluster = cluster.union(line.bounds) }
            }
            // A frame or border around an image belongs to that image.
            if let imageIndex = kept.firstIndex(where: { image in
                let inter = image.intersection(cluster)
                guard !inter.isNull else { return false }
                let smaller = min(image.width * image.height, cluster.width * cluster.height)
                return inter.width * inter.height >= 0.5 * smaller
            }) {
                kept[imageIndex] = kept[imageIndex].union(cluster)
                continue
            }
            kept.append(cluster)
        }

        // Overlapping figures would be rendered twice; merge them.
        var merged: [CGRect] = []
        for rect in kept.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            if let i = merged.firstIndex(where: { $0.intersects(rect) }) {
                merged[i] = merged[i].union(rect)
            } else {
                merged.append(rect)
            }
        }
        return merged
    }

    static func renderFigure(page: PDFPage, rect: CGRect, box: CGRect, displaySize: CGSize, options: Options, preferPNG: Bool) -> Figure? {
        var scale = options.imageDPI / 72
        let longest = max(displaySize.width, displaySize.height) * scale
        if longest > options.maxImageEdgePixels { scale *= options.maxImageEdgePixels / longest }
        let pixelSize = CGSize(width: floor(displaySize.width * scale), height: floor(displaySize.height * scale))
        guard pixelSize.width >= 2, pixelSize.height >= 2 else { return nil }

        let rendered = page.thumbnail(of: pixelSize, for: .cropBox)
        guard let cg = rendered.cgImage else { return nil }
        let imageScaleX = CGFloat(cg.width) / displaySize.width
        let imageScaleY = CGFloat(cg.height) / displaySize.height

        // Page space → rotated display space (Y up) → bitmap pixels (Y down).
        let display = rect.applying(page.transform(for: .cropBox))
        let pixelRect = CGRect(
            x: display.minX * imageScaleX,
            y: (displaySize.height - display.maxY) * imageScaleY,
            width: display.width * imageScaleX,
            height: display.height * imageScaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixelRect.isNull, pixelRect.width >= 2, pixelRect.height >= 2, let cropped = cg.cropping(to: pixelRect) else { return nil }

        let image = UIImage(cgImage: cropped)
        if preferPNG, let png = image.pngData(), png.count < 4_000_000 {
            return Figure(rect: rect, data: png, fileExtension: "png")
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        return Figure(rect: rect, data: jpeg, fileExtension: "jpeg")
    }

    // MARK: Paragraphs

    private static let listMarkerPattern = #"^\s*([•·\-–—▪◦●○■□➢➤✓✔►▶*]|\d{1,3}[.)]|\(\d{1,3}\)|[a-zA-Z][.)]|[ivxIVX]{1,5}[.)])\s"#

    static func buildParagraphs(from lines: [Line], box: CGRect, textBounds: CGRect, bodySize: CGFloat) -> [Paragraph] {
        guard !lines.isEmpty else { return [] }

        // Top-to-bottom, then left-to-right.
        let sorted = lines.sorted { a, b in
            if abs(a.bounds.maxY - b.bounds.maxY) > min(a.bounds.height, b.bounds.height) * 0.5 { return a.bounds.maxY > b.bounds.maxY }
            return a.bounds.minX < b.bounds.minX
        }

        let contentWidth = max(textBounds.width, 1)

        func isHeading(_ line: Line) -> Int? {
            let size = line.dominantSize
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if size >= bodySize * 1.6 { return 1 }
            if size >= bodySize * 1.3 { return 2 }
            if size >= bodySize * 1.15 { return 3 }
            if line.isBold, size >= bodySize - 0.5, line.bounds.width < contentWidth * 0.75,
               !text.hasSuffix("."), !text.hasSuffix(","), text.count <= 90 {
                return 3
            }
            return nil
        }

        var paragraphs: [Paragraph] = []
        var current: [Line] = []

        func flush() {
            guard !current.isEmpty else { return }
            paragraphs.append(makeParagraph(current, box: box, textBounds: textBounds, bodySize: bodySize, headingLevel: current.count <= 2 ? isHeading(current[0]) : nil))
            current = []
        }

        for line in sorted {
            guard let previous = current.last else {
                current = [line]
                continue
            }
            let heightRef = max(min(previous.bounds.height, line.bounds.height), 1)
            let gap = previous.bounds.minY - line.bounds.maxY
            let sameSize = abs(previous.dominantSize - line.dominantSize) <= 1.0
            let closeVertically = gap <= heightRef * 0.7 && gap > -heightRef * 0.6
            let startsList = line.text.range(of: listMarkerPattern, options: .regularExpression) != nil
            let previousIsHeading = isHeading(previous) != nil
            let lineIsHeading = isHeading(line) != nil
            // A visibly short previous line ends the paragraph when the new
            // line starts back at the paragraph's left edge.
            let paragraphLeft = current.map(\.bounds.minX).min() ?? previous.bounds.minX
            let previousShort = previous.bounds.width < contentWidth * 0.6 && previous.bounds.maxX < textBounds.maxX - contentWidth * 0.25
            let newLineAtLeft = abs(line.bounds.minX - paragraphLeft) < max(line.dominantSize, 6)
            let endsSentence = previous.text.trimmingCharacters(in: .whitespaces).last.map { ".!?:;\"”)".contains($0) } ?? false
            // Different column: no horizontal overlap at all.
            let horizontalOverlap = min(previous.bounds.maxX, line.bounds.maxX) - max(previous.bounds.minX, line.bounds.minX)
            let sameColumn = horizontalOverlap > -max(line.dominantSize * 2, 12)

            // Lines with column gaps are rows (tables, label/value pairs);
            // each stays its own paragraph so the tab stops line up.
            let isRow = !previous.tabPositions.isEmpty || !line.tabPositions.isEmpty
            let continues = closeVertically && sameSize && sameColumn && !startsList && !isRow
                && !previousIsHeading && !lineIsHeading
                && !(previousShort && newLineAtLeft && endsSentence)

            if continues {
                current.append(line)
            } else {
                flush()
                current = [line]
            }
        }
        flush()
        return paragraphs
    }

    private static func makeParagraph(_ lines: [Line], box: CGRect, textBounds: CGRect, bodySize: CGFloat, headingLevel: Int?) -> Paragraph {
        let bounds = lines.reduce(CGRect.null) { $0.union($1.bounds) }
        var paragraph = Paragraph(lines: lines, bounds: bounds, headingLevel: headingLevel)

        // Alignment, judged against the column's text block. A paragraph
        // whose lines all start at the same x is left-aligned no matter where
        // they end; centred and right-aligned text has a ragged left edge
        // (or is a single short line).
        let contentCenter = textBounds.midX
        let tolerance = max(bodySize * 0.6, 6)
        let lefts = lines.map(\.bounds.minX)
        let raggedLeft = lines.count == 1 || (lefts.max()! - lefts.min()!) > tolerance
        let narrow = lines.allSatisfy { $0.bounds.width < textBounds.width * 0.85 }
        let allCentered = raggedLeft && narrow
            && lines.allSatisfy { abs($0.bounds.midX - contentCenter) <= tolerance }
            && lines.allSatisfy { $0.bounds.minX > textBounds.minX + tolerance * 2 }
        let allRight = !allCentered && raggedLeft && narrow
            && lines.allSatisfy { abs($0.bounds.maxX - textBounds.maxX) <= tolerance }
            && lines.allSatisfy { $0.bounds.minX > textBounds.minX + tolerance * 3 }
        if allCentered {
            paragraph.alignment = .center
        } else if allRight {
            paragraph.alignment = .right
        } else {
            let indent = bounds.minX - textBounds.minX
            if indent > 4 { paragraph.leftIndentPt = indent }
        }

        // List marker → hanging indent so wrapped lines align under the text.
        // Headings like "1. Introduction" keep their heading style instead.
        if headingLevel == nil, lines[0].text.range(of: listMarkerPattern, options: .regularExpression) != nil {
            let hang = max(bodySize * 1.5, 14)
            paragraph.hangingIndentPt = hang
            if paragraph.alignment == .left { paragraph.leftIndentPt += hang }
        }

        // Tab stops: union of the column gaps in the paragraph's lines,
        // relative to the paragraph's left edge, de-duplicated within 4pt.
        var stops: [CGFloat] = []
        for line in lines {
            for x in line.tabPositions {
                let rel = x - bounds.minX
                guard rel > 4 else { continue }
                if !stops.contains(where: { abs($0 - rel) < 4 }) { stops.append(rel) }
            }
        }
        paragraph.tabStopsPt = stops.sorted()

        if headingLevel != nil { paragraph.spaceBeforePt = bodySize * 0.8 }
        return paragraph
    }

    // MARK: Reading order

    /// Top-to-bottom order, reading two-column layouts column by column.
    /// Blocks that span both columns (titles, full-width figures) act as
    /// separators between column segments.
    static func readingOrder(_ blocks: [Block], layout: ColumnLayout) -> [Block] {
        let byTop = blocks.sorted { $0.bounds.maxY > $1.bounds.maxY }
        guard layout.isTwoColumn(blocks.map(\.bounds)) else { return byTop }
        func column(_ block: Block) -> ColumnLayout.Column { layout.column(of: block.bounds) }

        var ordered: [Block] = []
        var left: [Block] = []
        var right: [Block] = []
        func flushColumns() {
            ordered.append(contentsOf: left)
            ordered.append(contentsOf: right)
            left = []
            right = []
        }
        for block in byTop {
            switch column(block) {
            case .span:
                flushColumns()
                ordered.append(block)
            case .left:
                left.append(block)
            case .right:
                right.append(block)
            }
        }
        flushColumns()
        return ordered
    }

    // MARK: - Content stream scanner

    /// Walks a page's content stream (and nested Form XObjects) tracking the
    /// CTM so image placements and painted path bounds come out in page
    /// space. Only geometry is collected; nothing is decoded.
    final class GraphicsScanner {
        private(set) var images: [CGRect] = []
        private(set) var paths: [CGRect] = []

        private var ctm = CGAffineTransform.identity
        private var stack: [CGAffineTransform] = []
        private var currentPath = CGRect.null
        private var depth = 0
        private var operations = 0
        private static let maxOperations = 400_000

        static func scan(page: PDFPage) -> (images: [CGRect], paths: [CGRect]) {
            guard let pageRef = page.pageRef else { return ([], []) }
            let scanner = GraphicsScanner()
            let content = CGPDFContentStreamCreateWithPage(pageRef)
            scanner.scan(contentStream: content)
            return (scanner.images, scanner.paths)
        }

        private static let table: CGPDFOperatorTableRef = {
            let table = CGPDFOperatorTableCreate()!
            func me(_ info: UnsafeMutableRawPointer?) -> GraphicsScanner? {
                info.map { Unmanaged<GraphicsScanner>.fromOpaque($0).takeUnretainedValue() }
            }
            func number(_ s: CGPDFScannerRef) -> CGFloat {
                var value: CGPDFReal = 0
                CGPDFScannerPopNumber(s, &value)
                return CGFloat(value)
            }
            CGPDFOperatorTableSetCallback(table, "q") { _, info in me(info)?.save() }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in me(info)?.restore() }
            CGPDFOperatorTableSetCallback(table, "cm") { s, info in
                let f = number(s), e = number(s), d = number(s), c = number(s), b = number(s), a = number(s)
                me(info)?.concatenate(CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f))
            }
            CGPDFOperatorTableSetCallback(table, "m") { s, info in
                let y = number(s), x = number(s)
                me(info)?.addPoint(CGPoint(x: x, y: y))
            }
            CGPDFOperatorTableSetCallback(table, "l") { s, info in
                let y = number(s), x = number(s)
                me(info)?.addPoint(CGPoint(x: x, y: y))
            }
            CGPDFOperatorTableSetCallback(table, "c") { s, info in
                let y3 = number(s), x3 = number(s), y2 = number(s), x2 = number(s), y1 = number(s), x1 = number(s)
                me(info)?.addPoint(CGPoint(x: x1, y: y1))
                me(info)?.addPoint(CGPoint(x: x2, y: y2))
                me(info)?.addPoint(CGPoint(x: x3, y: y3))
            }
            CGPDFOperatorTableSetCallback(table, "v") { s, info in
                let y3 = number(s), x3 = number(s), y2 = number(s), x2 = number(s)
                me(info)?.addPoint(CGPoint(x: x2, y: y2))
                me(info)?.addPoint(CGPoint(x: x3, y: y3))
            }
            CGPDFOperatorTableSetCallback(table, "y") { s, info in
                let y3 = number(s), x3 = number(s), y1 = number(s), x1 = number(s)
                me(info)?.addPoint(CGPoint(x: x1, y: y1))
                me(info)?.addPoint(CGPoint(x: x3, y: y3))
            }
            CGPDFOperatorTableSetCallback(table, "re") { s, info in
                let h = number(s), w = number(s), y = number(s), x = number(s)
                me(info)?.addRect(CGRect(x: x, y: y, width: w, height: h))
            }
            for op in ["f", "F", "f*", "B", "B*", "b", "b*", "S", "s"] {
                CGPDFOperatorTableSetCallback(table, op) { _, info in me(info)?.paintPath() }
            }
            CGPDFOperatorTableSetCallback(table, "n") { _, info in me(info)?.discardPath() }
            CGPDFOperatorTableSetCallback(table, "Do") { s, info in
                var name: UnsafePointer<CChar>? = nil
                guard CGPDFScannerPopName(s, &name), let name else { return }
                me(info)?.drawXObject(named: name, scanner: s)
            }
            // Inline image data arrives on EI as a stream object.
            CGPDFOperatorTableSetCallback(table, "EI") { s, info in
                var stream: CGPDFStreamRef? = nil
                if CGPDFScannerPopStream(s, &stream) { me(info)?.addImageUnitSquare() }
            }
            return table
        }()

        private func scan(contentStream: CGPDFContentStreamRef) {
            let info = Unmanaged.passUnretained(self).toOpaque()
            let scanner = CGPDFScannerCreate(contentStream, Self.table, info)
            _ = CGPDFScannerScan(scanner)
        }

        private func save() { stack.append(ctm) }
        private func restore() { ctm = stack.popLast() ?? .identity }
        private func concatenate(_ transform: CGAffineTransform) { ctm = transform.concatenating(ctm) }

        private func addPoint(_ point: CGPoint) {
            operations += 1
            let p = point.applying(ctm)
            guard p.x.isFinite, p.y.isFinite else { return }
            currentPath = currentPath.union(CGRect(origin: p, size: .zero))
        }

        private func addRect(_ rect: CGRect) {
            operations += 1
            let r = rect.applying(ctm)
            guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite else { return }
            currentPath = currentPath.union(r)
        }

        private func paintPath() {
            if !currentPath.isNull, operations < Self.maxOperations { paths.append(currentPath) }
            currentPath = .null
        }

        private func discardPath() { currentPath = .null }

        private func addImageUnitSquare() {
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return }
            images.append(rect)
        }

        private func drawXObject(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef) {
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef? = nil
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>? = nil
            CGPDFDictionaryGetName(dict, "Subtype", &subtype)
            guard let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                addImageUnitSquare()
            case "Form":
                guard depth < 8 else { return }
                depth += 1
                defer { depth -= 1 }
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef? = nil
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var values = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(array, i, &values[i]) }
                    matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
                }
                var resources: CGPDFDictionaryRef? = nil
                CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                let saved = ctm
                let savedStack = stack
                let savedPath = currentPath
                ctm = matrix.concatenating(ctm)
                currentPath = .null
                // A form without its own Resources inherits the parent's; the
                // parent chain handles that, so any dictionary will do here.
                let formStream = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, content)
                scan(contentStream: formStream)
                ctm = saved
                stack = savedStack
                currentPath = savedPath
            default:
                break
            }
        }
    }

    // MARK: - Word writer

    struct WordWriter {
        let title: String
        let pages: [PageContent]

        private static let emuPerPoint: CGFloat = 12_700
        private static let twipsPerPoint: CGFloat = 20

        func build() -> Data {
            // Section geometry from the first page and the tightest text
            // margins seen across the document (clamped to sane values).
            let first = pages.first
            let pageSize = first?.displaySize ?? CGSize(width: 612, height: 792)
            var margins = UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
            let textPages = pages.filter { $0.textBounds != nil }
            if !textPages.isEmpty {
                let left = textPages.map { $0.textBounds!.minX - $0.box.minX }.min() ?? 72
                let right = textPages.map { $0.box.maxX - $0.textBounds!.maxX }.min() ?? 72
                let top = textPages.map { $0.box.maxY - $0.textBounds!.maxY }.min() ?? 72
                let bottom = textPages.map { $0.textBounds!.minY - $0.box.minY }.min() ?? 72
                func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 36), 108) }
                margins = UIEdgeInsets(top: clamp(top), left: clamp(left), bottom: clamp(bottom), right: clamp(right))
            }
            let contentWidth = max(pageSize.width - margins.left - margins.right, 144)
            let contentHeight = max(pageSize.height - margins.top - margins.bottom, 144)

            var body = ""
            var media: [(name: String, data: Data)] = []
            var relationships = ""
            var pictureIndex = 0

            for (pageIndex, page) in pages.enumerated() {
                for block in page.blocks {
                    switch block {
                    case .paragraph(let paragraph):
                        body += paragraphXML(paragraph, page: page, margins: margins)
                    case .figure(let figure):
                        pictureIndex += 1
                        let name = "image\(pictureIndex).\(figure.fileExtension)"
                        let relID = "rIdImg\(pictureIndex)"
                        media.append((name, figure.data))
                        relationships += """
                        <Relationship Id="\(relID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(name)"/>
                        """
                        let size = page.isScan ? page.displaySize : figure.rect.size
                        body += pictureXML(relID: relID, index: pictureIndex, sizePt: size, maxWidth: contentWidth, maxHeight: contentHeight, centered: !page.isScan)
                    }
                }
                if pageIndex < pages.count - 1 {
                    body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                }
            }

            let pgW = Int(pageSize.width * Self.twipsPerPoint)
            let pgH = Int(pageSize.height * Self.twipsPerPoint)
            let orient = pageSize.width > pageSize.height ? " w:orient=\"landscape\"" : ""
            let sectPr = """
            <w:sectPr><w:pgSz w:w="\(pgW)" w:h="\(pgH)"\(orient)/><w:pgMar w:top="\(Int(margins.top * Self.twipsPerPoint))" w:right="\(Int(margins.right * Self.twipsPerPoint))" w:bottom="\(Int(margins.bottom * Self.twipsPerPoint))" w:left="\(Int(margins.left * Self.twipsPerPoint))" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
            """

            let zip = ZipArchive.Writer()
            zip.add("[Content_Types].xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Default Extension="jpeg" ContentType="image/jpeg"/>
            <Default Extension="png" ContentType="image/png"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
            <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
            <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
            </Types>
            """.utf8))
            zip.add("_rels/.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
            </Relationships>
            """.utf8))
            zip.add("word/_rels/document.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            <Relationship Id="rIdSettings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
            \(relationships)
            </Relationships>
            """.utf8))
            zip.add("word/styles.xml", data: Data(Self.stylesXML.utf8))
            zip.add("word/settings.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
            """.utf8))
            let now = ISO8601DateFormatter().string(from: Date())
            zip.add("docProps/core.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <dc:title>\(PDFExport.xmlEscape(title))</dc:title><dc:creator>PDF Editor</dc:creator>
            <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
            </cp:coreProperties>
            """.utf8))
            zip.add("docProps/app.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>PDF Editor</Application><Pages>\(pages.count)</Pages></Properties>
            """.utf8))
            zip.add("word/document.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
            <w:body>\(body)\(sectPr)</w:body>
            </w:document>
            """.utf8))
            for item in media {
                zip.add("word/media/\(item.name)", data: item.data)
            }
            return zip.finish()
        }

        // MARK: Paragraphs

        private func paragraphXML(_ paragraph: Paragraph, page: PageContent, margins: UIEdgeInsets) -> String {
            var pPr = ""
            if let level = paragraph.headingLevel {
                pPr += "<w:pStyle w:val=\"Heading\(min(max(level, 1), 3))\"/>"
            }
            if !paragraph.tabStopsPt.isEmpty {
                pPr += "<w:tabs>"
                for stop in paragraph.tabStopsPt.prefix(20) {
                    pPr += "<w:tab w:val=\"left\" w:pos=\"\(Int(stop * Self.twipsPerPoint))\"/>"
                }
                pPr += "</w:tabs>"
            }
            if paragraph.spaceBeforePt > 0 {
                pPr += "<w:spacing w:before=\"\(Int(paragraph.spaceBeforePt * Self.twipsPerPoint))\"/>"
            }
            if paragraph.leftIndentPt > 0 || paragraph.hangingIndentPt > 0 {
                var ind = "<w:ind"
                if paragraph.leftIndentPt > 0 { ind += " w:left=\"\(Int(paragraph.leftIndentPt * Self.twipsPerPoint))\"" }
                if paragraph.hangingIndentPt > 0 { ind += " w:hanging=\"\(Int(paragraph.hangingIndentPt * Self.twipsPerPoint))\"" }
                ind += "/>"
                pPr += ind
            }
            switch paragraph.alignment {
            case .center: pPr += "<w:jc w:val=\"center\"/>"
            case .right: pPr += "<w:jc w:val=\"right\"/>"
            case .left: break
            }

            // Join the paragraph's lines into one flow of runs: a space
            // between lines, no space after a hyphenated line break.
            var runs: [Run] = []
            for (index, line) in paragraph.lines.enumerated() {
                var lineRuns = line.runs
                if index > 0, let lastPrevious = runs.last {
                    let previousText = lastPrevious.text
                    let hyphenated = previousText.hasSuffix("-") && !previousText.hasSuffix(" -")
                    if hyphenated {
                        runs[runs.count - 1].text.removeLast()
                    } else if !previousText.hasSuffix(" "), !(lineRuns.first?.text.hasPrefix(" ") ?? true) {
                        runs[runs.count - 1].text += " "
                    }
                }
                // Trim leading/trailing whitespace of the whole line but keep
                // interior spacing and tabs.
                if var firstRun = lineRuns.first {
                    firstRun.text = String(firstRun.text.drop { $0 == " " })
                    lineRuns[0] = firstRun
                }
                if var lastRun = lineRuns.last {
                    while lastRun.text.last == " " { lastRun.text.removeLast() }
                    lineRuns[lineRuns.count - 1] = lastRun
                }
                for run in lineRuns where !run.text.isEmpty {
                    if let last = runs.last, last.sameStyle(as: run) {
                        runs[runs.count - 1].text += run.text
                    } else {
                        runs.append(run)
                    }
                }
            }

            var xml = "<w:p>"
            if !pPr.isEmpty { xml += "<w:pPr>\(pPr)</w:pPr>" }
            for run in runs { xml += runXML(run, isHeading: paragraph.headingLevel != nil) }
            xml += "</w:p>"
            return xml
        }

        private func runXML(_ run: Run, isHeading: Bool) -> String {
            var rPr = ""
            let family = Self.wordFontFamily(for: run.fontName)
            rPr += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:cs=\"\(family)\"/>"
            if run.bold { rPr += "<w:b/><w:bCs/>" }
            if run.italic { rPr += "<w:i/><w:iCs/>" }
            if let hex = Run.hex(run.color) { rPr += "<w:color w:val=\"\(hex)\"/>" }
            let halfPoints = Int(min(max((run.size * 2).rounded(), 12), 288))
            rPr += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"

            // Tabs are their own elements in WordprocessingML.
            var xml = ""
            let pieces = run.text.split(separator: "\t", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index > 0 { xml += "<w:r><w:rPr>\(rPr)</w:rPr><w:tab/></w:r>" }
                if !piece.isEmpty {
                    xml += "<w:r><w:rPr>\(rPr)</w:rPr><w:t xml:space=\"preserve\">\(PDFExport.xmlEscape(String(piece)))</w:t></w:r>"
                }
            }
            return xml
        }

        /// Maps a PDF font (often a subset like "ABCDEF+Helvetica-BoldOblique")
        /// to a family Word is guaranteed to have, keeping the serif / sans /
        /// monospace character of the original.
        static func wordFontFamily(for postScriptName: String) -> String {
            var name = postScriptName
            if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
                name = String(name[name.index(after: plus)...])
            }
            let lower = name.lowercased()
            if lower.contains("courier") || lower.contains("mono") || lower.contains("consolas") || lower.contains("menlo") || lower.contains("monaco") {
                return "Courier New"
            }
            if lower.contains("times") || lower.contains("georgia") || lower.contains("garamond") || lower.contains("cambria")
                || lower.contains("palatino") || lower.contains("book") || lower.contains("minion") || lower.contains("baskerville")
                || lower.contains("century") || lower.contains("didot") || lower.contains("bodoni") || lower.contains("charter")
                || (lower.contains("serif") && !lower.contains("sans")) {
                return "Times New Roman"
            }
            if lower.contains("arial") || lower.contains("helvetica") { return "Arial" }
            if lower.contains("verdana") { return "Verdana" }
            if lower.contains("calibri") { return "Calibri" }
            if lower.contains("segoe") || lower.contains("tahoma") { return "Segoe UI" }
            if lower.contains("roboto") || lower.contains("opensans") || lower.contains("open sans") || lower.contains("lato") || lower.contains("sfpro") || lower.contains("sf pro") || lower.contains(".sf") {
                return "Arial"
            }
            // Unknown family: use Core Text's classification bits when we have them.
            if let font = UIFont(name: name, size: 12) {
                let classBits = font.fontDescriptor.symbolicTraits.rawValue & UIFontDescriptor.SymbolicTraits.classMask.rawValue
                switch UIFontDescriptor.SymbolicTraits(rawValue: classBits) {
                case .classOldStyleSerifs, .classTransitionalSerifs, .classModernSerifs, .classClarendonSerifs, .classSlabSerifs, .classFreeformSerifs:
                    return "Times New Roman"
                case .classSansSerif:
                    return "Arial"
                default:
                    break
                }
                if font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) { return "Courier New" }
            }
            return "Calibri"
        }

        // MARK: Pictures

        private func pictureXML(relID: String, index: Int, sizePt: CGSize, maxWidth: CGFloat, maxHeight: CGFloat, centered: Bool) -> String {
            guard sizePt.width > 0, sizePt.height > 0 else { return "" }
            let scale = min(maxWidth / sizePt.width, maxHeight / sizePt.height, 1)
            let cx = Int(sizePt.width * scale * Self.emuPerPoint)
            let cy = Int(sizePt.height * scale * Self.emuPerPoint)
            let jc = centered ? "<w:pPr><w:jc w:val=\"center\"/><w:spacing w:before=\"120\" w:after=\"120\"/></w:pPr>" : "<w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr>"
            return """
            <w:p>\(jc)<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(index)" name="Picture \(index)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(index)" name="Picture \(index)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(relID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
        }

        // MARK: Styles

        private static let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="252" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
        <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>
        </w:styles>
        """
    }
}
