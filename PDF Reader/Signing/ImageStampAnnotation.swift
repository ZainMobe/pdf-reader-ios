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
    /// SwiftUI's RotationGesture convention. The Y-flip in `draw` happens
    /// *before* the rotation so rotation runs inside the already-flipped
    /// frame and CW positive in SwiftUI maps directly to CW positive in CG.
    init(image: UIImage, bounds: CGRect, rotationDegrees: CGFloat = 0) {
        self.image = image
        self.rotationDegrees = rotationDegrees
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        // Move origin to the centre of the annotation bounds in page space
        // (PDF page space is Y-up).
        context.translateBy(x: bounds.midX, y: bounds.midY)

        // PDF page space is Y-up; UIImage.draw expects a Y-down (UIKit)
        // frame, so flip Y FIRST and let everything below run in the
        // already-flipped frame.
        context.scaleBy(x: 1.0, y: -1.0)

        if rotationDegrees != 0 {
            context.rotate(by: rotationDegrees * .pi / 180)
        }

        let drawRect = CGRect(
            x: -bounds.width / 2,
            y: -bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )

        // UIImage.draw honours `imageOrientation`; the previous
        // CGContext.draw(cgImage:) path ignored it, which made photo-
        // imported and PencilKit-rendered signatures stamp mirrored
        // relative to the placement preview.
        UIGraphicsPushContext(context)
        image.draw(in: drawRect)
        UIGraphicsPopContext()
    }
}
