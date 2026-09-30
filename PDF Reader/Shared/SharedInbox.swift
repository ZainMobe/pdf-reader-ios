import Foundation
import UniformTypeIdentifiers

/// Hand-off channel between the Share Extension and the main app.
///
/// The extension never touches SwiftData or PDFKit. It stages the raw files
/// the user shared into an App Group folder and drops a small JSON manifest
/// next to them. The main app sweeps the folder on launch and whenever it
/// returns to the foreground, converts images to PDF, imports everything
/// into the Library and then deletes the batch.
///
/// This file is compiled into BOTH the app target and the ShareExtension
/// target. Keep it free of app-only dependencies.
///
/// Layout inside the group container:
///
///     Inbox/
///       <batchID>/
///         manifest.json        written LAST, atomically. No manifest = incomplete batch.
///         0.pdf, 1.jpg, ...    staged payloads, named by index so order is stable
enum SharedInbox {
    /// Must match the App Group added to both targets' entitlements.
    static let appGroupIdentifier = "group.com.wappltd.PDF-Reader"

    /// Hard cap on files per share. Keeps the extension well inside its
    /// memory budget and the import banner readable.
    static let maxItemsPerBatch = 20

    /// Staged batches older than this with no manifest are treated as
    /// abandoned (the extension was killed mid-share) and cleaned up.
    static let abandonedBatchAge: TimeInterval = 24 * 60 * 60

    enum ItemKind: String, Codable {
        case pdf
        case image
    }

    struct Item: Codable, Hashable {
        /// File name inside the batch folder, e.g. `3.jpg`.
        var storedName: String
        /// Display name from the source, without extension. May be empty.
        var originalTitle: String
        var kind: ItemKind
    }

    struct Manifest: Codable {
        var version: Int = 1
        var batchID: String
        var createdAt: Date
        var items: [Item]
        /// When true and the batch contains several images, they are merged
        /// into one multi-page PDF instead of one PDF per image.
        var combineImagesIntoOnePDF: Bool
        /// Optional user-supplied title applied to the combined PDF.
        var combinedTitle: String?
        /// Bundle identifier of the app the share came from, for the banner.
        var sourceAppName: String?
    }

    // MARK: - Locations

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static var inboxURL: URL? {
        guard let containerURL else { return nil }
        let url = containerURL.appending(path: "Inbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True when the App Group is provisioned for this process. False means
    /// the entitlement is missing or the group wasn't registered in the
    /// developer portal yet; callers should degrade gracefully.
    static var isAvailable: Bool { containerURL != nil }

    static func batchURL(for batchID: String) -> URL? {
        inboxURL?.appending(path: batchID, directoryHint: .isDirectory)
    }

    static func manifestURL(in batchURL: URL) -> URL {
        batchURL.appending(path: "manifest.json")
    }

    // MARK: - Writing (extension side)

    /// Creates a fresh, empty batch folder and returns its URL.
    static func beginBatch() throws -> (id: String, url: URL) {
        guard let inboxURL else { throw InboxError.appGroupUnavailable }
        let id = UUID().uuidString
        let url = inboxURL.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (id, url)
    }

    /// Writes the manifest atomically. Doing this last is what makes a
    /// batch visible to the app, so a crash before this point leaves
    /// nothing half-imported.
    static func commit(_ manifest: Manifest, to batchURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: batchURL), options: [.atomic])
    }

    /// Discards a batch folder (used when the user cancels).
    static func discardBatch(at batchURL: URL) {
        try? FileManager.default.removeItem(at: batchURL)
    }

    // MARK: - Reading (app side)

    /// All committed batches, oldest first. Also sweeps abandoned folders.
    static func pendingBatches() -> [(manifest: Manifest, url: URL)] {
        guard let inboxURL else { return [] }
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var result: [(manifest: Manifest, url: URL)] = []
        for folder in folders {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values?.isDirectory == true else {
                // Stray file at the top level; never ours.
                try? fm.removeItem(at: folder)
                continue
            }
            let manifestURL = manifestURL(in: folder)
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? decoder.decode(Manifest.self, from: data) {
                result.append((manifest: manifest, url: folder))
            } else if let created = values?.creationDate,
                      Date().timeIntervalSince(created) > abandonedBatchAge {
                try? fm.removeItem(at: folder)
            }
        }
        return result.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    static func finishBatch(at batchURL: URL) {
        try? FileManager.default.removeItem(at: batchURL)
    }

    // MARK: - Type helpers

    static func kind(for type: UTType) -> ItemKind? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    static func kind(forFileExtension ext: String) -> ItemKind? {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return nil }
        return kind(for: type)
    }

    enum InboxError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                "Shared storage isn't available. Open PDF Editor once, then try sharing again."
            }
        }
    }
}
