import AppIntents
import Foundation
import PDFKit
import UniformTypeIdentifiers

// MARK: - Intents that open the app

struct ScanDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a Document"
    static let description = IntentDescription("Opens the scanner so you can capture pages into a searchable PDF.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IncomingFileRouter.shared.handleAppScheme(URL(string: "pdfeditor://scan")!)
        return .result()
    }
}

struct AskLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask your Library"
    static let description = IntentDescription("Searches every PDF in your Library and answers with citations.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask your Library \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        var components = URLComponents(string: "pdfeditor://ask")!
        components.queryItems = [URLQueryItem(name: "q", value: question)]
        IncomingFileRouter.shared.handleAppScheme(components.url!)
        return .result()
    }
}

struct AddToLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to PDF Editor"
    static let description = IntentDescription("Adds PDFs or images to your Library. Images become one PDF.")
    static let openAppWhenRun = true

    @Parameter(title: "Files", supportedContentTypes: [.pdf, .image])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$files) to PDF Editor")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !files.isEmpty else { throw IntentError.noInput }
        // Stage through the same inbox the Share Extension uses, so all the
        // validation, conversion and de-duplication lives in one place.
        let batch = try SharedInbox.beginBatch()
        var items: [SharedInbox.Item] = []
        for (index, file) in files.prefix(SharedInbox.maxItemsPerBatch).enumerated() {
            let type = file.type ?? UTType(filenameExtension: (file.filename as NSString).pathExtension) ?? .data
            guard let kind = SharedInbox.kind(for: type) else { continue }
            let ext = type.preferredFilenameExtension ?? (kind == .pdf ? "pdf" : "jpg")
            let storedName = "\(index).\(ext)"
            try file.data.write(to: batch.url.appending(path: storedName), options: [.atomic])
            items.append(SharedInbox.Item(
                storedName: storedName,
                originalTitle: (file.filename as NSString).deletingPathExtension,
                kind: kind
            ))
        }
        guard !items.isEmpty else {
            SharedInbox.discardBatch(at: batch.url)
            throw IntentError.unsupported
        }
        try SharedInbox.commit(SharedInbox.Manifest(
            batchID: batch.id, createdAt: .now, items: items,
            combineImagesIntoOnePDF: true, combinedTitle: nil, sourceAppName: "Shortcuts"
        ), to: batch.url)
        IncomingFileRouter.shared.handleAppScheme(URL(string: "pdfeditor://inbox")!)
        return .result()
    }
}

// MARK: - Intents that run in the background and return files

struct MergePDFsIntent: AppIntent {
    static let title: LocalizedStringResource = "Merge PDFs"
    static let description = IntentDescription("Combines PDFs into one file, in the order given.")

    @Parameter(title: "PDFs", supportedContentTypes: [.pdf])
    var files: [IntentFile]

    @Parameter(title: "Title", default: "Merged")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Merge \(\.$files) into \(\.$name)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard files.count >= 1 else { throw IntentError.noInput }
        let merged = PDFDocument()
        for file in files {
            guard let pdf = PDFDocument(data: file.data) else { throw IntentError.unreadable(file.filename) }
            if pdf.isLocked { throw IntentError.locked(file.filename) }
            for i in 0..<pdf.pageCount {
                if let page = pdf.page(at: i), let copy = page.copy() as? PDFPage {
                    merged.insert(copy, at: merged.pageCount)
                }
            }
        }
        guard merged.pageCount > 0, let data = merged.dataRepresentation() else { throw IntentError.failed }
        let safe = DocumentStorage.sanitizedTitle(name, fallback: "Merged")
        return .result(value: IntentFile(data: data, filename: "\(safe).pdf", type: .pdf))
    }
}

