import Foundation
import SwiftyDropbox

/// Async/await wrapper around the SwiftyDropbox callback API for the
/// operations we actually use: listing folders, downloading PDFs, and
/// uploading from a local file URL.
enum DropboxService {
    enum DBXError: LocalizedError {
        case notSignedIn
        case requestFailed(String)
        case fileMissing

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "You're not signed in to Dropbox."
            case .requestFailed(let msg): msg
            case .fileMissing: "Couldn't read the file from Dropbox."
            }
        }
    }

    /// A single entry inside a Dropbox folder. Includes everything the
    /// browser sheet needs without leaking SwiftyDropbox metadata types.
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
        let isFolder: Bool
        let size: Int64?
        let modified: Date?
    }

    /// Lists immediate children of `path`. Pass `""` for the user's root.
    @MainActor
    static func listFolder(at path: String) async throws -> [Entry] {
        guard let client = DropboxAuthManager.shared.client else {
            throw DBXError.notSignedIn
        }
        return try await withCheckedThrowingContinuation { continuation in
            client.files.listFolder(path: path).response { result, error in
                if let error {
                    continuation.resume(throwing: DBXError.requestFailed(error.description))
                    return
                }
                let entries = (result?.entries ?? []).compactMap(Self.entry(from:))
                continuation.resume(returning: entries)
            }
        }
    }

    /// Downloads a Dropbox file to a temporary URL on disk. Caller is
    /// responsible for moving / cleaning up the temp file.
    @MainActor
    static func download(path: String) async throws -> URL {
        guard let client = DropboxAuthManager.shared.client else {
            throw DBXError.notSignedIn
        }
        let destination = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).pdf"
        )
        return try await withCheckedThrowingContinuation { continuation in
            client.files.download(path: path, overwrite: true, destination: destination).response { result, error in
                if let error {
                    continuation.resume(throwing: DBXError.requestFailed(error.description))
                    return
                }
                guard let url = result?.1 else {
                    continuation.resume(throwing: DBXError.fileMissing)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }

    /// Uploads `localURL` to `path` on Dropbox, replacing any existing file.
    /// Used by the manual library backup flow.
    @MainActor
    static func upload(localURL: URL, to path: String) async throws {
        guard let client = DropboxAuthManager.shared.client else {
            throw DBXError.notSignedIn
        }
        let data = try Data(contentsOf: localURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.files.upload(path: path, mode: .overwrite, input: data).response { _, error in
                if let error {
                    continuation.resume(throwing: DBXError.requestFailed(error.description))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func entry(from metadata: Files.Metadata) -> Entry? {
        if let folder = metadata as? Files.FolderMetadata {
            return Entry(
                id: folder.id,
                name: folder.name,
                path: folder.pathLower ?? folder.pathDisplay ?? folder.name,
                isFolder: true,
                size: nil,
                modified: nil
            )
        }
        if let file = metadata as? Files.FileMetadata {
            // Only surface PDFs in the picker — the rest are noise here.
            guard file.name.lowercased().hasSuffix(".pdf") else { return nil }
            return Entry(
                id: file.id,
                name: file.name,
                path: file.pathLower ?? file.pathDisplay ?? file.name,
                isFolder: false,
                size: Int64(file.size),
                modified: file.serverModified
            )
        }
        return nil
    }
}
