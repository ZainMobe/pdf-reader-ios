import Foundation
import SwiftData

@Model
final class Document {
    var id: UUID = UUID()
    var title: String = ""
    /// Local filename inside `DocumentStorage.pdfStorageDirectory`. The original
    /// import URL is not retained; the imported copy is the source of truth.
    var filename: String = ""
    var fileSize: Int64 = 0
    var pageCount: Int = 0
    var addedAt: Date = Date()
    var lastOpenedAt: Date?
    var isFavorite: Bool = false
    var isUnread: Bool = true
    var isSigned: Bool = false
    var thumbnailData: Data?
    /// Last page the user was on (0-based). Restored when the document is
    /// reopened; synced with the rest of the record.
    var lastPageIndex: Int = 0

    /// Plain-text content extracted at scan/import time. Used as a fallback
    /// for AI summarization when the PDF itself has no embedded text (e.g.
    /// image-only scans before the invisible-text-overlay pipeline ships).
    var ocrText: String?

    var folder: Folder?
    var tags: [Tag]? = []

    @Transient
    var fileURL: URL {
        DocumentStorage.pdfStorageDirectory.appending(path: filename)
    }

    init(
        id: UUID = UUID(),
        title: String,
        filename: String,
        fileSize: Int64,
        pageCount: Int
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.fileSize = fileSize
        self.pageCount = pageCount
    }
}
