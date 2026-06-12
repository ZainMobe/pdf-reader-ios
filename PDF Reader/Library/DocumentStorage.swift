import Foundation
import PDFKit
import SwiftData

/// On-disk location for imported PDF copies and the entry point for importing files.
///
/// Storage prefers the app's iCloud Drive ubiquity container so PDFs sync
/// across the user's devices and surface in the Files app under
/// `iCloud Drive › PDF Editor`. When iCloud is unavailable (user signed out,
/// container provisioning failed) it falls back to device-local Application
/// Support so the app still works.
///
/// `pdfStorageDirectory` is intentionally cheap and main-thread safe: it
/// returns a cached local fallback until `bootstrapStorage()` finishes
/// resolving the iCloud container on a background thread. Apple's
/// `url(forUbiquityContainerIdentifier:)` blocks the calling thread during
/// first-launch provisioning, so we never invoke it from the main thread.
enum DocumentStorage {
    nonisolated private static let ubiquityContainerIdentifier = "iCloud.com.wappltd.PDF-Reader"

    /// Always-available local fallback. Resolved eagerly because
    /// `FileManager.urls(for:in:)` is cheap and doesn't touch iCloud.
    nonisolated static let localPDFDirectory: URL = makeLocalPDFDirectory()

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var resolvedICloudDirectory: URL?
    nonisolated(unsafe) private static var didStartBootstrap = false

