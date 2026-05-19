import SwiftUI
import PencilKit
import UIKit

/// SwiftUI wrapper around `PKCanvasView` configured for signature capture.
///
/// Uses a fine pen tool and accepts any input (finger or Apple Pencil).
struct SignatureCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: UIColor.label, width: 4)
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
