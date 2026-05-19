import SwiftUI
import PencilKit
import UIKit

/// SwiftUI wrapper around `PKCanvasView` configured for signature capture.
///
/// Uses a fine pen tool and accepts any input (finger or Apple Pencil).
/// Reports drawing changes back to SwiftUI so consumers can enable a
/// "Save" button only when something has been drawn.
struct SignatureCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var onDrawingChange: ((PKDrawing) -> Void)?

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: UIColor.label, width: 4)
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.delegate = context.coordinator
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        context.coordinator.onDrawingChange = onDrawingChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChange: onDrawingChange)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDrawingChange: ((PKDrawing) -> Void)?

        init(onDrawingChange: ((PKDrawing) -> Void)?) {
            self.onDrawingChange = onDrawingChange
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChange?(canvasView.drawing)
        }
    }
}
