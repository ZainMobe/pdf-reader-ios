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
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: DesignSystem.Spacing.l) {
                        Button {
                            canvasView.tool = PKInkingTool(.pen, color: .label, width: 3)
                        } label: {
                            Label("Pen", systemImage: "pencil.tip")
                        }
                        Button {
                            canvasView.tool = PKInkingTool(.marker, color: UIColor.systemYellow.withAlphaComponent(0.4), width: 12)
                        } label: {
                            Label("Highlighter", systemImage: "highlighter")
                        }
                        Button {
                            canvasView.tool = PKEraserTool(.bitmap)
                        } label: {
                            Label("Eraser", systemImage: "eraser")
                        }
                        Spacer()
                        Button {
                            canvasView.drawing = PKDrawing()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commitAndDismiss() }
                        .buttonStyle(.glassProminent)
                }
            }
            .task { renderPage() }
        }
    }

    private func renderPage() {
        guard
            let pdf = PDFDocument(url: document.fileURL),
            let page = pdf.page(at: pageIndex)
        else { return }
        let bounds = page.bounds(for: .cropBox)
        pageSize = bounds.size
        let scale: CGFloat = 2
        let renderSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        pageImage = page.thumbnail(of: renderSize, for: .cropBox)
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

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.tool = PKInkingTool(.pen, color: UIColor.label, width: 3)
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
