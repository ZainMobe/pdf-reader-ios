import SwiftUI
import PencilKit
import PDFKit
import UIKit

/// Full-screen ink editor for a single PDF page.
///
/// Renders the target page as a background image and overlays a
/// `PKCanvasView` of the same dimensions so the user can ink directly over
/// the page content. On commit, the ink-only drawing (transparent background)
/// is handed back as a `UIImage` for the host to stamp onto the page.
struct InkSheet: View {
    let document: Document
    let pageIndex: Int
    let onCommit: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canvasView = PKCanvasView()
    @State private var pageImage: UIImage?
    @State private var pageSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let fit = aspectFit(pageSize, in: proxy.size)
                ZStack {
                    Color.clear
                    if let pageImage {
                        Image(uiImage: pageImage)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                        InkCanvasView(canvasView: $canvasView)
                            .frame(width: fit.width, height: fit.height)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.background.secondary)
            .navigationTitle("Ink Page \(pageIndex + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // PencilKit's tool picker owns pens, pressure, colours,
                    // ruler and eraser, and honours the Apple Pencil
                    // double-tap and squeeze preferences. We only add Clear.
                    Button {
                        canvasView.drawing = PKDrawing()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commitAndDismiss() }
                        .buttonStyle(.glassProminent)
                }
            }
            .task { await renderPage() }
        }
    }

    /// Renders the page off the main thread. At 2x on a large page this can
    /// take several seconds; doing it inline froze the sheet mid-presentation.
    private func renderPage() async {
        let url = document.fileURL
        let index = pageIndex
        let result: (CGSize, UIImage)? = await Task.detached(priority: .userInitiated) {
            guard
                let pdf = PDFDocument.opened(at: url),
                let page = pdf.page(at: index)
            else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let scale: CGFloat = 2
            let renderSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            return (bounds.size, page.thumbnail(of: renderSize, for: .cropBox))
        }.value
        guard let result, !Task.isCancelled else { return }
        pageSize = result.0
        pageImage = result.1
    }

    private func commitAndDismiss() {
        let drawingBounds = canvasView.drawing.bounds
        guard !drawingBounds.isEmpty else {
            dismiss()
            return
        }
        let image = canvasView.drawing.image(from: canvasView.bounds, scale: 3.0)
        onCommit(image)
        dismiss()
    }

    private func aspectFit(_ source: CGSize, in container: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return container }
        let ratio = min(container.width / source.width, container.height / source.height)
        return CGSize(width: source.width * ratio, height: source.height * ratio)
    }
}

private struct InkCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        // `.default` follows the system "Only Draw with Apple Pencil" setting:
        // finger drawing on iPhone, palm rejection and Pencil-only on iPad
        // when the user has asked for it.
        canvasView.drawingPolicy = .default
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.tool = PKInkingTool(.pen, color: UIColor.label, width: 3)

        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: canvasView)
        picker.addObserver(canvasView)
        context.coordinator.picker = picker
        DispatchQueue.main.async {
            canvasView.becomeFirstResponder()
        }
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.picker?.setVisible(false, forFirstResponder: uiView)
        coordinator.picker?.removeObserver(uiView)
        uiView.resignFirstResponder()
    }

    final class Coordinator {
        var picker: PKToolPicker?
    }
}
