import Foundation
import SwiftData

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String?
    var createdAt: Date = Date()

    var parent: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    var children: [Folder]? = []

    @Relationship(inverse: \Document.folder)
    var documents: [Document]? = []

    init(name: String, colorHex: String? = nil, parent: Folder? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.parent = parent
    }
}
