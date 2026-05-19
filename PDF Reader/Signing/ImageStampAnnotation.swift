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
    /// SwiftUI's RotationGesture convention. In `draw` we apply the Y-flip
    /// (needed because CGImage data is top-down) *before* rotating, so
    /// rotation happens inside the already-flipped frame and CW positive
    /// in SwiftUI maps directly to CW positive in CG after the flip.
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

        // Move origin to the centre of the annotation bounds in page space
        // (PDF page space is Y-up).
        context.translateBy(x: bounds.midX, y: bounds.midY)

        // CGImage bytes are top-down, PDF page space is Y-up. Flip Y FIRST
        // so the image draws upright; everything below operates in
        // already-flipped space.
        //
        // Critically, this must happen *before* the rotation. Applying
        // scale(1, -1) after a rotation flips the image's local Y axis,
        // which becomes a mirror in original-screen-space whenever the
        // rotation isn't a multiple of 180°.
        context.scaleBy(x: 1.0, y: -1.0)

        // After the flip we're in a frame where positive rotations rotate
        // clockwise on screen, matching SwiftUI's RotationGesture
        // convention — so we apply `rotationDegrees` without negation.
        if rotationDegrees != 0 {
            context.rotate(by: rotationDegrees * .pi / 180)
        }

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
