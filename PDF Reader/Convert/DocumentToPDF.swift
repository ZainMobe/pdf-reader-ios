import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Converts non-PDF documents (Word, Excel, PowerPoint, Pages, Numbers,
/// Keynote, RTF, plain text, Markdown, HTML) and live web pages into
/// paginated PDFs, entirely on device.
///
/// Strategy per input:
/// - Text-like (txt, md, rtf, rtfd): laid out directly with TextKit through
///   `UISimpleTextPrintFormatter`. Deterministic, fast, no WebKit.
/// - HTML and web URLs: WebKit renders, `UIPrintPageRenderer` paginates.
/// - Office and iWork: WebKit's built-in document preview is tried first
///   because it keeps layout, fonts and images. If the result comes back
///   blank (WebKit can't print some previews) the Office package is opened
///   directly and its text is laid out with TextKit instead, and the caller
///   is told so it can say "layout simplified".
@MainActor
enum DocumentToPDF {
    enum Source {
        case file(URL)
        case web(URL)
    }

    struct Output {
        var data: Data
        var pageCount: Int
        /// Non-nil when the result is a text-only rendering.
        var note: String?
        /// Suggested document title.
        var title: String
    }

    enum ConversionError: LocalizedError {
        case unsupportedType(String)
        case emptyResult
        case webFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext): "\(ext.uppercased()) files can't be converted yet."
            case .emptyResult: "The document rendered as empty pages. It may be protected or contain only unsupported content."
            case .webFailed(let reason): "The page couldn't be loaded: \(reason)"
            case .timedOut: "The document took too long to render."
            }
        }
    }

    /// Page geometry for all conversions.
    nonisolated struct PageSetup {
        var size: CGSize = CGSize(width: 612, height: 792) // US Letter
        var margins: UIEdgeInsets = UIEdgeInsets(top: 54, left: 54, bottom: 54, right: 54)

        static let letter = PageSetup()
        static let a4 = PageSetup(size: CGSize(width: 595.28, height: 841.89))
    }

    /// File types the tool's picker should offer.
    static var supportedTypes: [UTType] {
        var types: [UTType] = [.rtf, .rtfd, .plainText, .utf8PlainText, .html, .xml, .json, .sourceCode]
        let identifiers = [
            "org.openxmlformats.wordprocessingml.document",
            "org.openxmlformats.spreadsheetml.sheet",
            "org.openxmlformats.presentationml.presentation",
            "com.microsoft.word.doc",
            "com.microsoft.excel.xls",
            "com.microsoft.powerpoint.ppt",
            "com.apple.iwork.pages.pages",
            "com.apple.iwork.numbers.numbers",
            "com.apple.iwork.keynote.key",
            "com.apple.iwork.pages.sffpages",
            "com.apple.iwork.numbers.sffnumbers",
            "com.apple.iwork.keynote.sffkey",
            "net.daringfireball.markdown",
            "public.comma-separated-values-text",
        ]
        types.append(contentsOf: identifiers.compactMap { UTType($0) })
        return types
    }

    // MARK: - Entry point

    static func convert(_ source: Source, page: PageSetup = .letter) async throws -> Output {
        switch source {
        case .web(let url):
            let data = try await WebRenderer.render(.web(url), page: page)
            let count = PDFDocument(data: data)?.pageCount ?? 0
            guard count > 0 else { throw ConversionError.emptyResult }
            let title = WebRenderer.lastTitle ?? url.host() ?? "Web page"
            return Output(data: data, pageCount: count, note: nil, title: title)

        case .file(let url):
            let ext = url.pathExtension.lowercased()
            let title = url.deletingPathExtension().lastPathComponent

            switch ext {
            case "txt", "text", "log", "csv", "json", "xml", "swift", "py", "js", "ts", "java", "kt", "c", "h", "m", "cpp", "sh", "yml", "yaml":
                let text = try readText(at: url)
                let mono = ["json", "xml", "swift", "py", "js", "ts", "java", "kt", "c", "h", "m", "cpp", "sh", "yml", "yaml", "csv", "log"].contains(ext)
                let attributed = plainAttributed(text, monospaced: mono)
                let data = try TextRenderer.render(attributed, page: page)
                return Output(data: data, pageCount: PDFDocument(data: data)?.pageCount ?? 0, note: nil, title: title)

            case "md", "markdown":
                let text = try readText(at: url)
                let attributed = markdownAttributed(text)
                let data = try TextRenderer.render(attributed, page: page)
                return Output(data: data, pageCount: PDFDocument(data: data)?.pageCount ?? 0, note: nil, title: title)

            case "rtf", "rtfd":
                let attributed = try NSAttributedString(
                    url: url,
                    options: [.documentType: ext == "rtf" ? NSAttributedString.DocumentType.rtf : .rtfd],
                    documentAttributes: nil
                )
                let data = try TextRenderer.render(attributed, page: page)
                return Output(data: data, pageCount: PDFDocument(data: data)?.pageCount ?? 0, note: nil, title: title)

            case "html", "htm", "xhtml":
                let data = try await WebRenderer.render(.file(url), page: page)
                let count = PDFDocument(data: data)?.pageCount ?? 0
                guard count > 0, !(await isBlank(data)) else { throw ConversionError.emptyResult }
                return Output(data: data, pageCount: count, note: nil, title: title)

            case "docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "potx",
                 "doc", "xls", "ppt", "pages", "numbers", "key":
                // WebKit first: full layout.
                if let data = try? await WebRenderer.render(.file(url), page: page),
                   let count = PDFDocument(data: data)?.pageCount, count > 0,
                   !(await isBlank(data)) {
                    return Output(data: data, pageCount: count, note: nil, title: title)
                }
                // Text fallback for Office Open XML.
                if OfficeTextExtractor.kind(of: url) != nil {
                    let attributed = try OfficeTextExtractor.attributedText(from: url)
                    let data = try TextRenderer.render(attributed, page: page)
                    return Output(
                        data: data,
                        pageCount: PDFDocument(data: data)?.pageCount ?? 0,
                        note: "Converted as text. Images and complex layout were simplified.",
                        title: title
                    )
                }
                throw ConversionError.emptyResult

            default:
                throw ConversionError.unsupportedType(ext.isEmpty ? "This" : ext)
            }
        }
    }

    // MARK: - Text helpers

    private static func plainAttributed(_ text: String, monospaced: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = monospaced ? 0 : 6
        let font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
            : UIFont.systemFont(ofSize: 11)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: style,
        ])
    }

    private static func markdownAttributed(_ text: String) -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return plainAttributed(text, monospaced: false)
        }
        // Map presentation intents to fonts so headings and lists read as such.
        //
        // Runs split on every attribute boundary (bold, link, code…), not
        // just paragraphs, so the newline that restores block boundaries is
        // emitted once per block (tracked by presentation intent identity),
        // not once per run — otherwise "This is **bold** text" became three lines.
        let out = NSMutableAttributedString()
        var lastBlockIdentity: Int?
        for run in parsed.runs {
            var font = UIFont.systemFont(ofSize: 11)
            var prefix = ""
            let blockIdentity = run.presentationIntent?.components.first?.identity
            let startsNewBlock = blockIdentity != lastBlockIdentity
            if startsNewBlock, lastBlockIdentity != nil {
                out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            lastBlockIdentity = blockIdentity

            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        font = UIFont.systemFont(ofSize: max(11, 22 - CGFloat(level) * 2), weight: .bold)
                    case .listItem(let ordinal):
                        if startsNewBlock { prefix = ordinal > 0 ? "\(ordinal). " : "•  " }
                    case .codeBlock:
                        font = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
                    case .blockQuote:
                        font = UIFont.italicSystemFont(ofSize: 11)
                    default:
                        break
                    }
                }
            }
            if let inline = run.inlinePresentationIntent {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if inline.contains(.emphasized) { traits.insert(.traitItalic) }
                if inline.contains(.code) { font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular) }
                if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: d, size: font.pointSize)
                }
            }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            let piece = prefix + String(parsed[run.range].characters)
            out.append(NSAttributedString(string: piece, attributes: [
                .font: font, .foregroundColor: UIColor.black, .paragraphStyle: style,
            ]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 11)]))
        return out
    }

    /// Reads a text file, detecting its encoding. Falls back to Windows-1252
    /// (the usual encoding of CSVs exported from Excel on Windows) instead of
    /// failing with an opaque "couldn't be opened using text encoding" error.
    private static func readText(at url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return try String(contentsOf: url, encoding: .windowsCP1252)
    }

    /// Cheap blank-page check: renders page 1 tiny and looks for any pixel
    /// darker than near-white.
    private static func isBlank(_ pdfData: Data) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(data: pdfData), let page = pdf.page(at: 0) else { return true }
            let image = page.thumbnail(of: CGSize(width: 48, height: 64), for: .mediaBox)
            guard let cg = image.cgImage,
                  let provider = cg.dataProvider,
                  let data = provider.data,
                  let ptr = CFDataGetBytePtr(data) else { return false }
            let length = CFDataGetLength(data)
            var i = 0
            let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
            while i + 2 < length {
                if ptr[i] < 235 || ptr[i + 1] < 235 || ptr[i + 2] < 235 { return false }
                i += bytesPerPixel
            }
            return true
        }.value
    }

    // MARK: - TextKit renderer

    enum TextRenderer {
        /// Form feed (U+000C) characters split the text into sections that
        /// each start on a fresh page (sheets, slides).
        static func render(_ attributed: NSAttributedString, page: PageSetup) throws -> Data {
            let renderer = UIPrintPageRenderer()
            let paper = CGRect(origin: .zero, size: page.size)
            renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
            renderer.setValue(NSValue(cgRect: paper.inset(by: page.margins)), forKey: "printableRect")

            let sections = split(attributed, on: "\u{0C}")
            for section in sections {
                let formatter = UISimpleTextPrintFormatter(attributedText: section)
                formatter.perPageContentInsets = .zero
                // numberOfPages forces layout of what's been added so far, so
                // the next section starts on the page after the previous one.
                let start = renderer.printFormatters?.isEmpty == false ? renderer.numberOfPages : 0
                renderer.addPrintFormatter(formatter, startingAtPageAt: start)
            }
            return try paginate(renderer, page: page)
        }

        private static func split(_ text: NSAttributedString, on separator: String) -> [NSAttributedString] {
            var result: [NSAttributedString] = []
            let full = text.string as NSString
            var location = 0
            while location <= full.length {
                let range = full.range(of: separator, range: NSRange(location: location, length: full.length - location))
                let end = range.location == NSNotFound ? full.length : range.location
                let piece = text.attributedSubstring(from: NSRange(location: location, length: end - location))
                if piece.length > 0 { result.append(piece) }
                if range.location == NSNotFound { break }
                location = end + range.length
            }
            return result.isEmpty ? [text] : result
        }
    }

    /// Shared pagination for any `UIPrintPageRenderer`.
    static func paginate(_ renderer: UIPrintPageRenderer, page: PageSetup) throws -> Data {
        let paper = CGRect(origin: .zero, size: page.size)
        let printable = paper.inset(by: page.margins)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, [
            kCGPDFContextCreator as String: "PDF Editor",
        ])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let count = renderer.numberOfPages
        for i in 0..<count {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        guard count > 0 else { throw ConversionError.emptyResult }
        return data as Data
    }

    // MARK: - WebKit renderer

    /// Hosts a WKWebView behind the app's root view (WebKit only paints
    /// when it's in a window), loads the source, and paginates through the
    /// view's print formatter.
    @MainActor
    final class WebRenderer: NSObject, WKNavigationDelegate {
        static var lastTitle: String?

        private var webView: WKWebView?
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        static func render(_ source: Source, page: PageSetup, timeout: TimeInterval = 45) async throws -> Data {
            let renderer = WebRenderer()
            defer { renderer.tearDown() }
            try await renderer.load(source, timeout: timeout)
            return try renderer.paginate(page: page)
        }

        private func load(_ source: Source, timeout: TimeInterval) async throws {
            let config = WKWebViewConfiguration()
            config.suppressesIncrementalRendering = true
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056), configuration: config)
            webView.navigationDelegate = self
            webView.isUserInteractionEnabled = false
            webView.isOpaque = true
            webView.backgroundColor = .white
            self.webView = webView

            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first
            else { throw ConversionError.webFailed("No window available.") }
            window.insertSubview(webView, at: 0)

            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(ConversionError.timedOut))
                }
                switch source {
                case .file(let url):
                    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                case .web(let url):
                    var request = URLRequest(url: url)
                    request.timeoutInterval = timeout
                    webView.load(request)
                }
            }

            // Give lazy layouts, web fonts and document previews a moment
            // to settle before printing.
            try? await Task.sleep(for: .milliseconds(source.isWeb ? 1200 : 700))
            Self.lastTitle = webView.title?.isEmpty == false ? webView.title : nil
        }

        private func paginate(page: PageSetup) throws -> Data {
            guard let webView else { throw ConversionError.emptyResult }
            let renderer = UIPrintPageRenderer()
            renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
            return try DocumentToPDF.paginate(renderer, page: page)
        }

        private func finish(_ result: Result<Void, Error>) {
            timeoutTask?.cancel()
            timeoutTask = nil
            guard let c = continuation else { return }
            continuation = nil
            c.resume(with: result)
        }

        private func tearDown() {
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.removeFromSuperview()
            webView = nil
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(ConversionError.webFailed(error.localizedDescription)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(ConversionError.webFailed(error.localizedDescription)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure(ConversionError.webFailed("The page used too much memory.")))
        }
    }
}

private extension DocumentToPDF.Source {
    var isWeb: Bool {
        if case .web = self { return true }
        return false
    }
}