struct ImagesToPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Make PDF from Images"
    static let description = IntentDescription("Turns images into a single PDF, one image per page.")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Title", default: "Images")
    var name: String

    @Parameter(title: "Page Size", default: .fitImage)
    var pageSize: PageSizeOption

    static var parameterSummary: some ParameterSummary {
        Summary("Make PDF from \(\.$images)") {
            \.$name
            \.$pageSize
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard !images.isEmpty else { throw IntentError.noInput }
        let dir = FileManager.default.temporaryDirectory.appending(path: "IntentImages-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for (i, image) in images.enumerated() {
            let ext = image.type?.preferredFilenameExtension ?? "jpg"
            let url = dir.appending(path: "\(i).\(ext)")
            try image.data.write(to: url)
            urls.append(url)
        }
        let output = dir.appending(path: "out.pdf")
        var options = ImagesToPDF.Options()
        options.pageSize = pageSize.pageSize
        try ImagesToPDF.write(imageURLs: urls, to: output, options: options)
        let data = try Data(contentsOf: output)
        let safe = DocumentStorage.sanitizedTitle(name, fallback: "Images")
        return .result(value: IntentFile(data: data, filename: "\(safe).pdf", type: .pdf))
    }
}

enum PageSizeOption: String, AppEnum {
    case fitImage, a4, usLetter

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Page Size")
    static let caseDisplayRepresentations: [PageSizeOption: DisplayRepresentation] = [
        .fitImage: "Fit to image",
        .a4: "A4",
        .usLetter: "US Letter",
    ]

    var pageSize: ImagesToPDF.PageSize {
        switch self {
        case .fitImage: .fitImage
        case .a4: .a4
        case .usLetter: .usLetter
        }
    }
}

struct ExtractTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Text from PDF"
    static let description = IntentDescription("Returns the text of a PDF, page by page. Scanned PDFs need a text layer first.")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Get text from \(\.$file)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let pdf = PDFDocument(data: file.data) else { throw IntentError.unreadable(file.filename) }
        if pdf.isLocked { throw IntentError.locked(file.filename) }
        let text = try PDFExport.text(from: pdf, fallbackOCR: nil)
        return .result(value: text)
    }
}

struct PageCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Count PDF Pages"
    static let description = IntentDescription("Returns how many pages a PDF has.")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        guard let pdf = PDFDocument(data: file.data) else { throw IntentError.unreadable(file.filename) }
        return .result(value: pdf.pageCount)
    }
}

// MARK: - Errors

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case noInput
    case unsupported
    case unreadable(String)
    case locked(String)
    case failed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noInput: "No files were provided."
        case .unsupported: "Only PDFs and images are supported."
        case .unreadable(let name): "\(name) couldn't be read as a PDF."
        case .locked(let name): "\(name) is password protected. Remove the password in PDF Editor first."
        case .failed: "The PDF couldn't be created."
        }
    }
}

// MARK: - Siri and Spotlight phrases

struct PDFEditorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanDocumentIntent(),
            phrases: [
                "Scan a document with \(.applicationName)",
                "Scan with \(.applicationName)",
                "Open the scanner in \(.applicationName)",
            ],
            shortTitle: "Scan Document",
            systemImageName: "doc.viewfinder"
        )
        AppShortcut(
            intent: AskLibraryIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Search my PDFs in \(.applicationName)",
                "Ask my library in \(.applicationName)",
            ],
            shortTitle: "Ask your Library",
            systemImageName: "sparkle.magnifyingglass"
        )
        AppShortcut(
            intent: MergePDFsIntent(),
            phrases: ["Merge PDFs with \(.applicationName)"],
            shortTitle: "Merge PDFs",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: ImagesToPDFIntent(),
            phrases: ["Make a PDF from images with \(.applicationName)", "Convert photos to PDF with \(.applicationName)"],
            shortTitle: "Images to PDF",
            systemImageName: "photo.on.rectangle.angled"
        )
        AppShortcut(
            intent: AddToLibraryIntent(),
            phrases: ["Add to \(.applicationName)"],
            shortTitle: "Add to Library",
            systemImageName: "square.and.arrow.down"
        )
    }
}
