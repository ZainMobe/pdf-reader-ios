import Foundation
import SwiftData

/// A page-level bookmark inside a document. Stored as a separate model rather
/// than a PDF annotation so it doesn't show up in the page render — purely
/// a navigation aid in the Reader sidebar.
@Model
final class Bookmark {
    var id: UUID = UUID()
    var documentID: UUID = UUID()
    var pageIndex: Int = 0
    var label: String = ""
    var createdAt: Date = Date()

    init(documentID: UUID, pageIndex: Int, label: String) {
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.label = label
    }
}
