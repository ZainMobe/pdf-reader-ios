import Foundation
import UIKit

/// Pulls readable text out of Office Open XML packages without any
/// third-party library. Used as the fallback when WebKit can't paginate a
/// document, and as the source for PDF-to-Word round trips' opposite.
///
/// Output is an attributed string with light structure (headings, table
/// rows, slide titles) so the rendered PDF looks intentional rather than
/// like a dump of plain text.
enum OfficeTextExtractor {
    enum Kind {
        case word, excel, powerpoint
    }

    enum ExtractError: LocalizedError {
        case notOffice
        case noText

        var errorDescription: String? {
            switch self {
            case .notOffice: "This isn't a Word, Excel or PowerPoint file."
            case .noText: "No readable text was found in this file."
            }
        }
    }

    static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "docx", "docm", "dotx": .word
        case "xlsx", "xlsm", "xltx": .excel
        case "pptx", "pptm", "potx": .powerpoint
        default: nil
        }
    }

    /// Extracts styled text. Throws when the package can't be read or has
    /// no text at all (e.g. a presentation made only of pictures).
    static func attributedText(from url: URL) throws -> NSAttributedString {
        guard let kind = kind(of: url) else { throw ExtractError.notOffice }
        let zip = try ZipArchive.Reader(url: url)
        let result: NSAttributedString
        switch kind {
        case .word: result = try word(zip)
        case .excel: result = try excel(zip)
        case .powerpoint: result = try powerpoint(zip)
        }
        guard !result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractError.noText
        }
        return result
    }

    // MARK: - Styles

    private static let bodyFont = UIFont.systemFont(ofSize: 11)
    private static let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
    private static let headingFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
    private static let monoFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    private static func paragraph(_ text: String, font: UIFont, spacingAfter: CGFloat = 6) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text + "\n", attributes: [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: style,
        ])
    }

    static func pageBreak() -> NSAttributedString {
        // Form feed is honoured as a page break by UISimpleTextPrintFormatter.
        NSAttributedString(string: "\u{0C}", attributes: [.font: bodyFont])
    }

    // MARK: - Word

    private static func word(_ zip: ZipArchive.Reader) throws -> NSAttributedString {
        guard let xml = try zip.read("word/document.xml") else { throw ExtractError.notOffice }
        let collector = WordCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.parse()
        let out = NSMutableAttributedString()
        for p in collector.paragraphs {
            let font: UIFont
            switch p.style {
            case let s where s.hasPrefix("Title"): font = titleFont
            case let s where s.hasPrefix("Heading"): font = headingFont
            default: font = bodyFont
            }
            let text = p.text.trimmingCharacters(in: .newlines)
            out.append(paragraph(text, font: font, spacingAfter: font == bodyFont ? 6 : 10))
        }
        return out
    }

    /// SAX collector for `w:p` paragraphs: concatenates `w:t` runs, maps
    /// `w:tab` and `w:br` to tab / newline, keeps the paragraph style name,
    /// and flattens tables into tab-separated rows.
    private final class WordCollector: NSObject, XMLParserDelegate {
        struct Para { var text: String; var style: String }
        var paragraphs: [Para] = []
        private var current: Para?
        private var inText = false
        private var inTable = 0
        private var rowText = ""
        private var inRow = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "w:p":
                if !inRow { current = Para(text: "", style: "") }
            case "w:pStyle":
                if !inRow, let val = attributes["w:val"] { current?.style = val }
            case "w:t":
                inText = true
            case "w:tab":
                if inRow { rowText += "\t" } else { current?.text += "\t" }
            case "w:br", "w:cr":
                if inRow { rowText += " " } else { current?.text += "\n" }
            case "w:tbl":
                inTable += 1
            case "w:tr":
                inRow = true
                rowText = ""
            case "w:tc":
                if !rowText.isEmpty { rowText += "\t" }
            case "w:drawing", "w:pict":
                if !inRow { current?.text += "[Image] " }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inText else { return }
            if inRow { rowText += string } else { current?.text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "w:t":
                inText = false
            case "w:p":
                if !inRow, let p = current {
                    paragraphs.append(p)
                    current = nil
                }
            case "w:tr":
                inRow = false
                paragraphs.append(Para(text: rowText, style: "TableRow"))
            case "w:tbl":
                inTable = max(0, inTable - 1)
                paragraphs.append(Para(text: "", style: ""))
            default:
                break
            }
        }
    }

    // MARK: - Excel

    private static func excel(_ zip: ZipArchive.Reader) throws -> NSAttributedString {
        var shared: [String] = []
        if let sst = try zip.read("xl/sharedStrings.xml") {
            let c = SharedStringsCollector()
            let p = XMLParser(data: sst)
            p.delegate = c
            p.parse()
            shared = c.strings
        }
        // Sheet names from workbook.xml, in order; fall back to file order.
        var sheetNames: [String] = []
        if let wb = try zip.read("xl/workbook.xml") {
            let c = WorkbookCollector()
            let p = XMLParser(data: wb)
            p.delegate = c
            p.parse()
            sheetNames = c.names
        }
        let sheetFiles = zip.names
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { sheetNumber($0) < sheetNumber($1) }
        guard !sheetFiles.isEmpty else { throw ExtractError.notOffice }

        let out = NSMutableAttributedString()
        for (index, file) in sheetFiles.enumerated() {
            guard let xml = try zip.read(file) else { continue }
            let c = SheetCollector(shared: shared)
            let p = XMLParser(data: xml)
            p.delegate = c
            p.parse()
            guard !c.rows.isEmpty else { continue }
            if index > 0 { out.append(pageBreak()) }
            let name = index < sheetNames.count ? sheetNames[index] : "Sheet \(index + 1)"
            out.append(paragraph(name, font: headingFont, spacingAfter: 8))
            for row in c.rows {
                out.append(paragraph(row.joined(separator: "    "), font: monoFont, spacingAfter: 2))
            }
        }
        return out
    }

    private static func sheetNumber(_ name: String) -> Int {
        Int(name.replacingOccurrences(of: "xl/worksheets/sheet", with: "").replacingOccurrences(of: ".xml", with: "")) ?? 0
    }

    private final class SharedStringsCollector: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inT = false
        private var inSI = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "si" { inSI = true; current = "" }
            if name == "t" { inT = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inT { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inT = false }
            if name == "si" { strings.append(current); inSI = false }
        }
    }

    private final class WorkbookCollector: NSObject, XMLParserDelegate {
        var names: [String] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "sheet", let n = attributes["name"] { names.append(n) }
        }
    }

    private final class SheetCollector: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [String] = []
        private var cellType = ""
        private var value = ""
        private var inV = false
        private var inIS = false
        private var inlineText = ""
        init(shared: [String]) { self.shared = shared }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "row": row = []
            case "c": cellType = attributes["t"] ?? ""; value = ""; inlineText = ""
            case "v": inV = true
            case "is": inIS = true
            case "t": if inIS { inV = true }
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inV { if inIS { inlineText += string } else { value += string } }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v": inV = false
            case "t": if inIS { inV = false }
            case "is": inIS = false
            case "c":
                let text: String
                switch cellType {
                case "s": text = Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                case "inlineStr": text = inlineText
                case "b": text = value == "1" ? "TRUE" : "FALSE"
                default: text = value
                }
                row.append(text)
            case "row":
                // Trim trailing empties; skip fully empty rows.
                while row.last?.isEmpty == true { row.removeLast() }
                if !row.isEmpty { rows.append(row) }
            default: break
            }
        }
    }

    // MARK: - PowerPoint

    private static func powerpoint(_ zip: ZipArchive.Reader) throws -> NSAttributedString {
        let slides = zip.names
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }
        guard !slides.isEmpty else { throw ExtractError.notOffice }
        let out = NSMutableAttributedString()
        for (index, file) in slides.enumerated() {
            guard let xml = try zip.read(file) else { continue }
            let c = SlideCollector()
            let p = XMLParser(data: xml)
            p.delegate = c
            p.parse()
            if index > 0 { out.append(pageBreak()) }
            out.append(paragraph("Slide \(index + 1)", font: UIFont.systemFont(ofSize: 9, weight: .medium), spacingAfter: 4))
            for (i, para) in c.paragraphs.enumerated() where !para.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(paragraph(para, font: i == 0 ? titleFont : bodyFont, spacingAfter: i == 0 ? 12 : 5))
            }
        }
        return out
    }

    private static func slideNumber(_ name: String) -> Int {
        Int(name.replacingOccurrences(of: "ppt/slides/slide", with: "").replacingOccurrences(of: ".xml", with: "")) ?? 0
    }

    private final class SlideCollector: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var current = ""
        private var inT = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "a:p" { current = "" }
            if name == "a:t" { inT = true }
            if name == "a:br" { current += "\n" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inT { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "a:t" { inT = false }
            if name == "a:p" { paragraphs.append(current) }
        }
    }
}
