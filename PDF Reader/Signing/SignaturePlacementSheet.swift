import SwiftUI
import PDFKit
import UIKit

/// Full-screen placement editor for a signature image. Renders the target
/// page as a background and lets the user drag the signature around and
/// pinch to resize before committing it as a `PDFAnnotation` on the page.
///
/// The host (Reader) receives the final placement as a `CGRect` in PDF
/// page coordinates (origin at the bottom-left) and stamps the annotation
/// itself via `ReaderController.placeSignature`.
struct SignaturePlacementSheet: View {
    let document: Document
    let pageIndex: Int
    let signatureImage: UIImage
    let onPlace: (CGRect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pageImage: UIImage?
    @State private var pageSize: CGSize = .zero

    /// Position + size are stored normalized to page width/height so they
    /// survive geometry changes (e.g. rotation). Y is top-down here for
    /// easy SwiftUI math; we flip it to PDF-space on commit.
    @State private var centerXNorm: CGFloat = 0.5
    @State private var centerYNorm: CGFloat = 0.78
    @State private var widthNorm: CGFloat = 0.33

    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var liveMagnification: CGFloat = 1.0

    private var aspect: CGFloat {
        signatureImage.size.height / max(signatureImage.size.width, 1)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let fit = aspectFit(pageSize, in: proxy.size)
                let pageRect = CGRect(
                    x: (proxy.size.width - fit.width) / 2,
                    y: (proxy.size.height - fit.height) / 2,
                    width: fit.width,
                    height: fit.height
                )

                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    if let pageImage {
                        Image(uiImage: pageImage)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        signatureOverlay(in: pageRect)
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Place Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Place") { commit() }
                        .buttonStyle(.glassProminent)
                }
                ToolbarItem(placement: .bottomBar) {
                    Label("Drag to move · Pinch to resize", systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task { renderPage() }
        }
    }

    private func signatureOverlay(in pageRect: CGRect) -> some View {
        let liveWidth = pageRect.width * widthNorm * liveMagnification
        let liveHeight = liveWidth * aspect
        let centerX = pageRect.minX + pageRect.width * centerXNorm + dragOffset.width
        let centerY = pageRect.minY + pageRect.height * centerYNorm + dragOffset.height

        return Image(uiImage: signatureImage)
            .resizable()
            .scaledToFit()
            .frame(width: liveWidth, height: liveHeight)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                    .strokeBorder(.tint, lineWidth: 1.5)
            )
            .position(x: centerX, y: centerY)
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            guard pageRect.width > 0, pageRect.height > 0 else { return }
                            let dx = value.translation.width / pageRect.width
                            let dy = value.translation.height / pageRect.height
                            centerXNorm = clamp(centerXNorm + dx, 0.05, 0.95)
                            centerYNorm = clamp(centerYNorm + dy, 0.05, 0.95)
                        },
                    MagnificationGesture()
                        .updating($liveMagnification) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            widthNorm = clamp(widthNorm * value, 0.1, 0.9)
                        }
                )
            )
    }

    private func renderPage() {
        guard
            let pdf = PDFDocument(url: document.fileURL),
            let page = pdf.page(at: pageIndex)
        else { return }
        let bounds = page.bounds(for: .cropBox)
        pageSize = bounds.size
        let scale: CGFloat = 2
        pageImage = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .cropBox
        )
    }

    private func commit() {
        guard
            let pdf = PDFDocument(url: document.fileURL),
            let page = pdf.page(at: pageIndex)
        else {
            dismiss()
            return
        }
        let bounds = page.bounds(for: .mediaBox)
        let sigWidth = bounds.width * widthNorm
        let sigHeight = sigWidth * aspect

        // Our normalized Y is top-down; PDF page space is bottom-up.
        let centerX = bounds.width * centerXNorm
        let centerYFromTop = bounds.height * centerYNorm
        let centerYFromBottom = bounds.height - centerYFromTop

        let placedBounds = CGRect(
            x: centerX - sigWidth / 2,
            y: centerYFromBottom - sigHeight / 2,
            width: sigWidth,
            height: sigHeight
        )
        onPlace(placedBounds)
        dismiss()
    }

    private func aspectFit(_ source: CGSize, in container: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return container }
        let ratio = min(container.width / source.width, container.height / source.height)
        return CGSize(width: source.width * ratio, height: source.height * ratio)
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
