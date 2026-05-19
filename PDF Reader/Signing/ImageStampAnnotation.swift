import Foundation
import PDFKit
import UIKit

/// A `PDFAnnotation` subclass that renders a `UIImage` (e.g. a signature)
/// inside its bounds with an optional rotation. Stays as an annotation so
/// it can be reflowed / removed later; flattening happens naturally when
/// the host writes the PDF to disk.
final class ImageStampAnnotation: PDFAnnotation {
    private let image: UIImage
    private let rotationDegrees: CGFloat

    /// `rotationDegrees` is the clockwise rotation in degrees, matching
    /// SwiftUI's RotationGesture convention. We negate it inside `draw`
    /// because PDF page space is Y-up (positive CG rotation = CCW).
    init(image: UIImage, bounds: CGRect, rotationDegrees: CGFloat = 0) {
        self.image = image
        self.rotationDegrees = rotationDegrees
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = image.cgImage else { return }
        context.saveGState()

        // Move origin to the centre of the annotation bounds in page space.
        context.translateBy(x: bounds.midX, y: bounds.midY)

        // CG rotation is CCW for positive angles in Y-up coordinates; the
        // SwiftUI gesture reports CW positive, so we invert the sign so
        // the on-screen preview matches the rendered annotation.
        if rotationDegrees != 0 {
            context.rotate(by: -rotationDegrees * .pi / 180)
        }

        // CGImage bytes are top-down; flip Y so the signature draws upright.
        context.scaleBy(x: 1.0, y: -1.0)

        let drawRect = CGRect(
            x: -bounds.width / 2,
            y: -bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    }
}
