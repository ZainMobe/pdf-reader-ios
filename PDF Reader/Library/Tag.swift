import Foundation
import SwiftData

@Model
final class Tag {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "blue"

    @Relationship(inverse: \Document.tags)
    var documents: [Document] = []

    init(name: String, colorHex: String = "blue") {
        self.name = name
        self.colorHex = colorHex
    }
}
