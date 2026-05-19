import Foundation
import PDFKit
import UIKit

/// A `PDFAnnotation` subclass that renders a `UIImage` (e.g. a signature)
/// inside its bounds. Stays as an annotation so it can be reflowed / removed
/// later; flattening happens naturally when the host writes the PDF to disk.
final class ImageStampAnnotation: PDFAnnotation {
    private let image: UIImage

    init(image: UIImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image.cgImage else { return }
        context.saveGState()
        // PDF page space has origin at the bottom-left and Y increasing upward,
        // but CGImage data is top-down — flip so the signature draws upright.
        context.translateBy(x: bounds.minX, y: bounds.minY + bounds.height)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        )
        context.restoreGState()
    }
}
