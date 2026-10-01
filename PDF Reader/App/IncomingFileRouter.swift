import Foundation
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Single entry point for every file that arrives from outside the app's
/// own UI: "Open in PDF Editor" from other apps (`onOpenURL`), drag and
/// drop onto the Library, the `pdfeditor://` URL scheme, and batches staged
/// by the Share Extension.
///
/// Responsibilities:
/// - Stage the incoming file safely (security scope, iCloud placeholders,
///   Inbox copies that must be deleted afterwards).
/// - Validate it (real PDF? decodable image?).
/// - Convert images to PDF, combining multi-image drops into one document.
/// - Detect exact duplicates and open the existing document instead.
/// - Surface a banner with an "Open" action, and tell the Library to push
///   the new document.
@MainActor
@Observable
final class IncomingFileRouter {
    static let shared = IncomingFileRouter()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var subtitle: String?
        var systemImage: String
        /// When set, the banner's Open button opens this document.
        var documentID: UUID?
        /// When true, Open just switches to the Library tab.
        var opensLibrary: Bool = false
        var isError: Bool = false
    }

    /// Currently visible banner. RootView renders it and auto-dismisses.
    var banner: Banner?
    /// Document the Library should push. Library clears it after reading.
    var documentToOpen: UUID?
    /// Page to show once `documentToOpen` is on screen (0-based). Consumed
    /// by `ReaderController.attach`. Set together with `documentToOpen`.
    var pageToOpen: Int?
    /// Bumps whenever something asks to show the Library tab.
    var libraryRequestToken: Int = 0
    /// Number of files currently being staged/imported (for a progress pill).
    var inFlightCount: Int = 0

    /// App-level actions requested from outside the UI (Quick Actions,
    /// Shortcuts, widgets, `pdfeditor://` links). RootView consumes them.
    enum AppAction: Equatable {
        case scan
        case importFiles
        case newBlank
        case askLibrary(query: String)
        case openTools
    }

    /// Pending action; RootView clears it once handled.
    var pendingAction: AppAction?

    private var container: ModelContainer?
    private var bannerDismissTask: Task<Void, Never>?
    /// Files that arrived before `configure(container:)`; replayed once the
    /// database is ready.
    private var deferredURLs: [URL] = []
    /// Share Extension batches currently being imported. `sweepSharedInbox`
    /// is called from several places (launch, scene activation, URL scheme)
    /// that can fire in the same run-loop turn; without this guard the same
    /// batch is imported twice before the first import removes it.
    private var importingBatchIDs = Set<String>()

    private init() {}

    // MARK: - Setup

    func configure(container: ModelContainer) {
        self.container = container
        if !deferredURLs.isEmpty {
            let urls = deferredURLs
            deferredURLs = []
            handle(urls: urls)
        }
    }

    // MARK: - Public entry points

    /// Handles a URL delivered by `onOpenURL`.
    func handle(url: URL) {
        if url.scheme?.lowercased() == "pdfeditor" {
            handleAppScheme(url)
            return
        }
        guard url.isFileURL else { return }
        handle(urls: [url])
    }

    /// Handles one or more file URLs (Open-in, drop). Images arriving
    /// together are combined into one PDF; PDFs import individually.
    /// - Parameter stageSynchronously: copy the files before returning.
    ///   Required for drag-and-drop, whose temporary URLs may be reclaimed
    ///   as soon as the drop handler returns.
    /// - Parameter folder: Library folder new documents should land in.
    func handle(urls: [URL], stageSynchronously: Bool = false, folder: Folder? = nil) {
        guard let container else {
            deferredURLs.append(contentsOf: urls)
            return
        }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        if stageSynchronously {
            let staged = fileURLs.compactMap { try? Self.stage($0) }
            guard !staged.isEmpty else {
                show(.error("Couldn't read the dropped files."))
                return
            }
            Task { await importStaged(staged, container: container, folder: folder) }
        } else {
            Task {
                var staged: [StagedFile] = []
                var failures = 0
                for url in fileURLs {
                    do {
                        staged.append(try await Self.stageCoordinated(url))
                    } catch {
                        failures += 1
                    }
                }
                if staged.isEmpty {
                    show(.error(failures == 1
                        ? "Couldn't read that file. It may not have finished downloading."
                        : "Couldn't read those files."))
                    return
                }
                await importStaged(staged, container: container, folder: folder)
            }
        }
    }

    /// Imports everything the Share Extension has committed. Safe to call
    /// often; no-ops when the inbox is empty.
    func sweepSharedInbox() {
        guard let container, SharedInbox.isAvailable else { return }
        let batches = SharedInbox.pendingBatches().filter { !importingBatchIDs.contains($0.manifest.batchID) }
        guard !batches.isEmpty else { return }
        let ids = batches.map(\.manifest.batchID)
        importingBatchIDs.formUnion(ids)
        Task {
            await importBatches(batches, container: container)
            importingBatchIDs.subtract(ids)
        }
    }

    /// Consumes `documentToOpen`, returning the resolved document if any.
    func takeDocumentToOpen(in context: ModelContext) -> Document? {
        guard let id = documentToOpen else { return nil }
        documentToOpen = nil
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let document = try? context.fetch(descriptor).first
        if document == nil {
            pageToOpen = nil
            // A widget or Shortcut pointed at a document that has since been
            // deleted; say so rather than silently showing the Library.
            show(Banner(
                title: "Document not found",
                subtitle: "It's no longer in your library.",
                systemImage: "doc.questionmark",
                isError: true
            ))
        }
        return document
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.snappy) { banner = nil }
    }

    /// Called by the banner's Open button.
    func performBannerAction() {
        guard let banner else { return }
        dismissBanner()
        libraryRequestToken &+= 1
        if let id = banner.documentID {
            documentToOpen = id
        }
    }

    // MARK: - Staging

    struct StagedFile {
        var url: URL
        var originalTitle: String
        var kind: SharedInbox.ItemKind
    }

    nonisolated private static var stagingDirectory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "IncomingStaging", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum StagingError: LocalizedError {
        case unsupportedType
        case unreadable
        var errorDescription: String? {
            switch self {
            case .unsupportedType: "Only PDFs and images can be added."
            case .unreadable: "The file couldn't be read."
            }
        }
    }

    nonisolated private static func detectKind(_ url: URL) -> SharedInbox.ItemKind? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let kind = SharedInbox.kind(for: type) {
            return kind
        }
        return SharedInbox.kind(forFileExtension: url.pathExtension)
    }

    /// Copies `url` into app-private temp storage. Handles security scope
    /// and removes the source when it lives in our own `Documents/Inbox`
    /// (iOS puts "Copy to PDF Editor" files there and never cleans up).
    nonisolated private static func stage(_ url: URL) throws -> StagedFile {
        guard let kind = detectKind(url) else { throw StagingError.unsupportedType }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? (kind == .pdf ? "pdf" : "jpg") : url.pathExtension
        let destination = stagingDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw StagingError.unreadable
        }
        if isInAppInbox(url) {
            try? FileManager.default.removeItem(at: url)
        }
        return StagedFile(
            url: destination,
            originalTitle: url.deletingPathExtension().lastPathComponent,
            kind: kind
        )
    }

    /// Like `stage` but wrapped in a coordinated read, which is what makes
    /// iCloud Drive placeholders download before we copy them.
    nonisolated private static func stageCoordinated(_ url: URL) async throws -> StagedFile {
        try await Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            var result: Result<StagedFile, Error> = .failure(StagingError.unreadable)
            NSFileCoordinator().coordinate(
                readingItemAt: url,
                options: [.withoutChanges],
                error: &coordinationError
            ) { readableURL in
                result = Result { try stage(readableURL) }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    nonisolated private static func isInAppInbox(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Documents/Inbox/")
    }

    // MARK: - Import

    private func importStaged(_ files: [StagedFile], container: ModelContainer, folder: Folder?) async {
        inFlightCount += files.count
        defer { inFlightCount = max(0, inFlightCount - files.count) }

        let context = container.mainContext
        var imported: [Document] = []
        var reopened: Document?
        var errors: [String] = []

        // PDFs one by one.
        for file in files where file.kind == .pdf {
            do {
                if let dup = await DocumentStorage.existingDuplicate(of: file.url, in: context) {
                    reopened = dup
                    try? FileManager.default.removeItem(at: file.url)
                    continue
                }
                guard PDFDocument(url: file.url) != nil else {
                    try? FileManager.default.removeItem(at: file.url)
                    errors.append("\(file.originalTitle) isn't a valid PDF.")
                    continue
                }
                let doc = try DocumentStorage.adoptGeneratedPDF(
                    at: file.url,
                    title: file.originalTitle,
                    into: context
                )
                imported.append(doc)
            } catch {
                try? FileManager.default.removeItem(at: file.url)
                errors.append(error.localizedDescription)
            }
        }

        // Images: combine into one PDF when several arrive together.
        let images = files.filter { $0.kind == .image }
        if !images.isEmpty {
            let title: String
            if images.count == 1 {
                title = images[0].originalTitle
            } else {
                title = "Images · " + Date.now.formatted(date: .abbreviated, time: .shortened)
            }
            do {
                let doc = try await convertAndAdopt(imageURLs: images.map(\.url), title: title, context: context)
                imported.append(doc)
            } catch {
                errors.append(error.localizedDescription)
            }
            for image in images { try? FileManager.default.removeItem(at: image.url) }
        }

        if let folder {
            for doc in imported { doc.folder = folder }
        }
        try? context.save()
        report(imported: imported, reopened: reopened, errors: errors, source: nil)
    }

    private func importBatches(
        _ batches: [(manifest: SharedInbox.Manifest, url: URL)],
        container: ModelContainer
    ) async {
        let context = container.mainContext
        var imported: [Document] = []
        var reopened: Document?
        var errors: [String] = []
        var sourceApp: String?

        for (manifest, batchURL) in batches {
            inFlightCount += manifest.items.count
            defer { inFlightCount = max(0, inFlightCount - manifest.items.count) }
            sourceApp = manifest.sourceAppName ?? sourceApp

            var pendingImages: [(URL, String)] = []
            for item in manifest.items {
                let itemURL = batchURL.appending(path: item.storedName)
                guard FileManager.default.fileExists(atPath: itemURL.path) else { continue }
                switch item.kind {
                case .pdf:
                    do {
                        if let dup = await DocumentStorage.existingDuplicate(of: itemURL, in: context) {
                            reopened = dup
                            continue
                        }
                        guard PDFDocument(url: itemURL) != nil else {
                            errors.append("\(item.originalTitle) isn't a valid PDF.")
                            continue
                        }
                        // Copy rather than move: the group container may be
                        // on a different volume and we want the batch folder
                        // removed as one unit afterwards.
                        let temp = Self.stagingDirectory.appending(path: "\(UUID().uuidString).pdf")
                        try FileManager.default.copyItem(at: itemURL, to: temp)
                        let doc = try DocumentStorage.adoptGeneratedPDF(
                            at: temp,
                            title: item.originalTitle,
                            into: context
                        )
                        imported.append(doc)
                    } catch {
                        errors.append(error.localizedDescription)
                    }
                case .image:
                    pendingImages.append((itemURL, item.originalTitle))
                }
            }

            if !pendingImages.isEmpty {
                if manifest.combineImagesIntoOnePDF || pendingImages.count == 1 {
                    let title = manifest.combinedTitle?.isEmpty == false
                        ? manifest.combinedTitle!
                        : (pendingImages.count == 1
                            ? pendingImages[0].1
                            : "Images · " + Date.now.formatted(date: .abbreviated, time: .shortened))
                    do {
                        imported.append(try await convertAndAdopt(
                            imageURLs: pendingImages.map(\.0), title: title, context: context))
                    } catch {
                        errors.append(error.localizedDescription)
                    }
                } else {
                    for (url, title) in pendingImages {
                        do {
                            imported.append(try await convertAndAdopt(
                                imageURLs: [url], title: title, context: context))
                        } catch {
                            errors.append(error.localizedDescription)
                        }
                    }
                }
            }

            SharedInbox.finishBatch(at: batchURL)
        }

        try? context.save()
        report(imported: imported, reopened: reopened, errors: errors, source: sourceApp)
    }

    private func convertAndAdopt(imageURLs: [URL], title: String, context: ModelContext) async throws -> Document {
        let output = Self.stagingDirectory.appending(path: "\(UUID().uuidString).pdf")
        _ = try await Task.detached(priority: .userInitiated) {
            try ImagesToPDF.write(imageURLs: imageURLs, to: output)
        }.value
        return try DocumentStorage.adoptGeneratedPDF(at: output, title: title, into: context)
    }

    // MARK: - Reporting

    private func report(imported: [Document], reopened: Document?, errors: [String], source: String?) {
        if imported.isEmpty, let reopened {
            Haptics.selection()
            show(Banner(
                title: "Already in your library",
                subtitle: reopened.title,
                systemImage: "doc.on.doc",
                documentID: reopened.id
            ))
            return
        }

        if imported.isEmpty {
            Haptics.error()
            show(.error(errors.first ?? "Nothing could be added."))
            return
        }

        Haptics.success()
        let subtitleParts: [String] = [
            source.map { "From \($0)" },
            errors.isEmpty ? nil : (errors.count == 1 ? "1 file skipped" : "\(errors.count) files skipped"),
        ].compactMap { $0 }

        if imported.count == 1 {
            show(Banner(
                title: "Added to Library",
                subtitle: ([imported[0].title] + subtitleParts).joined(separator: " · "),
                systemImage: "checkmark.circle.fill",
                documentID: imported[0].id
            ))
        } else {
            show(Banner(
                title: "Added \(imported.count) documents",
                subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
                systemImage: "checkmark.circle.fill",
                opensLibrary: true
            ))
        }
    }

    private func show(_ newBanner: Banner) {
        bannerDismissTask?.cancel()
        withAnimation(.snappy) { banner = newBanner }
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(newBanner.isError ? 6 : 5))
            guard !Task.isCancelled else { return }
            self?.dismissBanner()
        }
    }

    // MARK: - URL scheme

    /// `pdfeditor://inbox` re-sweeps the shared inbox; `pdfeditor://library`
    /// shows the Library. Unknown paths are ignored. Reserved for widgets
    /// and Shortcuts in later steps.
    func handleAppScheme(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        switch url.host()?.lowercased() {
        case "inbox":
            sweepSharedInbox()
            libraryRequestToken &+= 1
        case "library":
            libraryRequestToken &+= 1
        case "scan":
            pendingAction = .scan
        case "import":
            pendingAction = .importFiles
        case "new":
            pendingAction = .newBlank
        case "ask":
            pendingAction = .askLibrary(query: query)
        case "tools":
            pendingAction = .openTools
        case "document":
            // pdfeditor://document/<uuid>?page=<n>
            if let id = url.pathComponents.dropFirst().first.flatMap(UUID.init) {
                // Reset first so a stale page request from an earlier link
                // can't be applied to this (different) document.
                pageToOpen = nil
                if let pageText = components?.queryItems?.first(where: { $0.name == "page" })?.value,
                   let page = Int(pageText) {
                    pageToOpen = max(0, page - 1)
                }
                documentToOpen = id
                libraryRequestToken &+= 1
            }
        default:
            break
        }
    }
}

extension IncomingFileRouter.Banner {
    static func error(_ message: String) -> Self {
        Self(title: "Couldn't add file", subtitle: message, systemImage: "exclamationmark.triangle.fill", isError: true)
    }
}

