import Foundation
import SwiftData

/// One-way backup of the local library to a designated `/PDF AI/` folder
/// on the user's Dropbox. Idempotent per filename — re-running the backup
/// overwrites existing files at the same path with the latest local copy.
///
/// Not a true sync: no change tracking, no conflict resolution, no pulls.
/// Designed for the "pick a button, push everything" case.
@MainActor
@Observable
final class DropboxBackup {
    static let shared = DropboxBackup()

    /// Where on Dropbox backups land. App-folder permissions would scope this
    /// automatically, but with full Dropbox access we put it under a known
    /// top-level folder so users can find it from dropbox.com / desktop.
    static let folderPath = "/PDF AI"

    /// Active progress in [0, 1] while a backup is running, else nil.
    private(set) var progress: Double?
    private(set) var lastError: String?

    /// Persisted timestamp of the last successful backup, formatted for UI.
    var lastBackedUpAt: Date? {
        get {
            let interval = UserDefaults.standard.double(forKey: Self.lastBackupKey)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastBackupKey)
        }
    }

    private static let lastBackupKey = "settings.dropbox.lastBackupAt"

    private init() {}

    /// Uploads every Document in `documents` to `/PDF AI/<sanitized-title>.pdf`.
    /// Returns the number of files successfully uploaded.
    @discardableResult
    func backup(_ documents: [Document]) async -> Int {
        guard !documents.isEmpty else { return 0 }
        progress = 0
        defer { progress = nil }

        var uploaded = 0
        let total = Double(documents.count)
        for (index, doc) in documents.enumerated() {
            let remoteName = Self.sanitize(filename: doc.title) + ".pdf"
            let remotePath = "\(Self.folderPath)/\(remoteName)"
            do {
                try await DropboxService.upload(localURL: doc.fileURL, to: remotePath)
                uploaded += 1
            } catch {
                lastError = error.localizedDescription
            }
            progress = Double(index + 1) / total
        }
        if uploaded > 0 {
            lastBackedUpAt = Date()
        }
        return uploaded
    }

    /// Strips characters Dropbox rejects in filenames (`\\ / : * ? " < > |`)
    /// and collapses runs of whitespace. Returns "Untitled" if the title was
    /// empty after sanitisation.
    private static func sanitize(filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = filename
            .components(separatedBy: invalid)
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
