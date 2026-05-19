import Foundation
import SwiftData

/// A saved signature stored as raw image data. Users can reuse signatures
/// across documents instead of redrawing each time.
@Model
final class SignatureAsset {
    var id: UUID = UUID()
    var name: String = ""
    var imageData: Data = Data()
    var createdAt: Date = Date()

    init(name: String, imageData: Data) {
        self.name = name
        self.imageData = imageData
    }
}
