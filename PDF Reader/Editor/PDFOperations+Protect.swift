import Foundation
import PDFKit
import SwiftData

extension PDFOperations {
    struct ProtectRequest {
        var userPassword: String
        var ownerPassword: String
        /// Bitmask of `PDFAccessPermissions` raw values.
        var permissions: UInt
        var replaceOriginal: Bool
        var rememberPassword: Bool
    }

    enum ProtectError: LocalizedError {
        case alreadyProtected
        case emptyPassword
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .alreadyProtected: "This PDF already has a password. Remove it first, or open it once so the password is remembered, then try again."
            case .emptyPassword: "Enter a password."
            case .writeFailed: "The protected PDF couldn't be written."
            }
        }
    }

    /// Encrypts `source` with the given passwords and permissions.
    ///
    /// Writes a new file (PDFKit re-encrypts on write), inserts a `Document`
    /// for it and, when requested, removes the original and moves its
    /// folder, tags and favourite state across so the Library looks
    /// unchanged apart from the lock.
    @discardableResult
    static func protect(_ source: Document, request: ProtectRequest, in context: ModelContext) throws -> Document {
        guard !request.userPassword.isEmpty else { throw ProtectError.emptyPassword }
        guard let pdf = PDFDocument.opened(at: source.fileURL) else { throw OpError.noSourceDocument }
        if pdf.isLocked { throw ProtectError.alreadyProtected }

        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: request.userPassword,
            .ownerPasswordOption: request.ownerPassword,
            .accessPermissionsOption: NSNumber(value: request.permissions),
        ]

        let newID = UUID()
        let filename = "\(newID.uuidString).pdf"
        let url = DocumentStorage.pdfStorageDirectory.appending(path: filename)
        guard pdf.write(to: url, withOptions: options) else { throw ProtectError.writeFailed }

        // Verify the file really is locked before touching the original.
        guard let check = PDFDocument(url: url), check.isLocked else {
            try? FileManager.default.removeItem(at: url)
            throw ProtectError.writeFailed
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let document = Document(
            id: newID,
            title: request.replaceOriginal ? source.title : "\(source.title) (Protected)",
            filename: filename,
            fileSize: size,
            pageCount: source.pageCount
        )
        document.thumbnailData = source.thumbnailData
        document.ocrText = source.ocrText
        document.isSigned = source.isSigned
        if request.replaceOriginal {
            document.folder = source.folder
            document.tags = source.tags
            document.isFavorite = source.isFavorite
            document.isUnread = source.isUnread
            document.addedAt = source.addedAt
        }
        context.insert(document)

        if request.rememberPassword {
            DocumentPasswordStore.store(request.userPassword, for: url)
        }

        if request.replaceOriginal {
            DocumentStorage.transferReadingState(from: source, to: document, in: context)
            DocumentStorage.delete(source, in: context)
        }
        return document
    }
}