    /// Active directory for PDF reads and writes. Returns iCloud once
    /// bootstrap has resolved the ubiquity container, otherwise the local
    /// fallback. Cheap to call from any thread.
    static var pdfStorageDirectory: URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        return resolvedICloudDirectory ?? localPDFDirectory
    }

    /// True when PDFs are being written to iCloud Drive. UI can surface
    /// this so users know whether their library propagates across devices.
    static var isUsingICloud: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return resolvedICloudDirectory != nil
    }

    /// Resolves the iCloud container on a background thread, publishes it
    /// as the active directory, and migrates any pre-iCloud local PDFs into
    /// it. Idempotent; only the first call does work. Must be called once
    /// at app startup before any iCloud-aware UI runs.
    static func bootstrapStorage() async {
        let shouldRun = stateLock.withLock { () -> Bool in
            if didStartBootstrap { return false }
            didStartBootstrap = true
            return true
        }
        guard shouldRun else { return }

        // The identity-token probe is cheap; the container URL resolution is
        // not. Both are off the main thread for safety.
        let icloud = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
            return resolveICloudDirectoryBlocking()
        }.value

        guard let icloud else { return }

        // Switch storage to iCloud first so any imports that happen during
        // migration land in iCloud directly. Migration sweeps anything left
        // behind in the local fallback.
        stateLock.withLock {
            resolvedICloudDirectory = icloud
        }

        await Task.detached(priority: .utility) {
            migrateLocalPDFsIntoICloud(icloudDirectory: icloud)
        }.value
    }

    enum ImportError: Error, LocalizedError {
        case copyFailed(underlying: any Error)
        case notReadable

        var errorDescription: String? {
            switch self {
            case .copyFailed(let error): "Couldn't copy PDF: \(error.localizedDescription)"
            case .notReadable: "PDF couldn't be read."
            }
        }
    }

    /// Deletes the SwiftData record, removes the underlying PDF file from
    /// `pdfStorageDirectory`, and cascades to any bookmarks referencing the
    /// document. Call this instead of `context.delete(_:)` directly so
    /// storage and metadata don't drift apart over time.
    static func delete(_ document: Document, in context: ModelContext) {
        let url = document.fileURL
        let documentID = document.id

        let bookmarkDescriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.documentID == documentID }
        )
        if let bookmarks = try? context.fetch(bookmarkDescriptor) {
            for bookmark in bookmarks {
                context.delete(bookmark)
            }
        }

        context.delete(document)
        try? FileManager.default.removeItem(at: url)
    }

    /// Copies the file at `sourceURL` into the app's PDF storage and inserts a
    /// `Document` record into `context`. Returns the inserted document.
    @discardableResult
    static func importPDF(from sourceURL: URL, into context: ModelContext) throws -> Document {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let destinationURL = pdfStorageDirectory.appending(path: filename)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw ImportError.copyFailed(underlying: error)
        }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
        let pdfDocument = PDFDocument(url: destinationURL)
        let pageCount = pdfDocument?.pageCount ?? 0
        let title = sourceURL.deletingPathExtension().lastPathComponent

        let document = Document(
            id: id,
            title: title,
            filename: filename,
            fileSize: fileSize,
            pageCount: pageCount
        )

        // Index the document's embedded text so it's searchable from the
        // Library on the next pass. Scanned PDFs already populate `ocrText`
        // via the OCR pipeline; this covers imported PDFs that already
        // carry their own text layer.
        if let body = pdfDocument?.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.ocrText = body
        }

        context.insert(document)
        return document
    }

    /// Forces iCloud to materialize the file at `url` if it's only a
    /// placeholder. No-op when the file is already local or when storage
    /// is not backed by iCloud. Caller can `await` to be sure subsequent
    /// reads succeed; the wait is capped so the UI never hangs forever.
    static func ensureDownloaded(at url: URL) async {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        guard
            let values = try? url.resourceValues(forKeys: keys),
            values.isUbiquitousItem == true,
            values.ubiquitousItemDownloadingStatus != .current
        else { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let refreshed = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if refreshed?.ubiquitousItemDownloadingStatus == .current { return }
        }
    }

    nonisolated private static func resolveICloudDirectoryBlocking() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: ubiquityContainerIdentifier
        ) else { return nil }

        // Files app surfaces the contents of `Documents/` inside the
        // ubiquity container as the visible iCloud Drive folder for the
        // app. We use a `PDFs/` subdirectory to keep the managed library
        // distinct from anything the user may add manually.
        let pdfDir = container
            .appending(path: "Documents", directoryHint: .isDirectory)
            .appending(path: "PDFs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        return pdfDir
    }

    nonisolated private static func makeLocalPDFDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let pdfDir = appSupport.appending(path: "PDFs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        return pdfDir
    }

    /// Sweeps any PDFs sitting in the device-local fallback into iCloud.
    /// Idempotent: re-running just no-ops once the local directory is empty.
    nonisolated private static func migrateLocalPDFsIntoICloud(icloudDirectory: URL) {
        let local = localPDFDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: local,
            includingPropertiesForKeys: nil
        )) ?? []

        for source in contents where source.pathExtension.lowercased() == "pdf" {
            let destination = icloudDirectory.appending(path: source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: source)
                continue
            }
            // `setUbiquitous` atomically promotes the local file into iCloud.
            // If it fails (e.g. the file is open elsewhere) we fall back to a
            // copy so the document at least syncs, even if a stale local copy
            // is left behind.
            do {
                try FileManager.default.setUbiquitous(true, itemAt: source, destinationURL: destination)
            } catch {
                try? FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }
}

/// One-shot backfill that indexes embedded PDF text for any document whose
/// `ocrText` is still `nil`. Runs lazily from the Library so older imports
/// (and documents synced in from other devices) become searchable without a
/// migration.
@MainActor
enum SearchableTextBackfill {
    private static var didRun = false

    static func runIfNeeded(in context: ModelContext) async {
        guard !didRun else { return }
        didRun = true

        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.ocrText == nil }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        for document in pending {
            if Task.isCancelled { return }
            let url = document.fileURL
            await DocumentStorage.ensureDownloaded(at: url)
            let extracted = await Task.detached(priority: .utility) {
                extractText(at: url)
            }.value
            if let extracted {
                document.ocrText = extracted
            }
            await Task.yield()
        }
    }

    nonisolated private static func extractText(at url: URL) -> String? {
        guard
            let pdf = PDFDocument(url: url),
            !pdf.isLocked,
            let body = pdf.string,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return body
    }
}
