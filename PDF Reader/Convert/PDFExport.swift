import Foundation
import PDFKit
import UIKit

/// Turns a PDF into other formats: Word (.docx), plain text, and page images.
nonisolated enum PDFExport {
    enum ExportError: LocalizedError {
        case locked
        case noPages
        case noText
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .locked: "This PDF is password protected. Unlock it first."
            case .noPages: "This PDF has no pages."
            case .noText: "No text could be found. For scanned documents, run Scan to PDF with OCR first."
            case .writeFailed: "The file couldn't be written."
            }
        }
    }

    // MARK: - Text

    /// Plain text, one page after another, separated by a blank line.
    /// Falls back to the Library's stored OCR text for scanned documents.
    nonisolated static func text(from pdf: PDFDocument, fallbackOCR: String?) throws -> String {
        if pdf.isLocked { throw ExportError.locked }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            let raw = pdf.page(at: i)?.string ?? ""
            pages.append(normalizeParagraphs(raw))
        }
        let joined = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return joined }
        if let ocr = fallbackOCR?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty { return ocr }
        throw ExportError.noText
    }

    /// Rebuilds paragraphs from PDF line breaks: consecutive lines are
    /// joined unless the previous line looks like it ended a paragraph
    /// (terminal punctuation, short line, blank line) or the next one
    /// starts a list item.
    nonisolated static func normalizeParagraphs(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var paragraphs: [String] = []
        var current = ""
        let averageLength = max(30, lines.filter { !$0.isEmpty }.map(\.count).reduce(0, +) / max(1, lines.filter { !$0.isEmpty }.count))

        func flush() {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { paragraphs.append(t) }
            current = ""
        }

        for (index, line) in lines.enumerated() {
            if line.isEmpty { flush(); continue }
            let startsList = line.range(of: #"^([\-\*•▪◦]|\d+[\.\)]|[a-zA-Z][\.\)])\s"#, options: .regularExpression) != nil
            if startsList { flush() }
            if current.isEmpty {
                current = line
            } else if current.last.map({ "-–".contains($0) }) == true {
                // Hyphenated line break: join without a space.
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
            let endsSentence = line.last.map { ".!?:;\"”)".contains($0) } ?? false
            let isShort = line.count < Int(Double(averageLength) * 0.6)
            let nextIsBlank = index + 1 < lines.count ? lines[index + 1].isEmpty : true
            let looksLikeHeading = isShort && !endsSentence && !line.hasSuffix(",")
                && line.split(separator: " ").count <= 8
                && (line.first?.isUppercase == true || line.first?.isNumber == true)
                && current == line
            if endsSentence && (isShort || nextIsBlank) || isShort && nextIsBlank || looksLikeHeading {
                flush()
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Word

    struct WordOptions {
        /// Render scanned (text-less) pages as embedded images so nothing
        /// is silently dropped.
        var embedImagesForScannedPages = true
        /// DPI for embedded page images.
        var imageDPI: CGFloat = 150
    }

    /// Builds a .docx: one section per PDF page, paragraphs reconstructed
    /// from the text layer, page breaks between pages, and page images for
    /// pages without text. Returns the file bytes.
    nonisolated static func docx(from pdf: PDFDocument, title: String, options: WordOptions = WordOptions()) throws -> Data {
        if pdf.isLocked { throw ExportError.locked }
        guard pdf.pageCount > 0 else { throw ExportError.noPages }

        var body = ""
        var media: [(name: String, data: Data)] = []
        var relationships = ""
        var hasAnyText = false

        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let text = normalizeParagraphs(page.string ?? "")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasAnyText = true
                for paragraph in text.components(separatedBy: "\n\n") {
                    body += wordParagraph(paragraph)
                }
            } else if options.embedImagesForScannedPages {
                let bounds = page.bounds(for: .mediaBox)
                var scale = options.imageDPI / 72
                // Cap the bitmap like `imageData(for:)` does; scanned pages
                // can have very large point sizes and would otherwise need
                // hundreds of MB per page.
                let longest = max(bounds.width, bounds.height) * scale
                if longest > 4000 { scale *= 4000 / longest }
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let image = page.thumbnail(of: size, for: .mediaBox)
                if let jpeg = image.jpegData(compressionQuality: 0.8) {
                    let name = "image\(media.count + 1).jpeg"
                    let relID = "rIdImg\(media.count + 1)"
                    media.append((name, jpeg))
                    relationships += """
                    <Relationship Id="\(relID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(name)"/>
                    """
                    body += wordImageParagraph(relID: relID, index: media.count, pageSize: bounds.size)
                }
            }
            if i < pdf.pageCount - 1 {
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        guard hasAnyText || !media.isEmpty else { throw ExportError.noText }

        let zip = ZipArchive.Writer()
        zip.add("[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="jpeg" ContentType="image/jpeg"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        </Types>
        """.utf8))
        zip.add("_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """.utf8))
        zip.add("word/_rels/document.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        \(relationships)
        </Relationships>
        """.utf8))
        zip.add("word/styles.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        </w:styles>
        """.utf8))
        let now = ISO8601DateFormatter().string(from: Date())
        zip.add("docProps/core.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(xmlEscape(title))</dc:title><dc:creator>PDF Editor</dc:creator>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
        </cp:coreProperties>
        """.utf8))
        zip.add("word/document.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body>
        </w:document>
        """.utf8))
        for item in media {
            zip.add("word/media/\(item.name)", data: item.data)
        }
        return zip.finish()
    }

    nonisolated private static func wordParagraph(_ text: String) -> String {
        // Preserve intentional single line breaks inside a paragraph.
        let runs = text.components(separatedBy: "\n").map { line in
            "<w:r><w:t xml:space=\"preserve\">\(xmlEscape(line))</w:t></w:r>"
        }.joined(separator: "<w:r><w:br/></w:r>")
        return "<w:p>\(runs)</w:p>"
    }

    nonisolated private static func wordImageParagraph(relID: String, index: Int, pageSize: CGSize) -> String {
        // Fit inside 6.5in x 9in content area, in EMUs (914400 per inch).
        let maxW: CGFloat = 6.5 * 914_400, maxH: CGFloat = 9 * 914_400
        let scale = min(maxW / (pageSize.width / 72 * 914_400), maxH / (pageSize.height / 72 * 914_400), 1)
        let cx = Int(pageSize.width / 72 * 914_400 * scale)
        let cy = Int(pageSize.height / 72 * 914_400 * scale)
        return """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(index)" name="Page \(index)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(index)" name="Page \(index)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(relID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    nonisolated static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Strip control characters XML 1.0 forbids.
                if let scalar = ch.unicodeScalars.first, scalar.value < 0x20, !["\t", "\n", "\r"].contains(ch) { continue }
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Images

    enum ImageFormat: String, CaseIterable, Identifiable {
        case jpeg, png
        var id: Self { self }
        var title: String { self == .jpeg ? "JPEG" : "PNG" }
        var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    }

    enum Resolution: String, CaseIterable, Identifiable {
        case screen, print, high
        var id: Self { self }
        var title: String {
            switch self {
            case .screen: "Standard"
            case .print: "High"
            case .high: "Maximum"
            }
        }
        var subtitle: String {
            switch self {
            case .screen: "150 DPI · sharing and screens"
            case .print: "300 DPI · printing"
            case .high: "600 DPI · large files"
            }
        }
        var dpi: CGFloat {
            switch self {
            case .screen: 150
            case .print: 300
            case .high: 600
            }
        }
    }

    /// Renders one page to image bytes. Longest edge is capped at 8000 px
    /// to keep memory bounded on very large pages.
    nonisolated static func imageData(
        for page: PDFPage,
        format: ImageFormat,
        dpi: CGFloat,
        jpegQuality: CGFloat = 0.9
    ) -> Data? {
        let bounds = page.bounds(for: .cropBox)
        var scale = dpi / 72
        let longest = max(bounds.width, bounds.height) * scale
        if longest > 8000 { scale *= 8000 / longest }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        switch format {
        case .jpeg: return image.jpegData(compressionQuality: jpegQuality)
        case .png: return image.pngData()
        }
    }
}
